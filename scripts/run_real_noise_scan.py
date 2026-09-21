#!/usr/bin/env python3
"""Scan the repository Data 3 waveforms through the current AI Trigger RTL."""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
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
DATASET_RELATIVE_DIR = Path("data/Amp_Scope_Data_3_Offsetted")
DATASET_CASES = (
    "noise_1_offset",
    "noise_2_offset",
    "noise_3_offset",
    "noise_4_offset",
    "signal_10rms_offset",
    "signal_2rms_offset",
    "signal_3rms_offset",
    "signal_4rms_offset",
)
TRIGGER_MODE_CONTINUOUS_AI = 2


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


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def git_value(repo_root: Path, *args: str) -> str:
    result = subprocess.run(
        ["git", *args],
        cwd=repo_root,
        text=True,
        capture_output=True,
        check=False,
    )
    return result.stdout.strip() if result.returncode == 0 else "unknown"


def dependency_revisions(lock_path: Path) -> dict[str, str]:
    revisions: dict[str, str] = {}
    package = ""
    for line in lock_path.read_text(encoding="utf-8").splitlines():
        package_match = re.fullmatch(r"  ([a-z0-9-]+):", line)
        if package_match:
            package = package_match.group(1)
            continue
        revision_match = re.fullmatch(r"    revision: ([0-9a-f]+)", line)
        if package and revision_match:
            revisions[package] = revision_match.group(1)
    return revisions


def write_provenance(
    repo_root: Path,
    out_root: Path,
    input_paths: list[Path],
    adc_vfs_v: float,
    cnn_thresh_raw: int,
    project: str,
    vivado: str | None,
) -> Path:
    lock_path = repo_root / "Bender.lock"
    status = git_value(repo_root, "status", "--porcelain", "--untracked-files=no")
    tool_paths = (
        Path("scripts/run_real_noise_scan.py"),
        Path("scripts/run_vivado_sim.py"),
        Path("run_sim.tcl"),
        Path("HDL/sim/tb_ai_trigger_top.sv"),
        Path("HDL/sim/AI_TRIGGER_TOP_TB_WRAP.vhd"),
    )
    payload = {
        "schema_version": 1,
        "ai_trigger_commit": git_value(repo_root, "rev-parse", "HEAD"),
        "tracked_worktree_dirty": bool(status),
        "bender_lock_sha256": sha256(lock_path),
        "dependency_revisions": dependency_revisions(lock_path),
        "tool_files": {
            str(path): sha256(repo_root / path)
            for path in tool_paths
        },
        "dataset_root": str(DATASET_RELATIVE_DIR),
        "dataset_files": [
            {
                "name": path.name,
                "sha256": sha256(path),
                "samples": len(load_scope_csv(path)[0]),
            }
            for path in input_paths
        ],
        "scan": {
            "adc_vfs_v": adc_vfs_v,
            "samples_per_window": SAMPLES_PER_CHUNK,
            "window_stride_samples": 1,
            "trigger_channel": 0,
            "other_raw_channels_zero": True,
            "trigger_mode": TRIGGER_MODE_CONTINUOUS_AI,
            "cnn_thresh_raw": cnn_thresh_raw,
            "score_threshold": cnn_thresh_raw / 16.0,
            "input_schedule": "continuous_back_to_back_windows",
            "project": project,
            "vivado_executable": vivado or "PATH/autodetect",
        },
    }
    path = out_root / "scan_provenance.json"
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return path


def read_csv_rows(path: Path) -> list[dict[str, str]]:
    if not path.exists():
        raise SystemExit(f"required CSV not found: {path}")
    with path.open(newline="", encoding="utf-8") as csv_file:
        rows = list(csv.DictReader(csv_file))
    if not rows:
        raise SystemExit(f"CSV has no data rows: {path}")
    return rows


def configure_matplotlib(out_root: Path) -> None:
    mpl_config = out_root / ".mplconfig"
    mpl_config.mkdir(parents=True, exist_ok=True)
    cache_dir = out_root / ".cache"
    cache_dir.mkdir(parents=True, exist_ok=True)
    os.environ.setdefault("MPLCONFIGDIR", str(mpl_config))
    os.environ.setdefault("XDG_CACHE_HOME", str(cache_dir))


def build_input_waveform_plots(input_paths: list[Path], out_root: Path) -> None:
    configure_matplotlib(out_root)

    import matplotlib

    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    waveforms: list[tuple[str, list[float], list[float]]] = []
    for input_path in input_paths:
        times_s, voltages_v = load_scope_csv(input_path)
        times_ns = [value * 1e9 for value in times_s]
        voltages_mv = [value * 1e3 for value in voltages_v]
        waveforms.append((input_path.stem, times_ns, voltages_mv))

        case_dir = out_root / input_path.stem
        case_dir.mkdir(parents=True, exist_ok=True)
        plt.figure(figsize=(10, 4.8))
        plt.plot(times_ns, voltages_mv, linewidth=1.0)
        plt.axhline(0.0, color="black", linewidth=0.8, alpha=0.5)
        plt.xlabel("Time (ns)")
        plt.ylabel("Voltage (mV)")
        plt.title(f"Original 1000-sample waveform: {input_path.stem}")
        plt.grid(True, alpha=0.25)
        plt.tight_layout()
        plt.savefig(case_dir / "input_waveform.png", dpi=160)
        plt.close()

    columns = 2
    rows = math.ceil(len(waveforms) / columns)
    figure, axes = plt.subplots(
        rows,
        columns,
        figsize=(14, 3.2 * rows),
        sharex=True,
        squeeze=False,
    )
    for axis, (case_name, times_ns, voltages_mv) in zip(
        axes.flat,
        waveforms,
    ):
        axis.plot(times_ns, voltages_mv, linewidth=0.9)
        axis.axhline(0.0, color="black", linewidth=0.7, alpha=0.5)
        axis.set_title(case_name)
        axis.set_ylabel("Voltage (mV)")
        axis.grid(True, alpha=0.25)
    for axis in axes[-1]:
        axis.set_xlabel("Time (ns)")
    for axis in axes.flat[len(waveforms):]:
        axis.set_visible(False)
    figure.suptitle("Original Data 3 waveforms (1000 samples each)")
    figure.tight_layout(rect=(0.0, 0.0, 1.0, 0.98))
    figure.savefig(out_root / "input_waveforms_overview.png", dpi=160)
    plt.close(figure)


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


def analyze_results(
    out_root: Path,
    score_threshold: float,
    case_dirs: list[Path] | None = None,
) -> Path:
    if case_dirs is None:
        case_dirs = [
            path for path in out_root.iterdir()
            if path.is_dir() and (path / "manifest.csv").exists()
        ]
    case_dirs = sorted(case_dirs)
    if not case_dirs:
        raise SystemExit(f"no prepared scan cases found under {out_root}")
    summaries = [annotate_case(case_dir, score_threshold) for case_dir in case_dirs]
    summary_path = out_root / "scan_summary.csv"
    with summary_path.open("w", newline="", encoding="utf-8") as csv_file:
        writer = csv.DictWriter(csv_file, fieldnames=list(summaries[0]))
        writer.writeheader()
        writer.writerows(summaries)
    noise_summaries = [
        summary for summary in summaries
        if summary["case_name"].startswith("noise_")
    ]
    if noise_summaries:
        noise_summary_path = out_root / "noise_scan_summary.csv"
        with noise_summary_path.open("w", newline="", encoding="utf-8") as csv_file:
            writer = csv.DictWriter(csv_file, fieldnames=list(noise_summaries[0]))
            writer.writeheader()
            writer.writerows(noise_summaries)
    offset_summaries = [
        summary for summary in summaries
        if summary["case_name"].endswith("_offset")
    ]
    if offset_summaries:
        offset_summary_path = out_root / "offset_scan_summary.csv"
        with offset_summary_path.open("w", newline="", encoding="utf-8") as csv_file:
            writer = csv.DictWriter(csv_file, fieldnames=list(offset_summaries[0]))
            writer.writeheader()
            writer.writerows(offset_summaries)
    build_score_plots(out_root, case_dirs, score_threshold)
    print(f"Wrote {summary_path}")
    return summary_path


def build_score_plots(
    out_root: Path,
    case_dirs: list[Path],
    score_threshold: float,
) -> None:
    configure_matplotlib(out_root)

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
        x_min, x_max = score_plot_limits(scores)
        threshold_label = f"threshold={score_threshold:g}"
        if not x_min <= score_threshold <= x_max:
            threshold_label += " (outside plotted range)"
        plt.axvline(
            score_threshold,
            color="tab:red",
            linestyle="--",
            label=threshold_label,
        )
        plt.xlim(x_min, x_max)
        plt.xlabel("CNN score")
        plt.ylabel("Window count")
        plt.title(f"Real-noise scan score distribution: {case_dir.name}")
        plt.grid(True, alpha=0.25)
        plt.legend()
        plt.tight_layout()
        plt.savefig(case_dir / "score_histogram.png", dpi=160)
        plt.close()

    build_score_overlays(
        out_root,
        score_sets,
        score_threshold,
        file_prefix="",
        title_prefix="Real-noise scan",
    )

    noise_score_sets = [
        score_set for score_set in score_sets
        if score_set[0].startswith("noise_")
    ]
    if noise_score_sets:
        build_score_overlays(
            out_root,
            noise_score_sets,
            score_threshold,
            file_prefix="noise_",
            title_prefix="Pure-noise scan",
        )

    offset_score_sets = [
        score_set for score_set in score_sets
        if score_set[0].endswith("_offset")
    ]
    if offset_score_sets:
        build_score_overlays(
            out_root,
            offset_score_sets,
            score_threshold,
            file_prefix="offset_",
            title_prefix="Offset-corrected scan",
        )


def score_plot_limits(scores: list[float]) -> tuple[float, float]:
    score_min = min(scores)
    score_max = max(scores)
    span = score_max - score_min
    padding = max(span * 0.05, 0.01)
    return score_min - padding, score_max + padding


def build_score_overlays(
    out_root: Path,
    score_sets: list[tuple[str, list[float], list[float]]],
    score_threshold: float,
    *,
    file_prefix: str,
    title_prefix: str,
) -> None:
    import matplotlib.pyplot as plt

    plt.figure(figsize=(10, 5.2))
    for case_name, window_starts, scores in score_sets:
        plt.plot(window_starts, scores, linewidth=1.0, label=case_name)
    plt.axhline(score_threshold, color="black", linestyle="--", label="threshold")
    plt.xlabel("256 ns window start time (ns)")
    plt.ylabel("CNN score")
    plt.title(f"{title_prefix} score vs window start")
    plt.grid(True, alpha=0.25)
    plt.legend()
    plt.tight_layout()
    plt.savefig(out_root / f"{file_prefix}score_vs_window_start_overlay.png", dpi=160)
    plt.close()

    all_scores = [score for _, _, scores in score_sets for score in scores]
    data_min = min(all_scores)
    data_max = max(all_scores)
    if math.isclose(data_min, data_max):
        common_bins = 1
    else:
        bin_width = (data_max - data_min) / 40
        common_bins = [data_min + index * bin_width for index in range(41)]

    plt.figure(figsize=(9, 5.2))
    for case_name, _, scores in score_sets:
        plt.hist(
            scores,
            bins=common_bins,
            alpha=0.5,
            label=case_name,
        )
    x_min, x_max = score_plot_limits(all_scores)
    threshold_label = f"threshold={score_threshold:g}"
    if not x_min <= score_threshold <= x_max:
        threshold_label += " (outside plotted range)"
    plt.axvline(
        score_threshold,
        color="black",
        linestyle="--",
        label=threshold_label,
    )
    plt.xlim(x_min, x_max)
    plt.xlabel("CNN score")
    plt.ylabel("Window count")
    plt.title(f"{title_prefix} score distributions")
    plt.grid(True, alpha=0.25)
    plt.legend()
    plt.tight_layout()
    plt.savefig(out_root / f"{file_prefix}score_histogram_overlay.png", dpi=160)
    plt.close()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prepare-only", action="store_true")
    parser.add_argument("--analyze-only", action="store_true")
    parser.add_argument(
        "--case",
        action="append",
        choices=DATASET_CASES,
        help=(
            "Scan one named repository Data 3 case; repeat to select more. "
            "Defaults to all eight tracked cases."
        ),
    )
    parser.add_argument("--out-dir", type=Path, default=Path("build/real_noise_scan"))
    parser.add_argument("--adc-vfs-v", type=float, default=DEFAULT_ADC_VFS_V)
    parser.add_argument("--cnn-thresh-raw", type=int, default=0)
    parser.add_argument(
        "--project",
        default="AI_Trigger_System/AI_Trigger_System.xpr",
        help="Current AI Trigger Vivado project passed to run_vivado_sim.py.",
    )
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
    if not -(1 << 31) <= args.cnn_thresh_raw < (1 << 31):
        raise SystemExit("--cnn-thresh-raw must fit the signed 32-bit v3.5 interface")
    score_threshold = args.cnn_thresh_raw / 16.0

    repo_root = Path(__file__).resolve().parents[1]
    out_root = args.out_dir if args.out_dir.is_absolute() else repo_root / args.out_dir
    out_root = out_root.resolve()
    if args.analyze_only:
        analyze_results(out_root, score_threshold)
        return
    if args.case and len(set(args.case)) != len(args.case):
        raise SystemExit("duplicate --case selection")
    selected_cases = args.case or list(DATASET_CASES)
    dataset_dir = (repo_root / DATASET_RELATIVE_DIR).resolve()
    expected_paths = {case: dataset_dir / f"{case}.csv" for case in DATASET_CASES}
    missing_paths = [path for path in expected_paths.values() if not path.is_file()]
    if missing_paths:
        raise SystemExit(
            "repository Data 3 dataset is incomplete; missing: "
            + ", ".join(str(path) for path in missing_paths)
        )
    resolved_input_paths = [expected_paths[case] for case in selected_cases]

    out_root.mkdir(parents=True, exist_ok=True)
    provenance = write_provenance(
        repo_root,
        out_root,
        resolved_input_paths,
        args.adc_vfs_v,
        args.cnn_thresh_raw,
        args.project,
        args.vivado,
    )
    print(f"Wrote {provenance}")

    case_dirs = []
    for input_csv in resolved_input_paths:
        case_dirs.append(
            prepare_scope_csv(input_csv, out_root, args.adc_vfs_v)
        )
    build_input_waveform_plots(resolved_input_paths, out_root)

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
            str(score_threshold),
            "--cnn-thresh-raw",
            str(args.cnn_thresh_raw),
            "--mirror-raw-channels",
            "0",
            "--trigger-mode",
            str(TRIGGER_MODE_CONTINUOUS_AI),
            "--project",
            args.project,
        ]
        if args.vivado:
            command.extend(["--vivado", args.vivado])
        print("Running current v3.5 AI Trigger simulation:", " ".join(command))
        subprocess.run(command, cwd=repo_root, check=True)
        if not xsim_log.exists():
            raise SystemExit(f"XSim log not found after simulation: {xsim_log}")
        shutil.copy2(xsim_log, case_dir / "simulate.log")

    analyze_results(out_root, score_threshold, case_dirs)


if __name__ == "__main__":
    main()
