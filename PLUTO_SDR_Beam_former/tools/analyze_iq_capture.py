#!/usr/bin/env python3
"""Analyze interleaved Pluto 2-RX I/Q captures without third-party packages."""

import argparse
import cmath
import math
import struct
from pathlib import Path


def fft(values):
    count = len(values)
    levels = count.bit_length() - 1
    if 1 << levels != count:
        raise ValueError("sample count must be a power of two")

    output = [0j] * count
    for index, value in enumerate(values):
        reversed_index = int(f"{index:0{levels}b}"[::-1], 2)
        output[reversed_index] = value

    size = 2
    while size <= count:
        step = cmath.exp(-2j * math.pi / size)
        half = size // 2
        for start in range(0, count, size):
            rotation = 1 + 0j
            for offset in range(half):
                even = output[start + offset]
                odd = rotation * output[start + offset + half]
                output[start + offset] = even + odd
                output[start + offset + half] = even - odd
                rotation *= step
        size *= 2
    return output


def analyze(samples, sample_rate):
    count = len(samples)
    mean = sum(samples) / count
    windowed = []
    window_sum = 0.0
    for index, sample in enumerate(samples):
        window = 0.5 - 0.5 * math.cos(2.0 * math.pi * index / (count - 1))
        window_sum += window
        windowed.append((sample - mean) * window)

    spectrum = fft(windowed)
    bins = []
    for index, value in enumerate(spectrum):
        frequency = index * sample_rate / count
        if index >= count // 2:
            frequency -= sample_rate
        amplitude = abs(value) / window_sum / 2048.0
        dbfs = 20.0 * math.log10(max(amplitude, 1e-15))
        if abs(frequency) >= 10_000:
            bins.append((dbfs, frequency))

    bins.sort(reverse=True)
    noise_bins = sorted(dbfs for dbfs, _ in bins)
    median = noise_bins[len(noise_bins) // 2]
    return bins[:5], median


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("captures", nargs="+", type=Path)
    parser.add_argument("--sample-rate", type=float, default=8_000_000.0)
    args = parser.parse_args()

    for path in args.captures:
        raw = path.read_bytes()
        if len(raw) % 8:
            raise ValueError(f"{path}: byte length is not divisible by 8")
        words = struct.unpack(f"<{len(raw) // 2}h", raw)
        channels = (
            [complex(words[index], words[index + 1]) for index in range(0, len(words), 4)],
            [complex(words[index], words[index + 1]) for index in range(2, len(words), 4)],
        )
        print(path)
        for channel_number, samples in enumerate(channels, start=1):
            peaks, median = analyze(samples, args.sample_rate)
            formatted = ", ".join(
                f"{frequency:+.1f} Hz {dbfs:.2f} dBFS" for dbfs, frequency in peaks
            )
            print(f"  CH{channel_number}: peaks [{formatted}], median={median:.2f} dBFS/bin")


if __name__ == "__main__":
    main()
