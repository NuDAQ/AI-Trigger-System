#!/usr/bin/env python3
"""Prepare real-noise sliding windows for the AI-trigger simulation."""

from __future__ import annotations

import argparse
import csv
from pathlib import Path


SAMPLES_PER_CHUNK = 256
DEFAULT_ADC_VFS_V = 0.8


def voltage_to_adc_code(voltage_v: float, adc_vfs_v: float) -> int:
    code = round(voltage_v * 4096.0 / adc_vfs_v)
    return max(-2048, min(2047, code))


def pack_ch0_timestep(code: int) -> str:
    return f"{code & 0xFFF:016x}"


def load_scope_csv(path: Path) -> tuple[list[float], list[float]]:
    with path.open(newline="", encoding="utf-8") as csv_file:
        reader = csv.reader(csv_file)
        axis_header = next(reader, None)
        unit_header = next(reader, None)
        if axis_header != ["x-axis", "1"] or unit_header != ["second", "Volt"]:
            raise SystemExit(
                f"unsupported scope CSV header in {path}: "
                "expected 'x-axis,1' followed by 'second,Volt'"
            )
        rows = list(reader)

    if len(rows) < SAMPLES_PER_CHUNK:
        raise SystemExit(
            f"scope CSV needs at least {SAMPLES_PER_CHUNK} samples, got {len(rows)}: {path}"
        )
    try:
        times_s = [float(row[0]) for row in rows]
        voltages_v = [float(row[1]) for row in rows]
    except (IndexError, ValueError) as exc:
        raise SystemExit(f"invalid numeric scope CSV row in {path}") from exc
    return times_s, voltages_v


def prepare_scope_csv(input_csv: Path, out_root: Path, adc_vfs_v: float) -> Path:
    times_s, voltages_v = load_scope_csv(input_csv)
    codes = [voltage_to_adc_code(voltage, adc_vfs_v) for voltage in voltages_v]
    window_count = len(codes) - SAMPLES_PER_CHUNK + 1

    case_dir = out_root / input_csv.stem
    testhex_dir = case_dir / "testhex_stream"
    testhex_dir.mkdir(parents=True, exist_ok=True)

    manifest_rows: list[dict[str, str]] = []
    for sample_id in range(window_count):
        window = codes[sample_id : sample_id + SAMPLES_PER_CHUNK]
        (testhex_dir / f"test_input_sample{sample_id}.hex").write_text(
            "\n".join(pack_ch0_timestep(code) for code in window) + "\n",
            encoding="utf-8",
        )
        manifest_rows.append(
            {
                "sample_id": str(sample_id),
                "source_file": input_csv.name,
                "window_start_index": str(sample_id),
                "window_end_index": str(sample_id + SAMPLES_PER_CHUNK - 1),
                "window_start_ns": f"{times_s[sample_id] * 1e9:.6f}",
                "window_end_ns": (
                    f"{times_s[sample_id + SAMPLES_PER_CHUNK - 1] * 1e9:.6f}"
                ),
            }
        )

    (testhex_dir / "labels.hex").write_text(
        "\n".join("0" for _ in range(window_count)) + "\n",
        encoding="utf-8",
    )
    with (case_dir / "manifest.csv").open("w", newline="", encoding="utf-8") as csv_file:
        writer = csv.DictWriter(csv_file, fieldnames=list(manifest_rows[0]))
        writer.writeheader()
        writer.writerows(manifest_rows)

    print(f"Prepared {window_count} windows from {input_csv} in {case_dir}")
    return case_dir


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prepare-only", action="store_true")
    parser.add_argument("--input-csv", type=Path, action="append", required=True)
    parser.add_argument("--out-dir", type=Path, default=Path("build/real_noise_scan"))
    parser.add_argument("--adc-vfs-v", type=float, default=DEFAULT_ADC_VFS_V)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    if not args.prepare_only:
        raise SystemExit("only --prepare-only is implemented")
    if args.adc_vfs_v <= 0:
        raise SystemExit("--adc-vfs-v must be positive")

    repo_root = Path(__file__).resolve().parents[1]
    out_root = args.out_dir if args.out_dir.is_absolute() else repo_root / args.out_dir
    for input_path in args.input_csv:
        input_csv = input_path if input_path.is_absolute() else repo_root / input_path
        prepare_scope_csv(input_csv.resolve(), out_root.resolve(), args.adc_vfs_v)


if __name__ == "__main__":
    main()
