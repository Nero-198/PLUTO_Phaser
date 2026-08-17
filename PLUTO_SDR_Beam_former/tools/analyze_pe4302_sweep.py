#!/usr/bin/env python3
"""Quantify the programmed-attenuation response from a Pluto 2-RX sweep."""

import argparse
import csv
import json
import math
import struct
from pathlib import Path


def read_channels(path):
    raw = path.read_bytes()
    if len(raw) % 8:
        raise ValueError(f"{path}: byte length is not divisible by 8")
    words = struct.unpack(f"<{len(raw) // 2}h", raw)
    return (
        [complex(words[index], words[index + 1]) for index in range(0, len(words), 4)],
        [complex(words[index], words[index + 1]) for index in range(2, len(words), 4)],
    )


def tone_measurement(samples, frequency, sample_rate):
    mean = sum(samples) / len(samples)
    centered = [sample - mean for sample in samples]
    candidates = []
    for signed_frequency in (frequency, -frequency):
        step = complex(
            math.cos(-2.0 * math.pi * signed_frequency / sample_rate),
            math.sin(-2.0 * math.pi * signed_frequency / sample_rate),
        )
        rotation = 1 + 0j
        total = 0j
        for sample in centered:
            total += sample * rotation
            rotation *= step
        amplitude = abs(total) / len(centered) / 2048.0
        candidates.append((20.0 * math.log10(max(amplitude, 1e-15)), signed_frequency))
    level, detected_frequency = max(candidates)
    peak_code = max(max(abs(int(value.real)), abs(int(value.imag))) for value in samples)
    return level, detected_frequency, peak_code


def slope(rows, direction, channel_key):
    selected = [row for row in rows if row["direction"] == direction]
    xs = [float(row["attenuation_db"]) for row in selected]
    ys = [float(row[channel_key]) for row in selected]
    x_mean = sum(xs) / len(xs)
    y_mean = sum(ys) / len(ys)
    denominator = sum((value - x_mean) ** 2 for value in xs)
    return sum((x - x_mean) * (y - y_mean) for x, y in zip(xs, ys)) / denominator


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("directory", type=Path)
    parser.add_argument(
        "--tone-frequency",
        type=float,
        help="Measured complex-baseband tone frequency in Hz; overrides setup metadata",
    )
    args = parser.parse_args()

    setup = json.loads((args.directory / "measurement_setup.json").read_text())
    with (args.directory / "sweep_metadata.csv").open(newline="") as stream:
        metadata = list(csv.DictReader(stream))

    sample_rate = float(setup["sample_rate_sps"])
    expected_if = abs(
        args.tone_frequency
        if args.tone_frequency is not None
        else float(setup["expected_if_hz"])
    )
    expected_if %= sample_rate
    if expected_if > sample_rate / 2:
        expected_if = sample_rate - expected_if
    rows = []
    for entry in metadata:
        channels = read_channels(args.directory / entry["file"])
        ch1 = tone_measurement(channels[0], expected_if, sample_rate)
        ch2 = tone_measurement(channels[1], expected_if, sample_rate)
        rows.append(
            {
                "index": int(entry["index"]),
                "direction": entry["direction"],
                "attenuation_db": float(entry["attenuation_db"]),
                "ch1_tone_dbfs": round(ch1[0], 3),
                "ch1_frequency_hz": round(ch1[1], 3),
                "ch1_peak_code": ch1[2],
                "ch2_tone_dbfs": round(ch2[0], 3),
                "ch2_frequency_hz": round(ch2[1], 3),
                "ch2_peak_code": ch2[2],
                "file": entry["file"],
            }
        )

    output_path = args.directory / "sweep_results.csv"
    with output_path.open("w", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=rows[0].keys())
        writer.writeheader()
        writer.writerows(rows)

    down_slope = slope(rows, "down", "ch2_tone_dbfs")
    up_slope = slope(rows, "up", "ch2_tone_dbfs")
    down = [row for row in rows if row["direction"] == "down"]
    down_span = down[-1]["ch2_tone_dbfs"] - down[0]["ch2_tone_dbfs"]
    summary = {
        "expected_response_slope_db_per_db": -1.0,
        "analyzed_tone_frequency_hz": expected_if,
        "ch2_down_slope_db_per_db": round(down_slope, 4),
        "ch2_up_slope_db_per_db": round(up_slope, 4),
        "ch2_31p5_to_0_change_db": round(down_span, 3),
        "expected_31p5_to_0_change_db": 31.5,
        "result": "CH2 attenuation did not track the programmed value",
    }
    (args.directory / "sweep_summary.json").write_text(
        json.dumps(summary, indent=2) + "\n"
    )

    print(output_path)
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
