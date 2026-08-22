#!/usr/bin/env python3
"""Prepare real-noise sliding windows for the AI-trigger simulation."""

from __future__ import annotations

import argparse
import csv
import math
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
from statistics import mean


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
    for sample_index, (left, right) in enumerate(zip(times_s, times_s[1:])):
        if not math.isclose(right - left, 1e-9, rel_tol=1e-6, abs_tol=1e-15):
            raise SystemExit(
                f"expected 1 ns sample spacing in {path}, but samples "
                f"{sample_index}..{sample_index + 1} differ by "
                f"{(right - left) * 1e9:.9f} ns"
            )
    return times_s, voltages_v


def prepare_scope_csv(input_csv: Path, out_root: Path, adc_vfs_v: float) -> Path:
    times_s, voltages_v = load_scope_csv(input_csv)
    raw_codes = [round(voltage * 4096.0 / adc_vfs_v) for voltage in voltages_v]
    codes = [voltage_to_adc_code(voltage, adc_vfs_v) for voltage in voltages_v]
    window_count = len(codes) - SAMPLES_PER_CHUNK + 1

    case_dir = out_root / input_csv.stem
    testhex_dir = case_dir / "testhex_stream"
    testhex_dir.mkdir(parents=True, exist_ok=True)

    manifest_rows: list[dict[str, str]] = []
    for sample_id in range(window_count):
        window = codes[sample_id : sample_id + SAMPLES_PER_CHUNK]
        raw_window = raw_codes[sample_id : sample_id + SAMPLES_PER_CHUNK]
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
                "adc_vfs_v": f"{adc_vfs_v:.6f}",
                "adc_code_min": str(min(window)),
                "adc_code_max": str(max(window)),
                "adc_saturated_samples": str(
                    sum(code < -2048 or code > 2047 for code in raw_window)
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


def read_csv_rows(path: Path) -> list[dict[str, str]]:
    if not path.exists():
        raise SystemExit(f"required CSV not found: {path}")
    with path.open(newline="", encoding="utf-8") as csv_file:
        rows = list(csv.DictReader(csv_file))
    if not rows:
        raise SystemExit(f"CSV has no data rows: {path}")
    return rows


def validate_simulation_health(path: Path) -> None:
    if not path.exists():
        raise SystemExit(f"simulation log not found: {path}")
    log_text = path.read_text(encoding="utf-8", errors="replace")
    counters = {}
    for label in (
        "Chunk overflows",
        "ADC input overflows",
        "Dropped triggers",
        "Ring misses",
    ):
        match = re.search(rf"^{re.escape(label)}:\s+(\d+)", log_text, re.MULTILINE)
        if not match:
            raise SystemExit(f"missing '{label}' counter in {path}")
        counters[label] = int(match.group(1))
    failures = [f"{label}={value}" for label, value in counters.items() if value != 0]
    if failures:
        raise SystemExit(
            f"simulation health check failed for {path.parent.name}: "
            + ", ".join(failures)
        )


def annotate_case(case_dir: Path, score_threshold: float) -> dict[str, str]:
    annotated_path = case_dir / "scores_annotated.csv"
    annotated_path.unlink(missing_ok=True)
    validate_simulation_health(case_dir / "simulate.log")
    manifest_rows = read_csv_rows(case_dir / "manifest.csv")
    score_rows = read_csv_rows(case_dir / "scores.csv")
    manifest_ids = [row["sample_id"] for row in manifest_rows]
    score_ids = [row["sample_id"] for row in score_rows]
    if len(set(manifest_ids)) != len(manifest_ids):
        raise SystemExit(f"duplicate sample_id in {case_dir / 'manifest.csv'}")
    if len(set(score_ids)) != len(score_ids):
        raise SystemExit(f"duplicate sample_id in {case_dir / 'scores.csv'}")

    manifest_id_set = set(manifest_ids)
    score_by_id = {row["sample_id"]: row for row in score_rows}
    missing_ids = [sample_id for sample_id in manifest_ids if sample_id not in score_by_id]
    unexpected_ids = [sample_id for sample_id in score_ids if sample_id not in manifest_id_set]
    if missing_ids or unexpected_ids:
        raise SystemExit(
            f"incomplete score CSV {case_dir / 'scores.csv'}: "
            f"expected {len(manifest_ids)} sample IDs, got {len(score_ids)}; "
            f"missing={missing_ids[:8]}; unexpected={unexpected_ids[:8]}"
        )

    annotated_rows = []
    for manifest_row in manifest_rows:
        combined = dict(manifest_row)
        for key, value in score_by_id[manifest_row["sample_id"]].items():
            if key != "sample_id":
                combined[key] = value
        annotated_rows.append(combined)

    with annotated_path.open("w", newline="", encoding="utf-8") as csv_file:
        writer = csv.DictWriter(csv_file, fieldnames=list(annotated_rows[0]))
        writer.writeheader()
        writer.writerows(annotated_rows)

    scores = [float(row["float_out"]) for row in annotated_rows]
    triggered_windows = sum(score > score_threshold for score in scores)
    return {
        "case_name": case_dir.name,
        "source_file": manifest_rows[0]["source_file"],
        "window_count": str(len(scores)),
        "score_min": f"{min(scores):.6f}",
        "score_max": f"{max(scores):.6f}",
        "score_mean": f"{mean(scores):.6f}",
        "score_threshold": f"{score_threshold:.6f}",
        "triggered_windows": str(triggered_windows),
        "trigger_fraction": f"{triggered_windows / len(scores):.6f}",
    }


def analyze_results(out_root: Path, score_threshold: float) -> Path:
    case_dirs = sorted(
        path for path in out_root.iterdir()
        if path.is_dir() and (path / "manifest.csv").exists()
    )
    if not case_dirs:
        raise SystemExit(f"no prepared scan cases found under {out_root}")
    summaries = [annotate_case(case_dir, score_threshold) for case_dir in case_dirs]
    summary_path = out_root / "scan_summary.csv"
    with summary_path.open("w", newline="", encoding="utf-8") as csv_file:
        writer = csv.DictWriter(csv_file, fieldnames=list(summaries[0]))
        writer.writeheader()
        writer.writerows(summaries)
    build_score_plots(out_root, case_dirs, score_threshold)
    print(f"Wrote {summary_path}")
    return summary_path


def build_score_plots(
    out_root: Path,
    case_dirs: list[Path],
    score_threshold: float,
) -> None:
    mpl_config = out_root / ".mplconfig"
    mpl_config.mkdir(parents=True, exist_ok=True)
    cache_dir = out_root / ".cache"
    cache_dir.mkdir(parents=True, exist_ok=True)
    os.environ.setdefault("MPLCONFIGDIR", str(mpl_config))
    os.environ.setdefault("XDG_CACHE_HOME", str(cache_dir))

    import matplotlib

    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    score_sets: list[tuple[str, list[float], list[float]]] = []
    for case_dir in case_dirs:
        rows = read_csv_rows(case_dir / "scores_annotated.csv")
        window_starts = [float(row["window_start_ns"]) for row in rows]
        scores = [float(row["float_out"]) for row in rows]
        score_sets.append((case_dir.name, window_starts, scores))

        plt.figure(figsize=(10, 4.8))
        plt.plot(window_starts, scores, marker=".", linewidth=1.0)
        plt.axhline(
            score_threshold,
            color="tab:red",
            linestyle="--",
            label=f"threshold={score_threshold:g}",
        )
        plt.xlabel("256 ns window start time (ns)")
        plt.ylabel("CNN score")
        plt.title(f"Real-noise scan score vs window start: {case_dir.name}")
        plt.grid(True, alpha=0.25)
        plt.legend()
        plt.tight_layout()
        plt.savefig(case_dir / "score_vs_window_start.png", dpi=160)
        plt.close()

        plt.figure(figsize=(8, 4.8))
        plt.hist(scores, bins=min(40, max(1, len(scores))))
        plt.axvline(
            score_threshold,
            color="tab:red",
            linestyle="--",
            label=f"threshold={score_threshold:g}",
        )
        plt.xlabel("CNN score")
        plt.ylabel("Window count")
        plt.title(f"Real-noise scan score distribution: {case_dir.name}")
        plt.grid(True, alpha=0.25)
        plt.legend()
        plt.tight_layout()
        plt.savefig(case_dir / "score_histogram.png", dpi=160)
        plt.close()

    plt.figure(figsize=(10, 5.2))
    for case_name, window_starts, scores in score_sets:
        plt.plot(window_starts, scores, linewidth=1.0, label=case_name)
    plt.axhline(score_threshold, color="black", linestyle="--", label="threshold")
    plt.xlabel("256 ns window start time (ns)")
    plt.ylabel("CNN score")
    plt.title("Real-noise scan score vs window start")
    plt.grid(True, alpha=0.25)
    plt.legend()
    plt.tight_layout()
    plt.savefig(out_root / "score_vs_window_start_overlay.png", dpi=160)
    plt.close()

    plt.figure(figsize=(9, 5.2))
    for case_name, _, scores in score_sets:
        plt.hist(
            scores,
            bins=min(40, max(1, len(scores))),
            alpha=0.5,
            label=case_name,
        )
    plt.axvline(score_threshold, color="black", linestyle="--", label="threshold")
    plt.xlabel("CNN score")
    plt.ylabel("Window count")
    plt.title("Real-noise scan score distributions")
    plt.grid(True, alpha=0.25)
    plt.legend()
    plt.tight_layout()
    plt.savefig(out_root / "score_histogram_overlay.png", dpi=160)
    plt.close()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prepare-only", action="store_true")
    parser.add_argument("--analyze-only", action="store_true")
    parser.add_argument(
        "--dataset",
        choices=("all", "signal", "noise"),
        default="all",
        help="Built-in scope dataset to scan when --input-csv is not supplied.",
    )
    parser.add_argument(
        "--input-csv",
        type=Path,
        action="append",
        help=(
            "Scope CSV to scan; repeat for multiple files. Defaults to all CSVs "
            "under data/Amp_Scope_Data_2."
        ),
    )
    parser.add_argument("--out-dir", type=Path, default=Path("build/real_noise_scan"))
    parser.add_argument("--adc-vfs-v", type=float, default=DEFAULT_ADC_VFS_V)
    parser.add_argument("--score-threshold", type=float, default=0.0)
    parser.add_argument("--cnn-thresh-raw", type=int, default=0)
    parser.add_argument("--mirror-raw-channels", type=int, choices=(0, 1), default=0)
    parser.add_argument(
        "--sim-runner",
        type=Path,
        default=Path("scripts/run_vivado_sim.py"),
        help="Simulation launcher. Defaults to scripts/run_vivado_sim.py.",
    )
    parser.add_argument(
        "--xsim-log",
        type=Path,
        default=Path(
            "AI_Trigger_System/AI_Trigger_System.sim/sim_1/behav/xsim/simulate.log"
        ),
        help="XSim simulate.log to preserve after each case.",
    )
    parser.add_argument("--vivado", help="Optional Vivado executable passed to the launcher.")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    if args.prepare_only and args.analyze_only:
        raise SystemExit("--prepare-only and --analyze-only are mutually exclusive")
    if args.adc_vfs_v <= 0:
        raise SystemExit("--adc-vfs-v must be positive")
    expected_threshold_raw = round(args.score_threshold * 2048.0)
    if expected_threshold_raw != args.cnn_thresh_raw:
        raise SystemExit(
            "--score-threshold and --cnn-thresh-raw disagree: "
            f"{args.score_threshold} maps to raw {expected_threshold_raw}, "
            f"not {args.cnn_thresh_raw}"
        )

    repo_root = Path(__file__).resolve().parents[1]
    out_root = args.out_dir if args.out_dir.is_absolute() else repo_root / args.out_dir
    out_root = out_root.resolve()
    if args.analyze_only:
        analyze_results(out_root, args.score_threshold)
        return
    input_paths = args.input_csv
    if input_paths is None:
        input_dirs = {
            "all": ("Amp_Scope_Data_1", "Amp_Scope_Data_2"),
            "noise": ("Amp_Scope_Data_1",),
            "signal": ("Amp_Scope_Data_2",),
        }[args.dataset]
        input_paths = sorted(
            path
            for input_dir in input_dirs
            for path in (repo_root / "data" / input_dir).glob("*.csv")
        )
    if not input_paths:
        raise SystemExit("no scope CSV inputs found")

    resolved_input_paths = []
    case_names = set()
    for input_path in input_paths:
        input_csv = input_path if input_path.is_absolute() else repo_root / input_path
        input_csv = input_csv.resolve()
        if input_csv.stem in case_names:
            raise SystemExit(f"duplicate scan case name '{input_csv.stem}'")
        case_names.add(input_csv.stem)
        resolved_input_paths.append(input_csv)

    case_dirs = []
    for input_csv in resolved_input_paths:
        case_dirs.append(
            prepare_scope_csv(input_csv, out_root, args.adc_vfs_v)
        )

    if args.prepare_only:
        return

    sim_runner = args.sim_runner if args.sim_runner.is_absolute() else repo_root / args.sim_runner
    xsim_log = args.xsim_log if args.xsim_log.is_absolute() else repo_root / args.xsim_log
    for case_dir in case_dirs:
        with (case_dir / "manifest.csv").open(newline="", encoding="utf-8") as csv_file:
            num_samples = sum(1 for _ in csv.DictReader(csv_file))
        command = [
            sys.executable,
            str(sim_runner.resolve()),
            "--num-samples",
            str(num_samples),
            "--testhex-dir",
            str((case_dir / "testhex_stream").resolve()),
            "--out-csv",
            str((case_dir / "scores.csv").resolve()),
            "--event-csv",
            str((case_dir / "events.csv").resolve()),
            "--score-threshold",
            str(args.score_threshold),
            "--cnn-thresh-raw",
            str(args.cnn_thresh_raw),
            "--mirror-raw-channels",
            str(args.mirror_raw_channels),
            "--pace-chunks",
            "1",
        ]
        if args.vivado:
            command.extend(["--vivado", args.vivado])
        print("Running paced simulation:", " ".join(command))
        subprocess.run(command, cwd=repo_root, check=True)
        if not xsim_log.exists():
            raise SystemExit(f"XSim log not found after simulation: {xsim_log}")
        shutil.copy2(xsim_log, case_dir / "simulate.log")

    analyze_results(out_root, args.score_threshold)


if __name__ == "__main__":
    main()
