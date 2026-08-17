#!/usr/bin/env python3
"""Analyze a dual-RX synthetic DoA phase-shifter sweep."""

from __future__ import annotations

import argparse
import csv
import json
import math
import tempfile
from pathlib import Path


def wrap_degrees(value: float) -> float:
    return (value + 180.0) % 360.0 - 180.0


def circular_mean_degrees(values: list[float]) -> float:
    real = sum(math.cos(math.radians(value)) for value in values)
    imag = sum(math.sin(math.radians(value)) for value in values)
    return math.degrees(math.atan2(imag, real))


def virtual_sum_power(
    ch1_dbfs: float,
    ch2_dbfs: float,
    relative_phase_deg: float,
    rx_phase_correction_deg: float,
) -> float:
    amplitude1 = 10.0 ** (ch1_dbfs / 20.0)
    amplitude2 = 10.0 ** (ch2_dbfs / 20.0)
    phase = math.radians(
        wrap_degrees(relative_phase_deg - rx_phase_correction_deg)
    )
    return max(
        1.0e-30,
        amplitude1 * amplitude1
        + amplitude2 * amplitude2
        + 2.0 * amplitude1 * amplitude2 * math.cos(phase),
    )


def fit_peak_phase(points: list[tuple[float, float]]) -> tuple[float, float]:
    """Fit the first harmonic P(phi)=C+A*cos(phi)+B*sin(phi)."""
    grouped: dict[float, list[float]] = {}
    for phase_deg, power in points:
        normalized = phase_deg % 360.0
        grouped.setdefault(normalized, []).append(power)
    states = [
        (phase, sum(powers) / len(powers))
        for phase, powers in sorted(grouped.items())
    ]
    if len(states) < 8:
        raise ValueError("at least eight unique phase states are required")
    mean_power = sum(power for _, power in states) / len(states)
    cosine = 2.0 * sum(
        power * math.cos(math.radians(phase)) for phase, power in states
    ) / len(states)
    sine = 2.0 * sum(
        power * math.sin(math.radians(phase)) for phase, power in states
    ) / len(states)
    peak_phase = math.degrees(math.atan2(sine, cosine)) % 360.0
    modulation_depth = math.hypot(cosine, sine) / max(mean_power, 1.0e-30)
    return peak_phase, modulation_depth


def analyze_run(
    directory: Path, rx_phase_correction_deg: float
) -> dict[str, float | int]:
    csv_path = directory / "phase_presence_measurements.csv"
    rows = list(csv.DictReader(csv_path.open(encoding="utf-8-sig", newline="")))
    if not rows:
        raise ValueError(f"no measurements in {csv_path}")

    points: list[tuple[float, float]] = []
    clipped = 0
    phase_groups: dict[float, list[float]] = {}
    for row in rows:
        commanded = float(row["commanded_phase_deg"])
        relative = float(row["relative_phase_deg"])
        power = virtual_sum_power(
            float(row["ch1_tone_dbfs"]),
            float(row["ch2_tone_dbfs"]),
            relative,
            rx_phase_correction_deg,
        )
        points.append((commanded, power))
        phase_groups.setdefault(commanded % 360.0, []).append(relative)
        clipped += int(row["ch1_clipped_samples"])
        clipped += int(row["ch2_clipped_samples"])

    peak_phase, modulation_depth = fit_peak_phase(points)
    state_powers: dict[float, list[float]] = {}
    for phase, power in points:
        state_powers.setdefault(phase % 360.0, []).append(power)
    mean_state_powers = {
        phase: sum(values) / len(values) for phase, values in state_powers.items()
    }
    discrete_peak = max(mean_state_powers, key=mean_state_powers.get)
    peak_power = mean_state_powers[discrete_peak]
    minimum_power = min(mean_state_powers.values())

    return {
        "fitted_peak_phase_deg": peak_phase,
        "discrete_peak_phase_deg": discrete_peak,
        "modulation_depth": modulation_depth,
        "peak_virtual_sum_dbfs": 10.0 * math.log10(peak_power),
        "null_virtual_sum_dbfs": 10.0 * math.log10(max(minimum_power, 1.0e-30)),
        "peak_to_null_db": 10.0
        * math.log10(peak_power / max(minimum_power, 1.0e-30)),
        "clipped_samples": clipped,
        "sample_count": len(rows),
        "state_zero_relative_phase_deg": circular_mean_degrees(
            phase_groups.get(0.0, [])
        ),
    }


def analyze_root(
    root: Path, rx_phase_correction_deg: float
) -> tuple[list[dict[str, float | int | str]], dict[str, float | int | str]]:
    manifest_path = root / "synthetic_doa_manifest.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8-sig"))
    spacing = float(manifest["virtual_spacing_wavelengths"])
    if spacing <= 0.0:
        raise ValueError("virtual spacing must be positive")

    analyzed: list[dict[str, float | int | str]] = []
    for run in manifest["runs"]:
        result = analyze_run(root / run["directory"], rx_phase_correction_deg)
        analyzed.append(
            {
                "target_angle_deg": float(run["target_angle_deg"]),
                "requested_tx2_relative_phase_deg": float(
                    run["requested_tx2_relative_phase_deg"]
                ),
                **result,
                "directory": run["directory"],
            }
        )

    center = min(analyzed, key=lambda row: abs(float(row["target_angle_deg"])))
    center_peak = float(center["fitted_peak_phase_deg"])
    expected_pairs = [
        (
            wrap_degrees(
                float(row["fitted_peak_phase_deg"]) - center_peak
            ),
            float(row["requested_tx2_relative_phase_deg"]),
        )
        for row in analyzed
        if abs(float(row["target_angle_deg"])) > 1.0e-9
    ]
    sign_errors = {}
    for sign in (1, -1):
        squared = [
            wrap_degrees(measured - sign * expected) ** 2
            for measured, expected in expected_pairs
        ]
        sign_errors[sign] = math.sqrt(sum(squared) / len(squared))
    inferred_sign = min(sign_errors, key=sign_errors.get)

    angle_errors = []
    phase_errors = []
    for row in analyzed:
        phase_from_center = wrap_degrees(
            float(row["fitted_peak_phase_deg"]) - center_peak
        )
        estimated_input_phase = wrap_degrees(inferred_sign * phase_from_center)
        sine_argument = estimated_input_phase / (360.0 * spacing)
        valid = abs(sine_argument) <= 1.0
        estimated_angle = (
            math.degrees(math.asin(max(-1.0, min(1.0, sine_argument))))
            if valid
            else math.nan
        )
        target_angle = float(row["target_angle_deg"])
        expected_phase = float(row["requested_tx2_relative_phase_deg"])
        phase_error = wrap_degrees(estimated_input_phase - expected_phase)
        angle_error = estimated_angle - target_angle if valid else math.nan
        row["phase_from_center_deg"] = phase_from_center
        row["estimated_input_phase_deg"] = estimated_input_phase
        row["phase_error_deg"] = phase_error
        row["estimated_angle_deg"] = estimated_angle
        row["angle_error_deg"] = angle_error
        row["angle_valid"] = "yes" if valid else "no"
        phase_errors.append(abs(phase_error))
        if valid:
            angle_errors.append(abs(angle_error))

    summary: dict[str, float | int | str] = {
        "inferred_tx_phase_sign": inferred_sign,
        "center_fitted_peak_phase_deg": center_peak,
        "rx_phase_correction_deg": rx_phase_correction_deg,
        "mean_abs_phase_error_deg": sum(phase_errors) / len(phase_errors),
        "max_abs_phase_error_deg": max(phase_errors),
        "mean_abs_angle_error_deg": sum(angle_errors) / len(angle_errors),
        "max_abs_angle_error_deg": max(angle_errors),
        "total_clipped_samples": sum(
            int(row["clipped_samples"]) for row in analyzed
        ),
        "run_count": len(analyzed),
    }
    return analyzed, summary


def write_results(
    root: Path,
    rows: list[dict[str, float | int | str]],
    summary: dict[str, float | int | str],
) -> None:
    csv_path = root / "synthetic_doa_summary.csv"
    with csv_path.open("w", encoding="utf-8", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)
    (root / "synthetic_doa_analysis.json").write_text(
        json.dumps(summary, indent=2) + "\n", encoding="utf-8"
    )


def self_test() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        runs = []
        spacing = 0.5
        offset = 37.0
        for target in (-45.0, 0.0, 30.0):
            injected = 360.0 * spacing * math.sin(math.radians(target))
            directory = root / f"angle_{target:+.0f}"
            directory.mkdir()
            runs.append(
                {
                    "target_angle_deg": target,
                    "requested_tx2_relative_phase_deg": injected,
                    "directory": directory.name,
                }
            )
            with (directory / "phase_presence_measurements.csv").open(
                "w", encoding="utf-8", newline=""
            ) as stream:
                fieldnames = [
                    "commanded_phase_deg",
                    "relative_phase_deg",
                    "ch1_tone_dbfs",
                    "ch2_tone_dbfs",
                    "ch1_clipped_samples",
                    "ch2_clipped_samples",
                ]
                writer = csv.DictWriter(stream, fieldnames=fieldnames)
                writer.writeheader()
                for phase in (index * 22.5 for index in range(16)):
                    relative = wrap_degrees(injected + offset - phase)
                    writer.writerow(
                        {
                            "commanded_phase_deg": phase,
                            "relative_phase_deg": relative,
                            "ch1_tone_dbfs": -30.0,
                            "ch2_tone_dbfs": -30.0,
                            "ch1_clipped_samples": 0,
                            "ch2_clipped_samples": 0,
                        }
                    )
        (root / "synthetic_doa_manifest.json").write_text(
            json.dumps(
                {"virtual_spacing_wavelengths": spacing, "runs": runs}
            ),
            encoding="utf-8",
        )
        rows, summary = analyze_root(root, 0.0)
        assert float(summary["max_abs_angle_error_deg"]) < 1.0e-9
        assert int(summary["total_clipped_samples"]) == 0
        assert all(float(row["modulation_depth"]) > 0.999 for row in rows)
    print("self-test passed")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("capture_root", nargs="?", type=Path)
    parser.add_argument("--rx-phase-correction-deg", type=float, default=0.0)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return
    if args.capture_root is None:
        parser.error("capture_root is required unless --self-test is used")
    rows, summary = analyze_root(
        args.capture_root, args.rx_phase_correction_deg
    )
    write_results(args.capture_root, rows, summary)
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
