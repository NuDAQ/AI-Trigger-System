#!/usr/bin/env python3
"""Run the same testhex stream through all five runtime trigger modes."""

from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
from pathlib import Path


MODES = range(5)


def find_default_testhex(repo_root: Path) -> Path:
    pattern = (
        ".bender/git/checkouts/cnn-core-wrapper-*/cnn_core_wrapper/"
        "cnn_core_wrapper.sim/sim_1/behav/xsim/testhex_stream"
    )
    candidates = sorted(path for path in repo_root.glob(pattern) if path.is_dir())
    if not candidates:
        raise SystemExit("ERROR: Bender testhex_stream not found; pass --testhex-dir")
    return candidates[0].resolve()


def build_mode_command(
    args: argparse.Namespace,
    repo_root: Path,
    testhex_dir: Path,
    mode_dir: Path,
    mode: int,
) -> list[str]:
    command = [
        sys.executable,
        str(repo_root / "scripts" / "run_vivado_sim.py"),
        "--project",
        str(args.project),
        "--num-samples",
        str(args.num_samples),
        "--testhex-dir",
        str(testhex_dir),
        "--out-csv",
        str((mode_dir / "scores.csv").resolve()),
        "--event-csv",
        str((mode_dir / "events.csv").resolve()),
        "--score-threshold",
        str(args.score_threshold),
        "--cnn-thresh-raw",
        str(args.cnn_thresh_raw),
        "--mirror-raw-channels",
        "1",
        "--trigger-mode",
        str(mode),
        "--force-trigger-interval",
        str(args.force_trigger_interval),
        "--force-trigger-beat",
        str(args.force_trigger_beat),
        "--hl-thresh",
        str(args.hl_thresh),
        "--hilo-window",
        str(args.hilo_window),
        "--coinc-window",
        str(args.coinc_window),
        "--bin-thr",
        str(args.bin_thr),
    ]
    if args.vivado:
        command.extend(["--vivado", str(args.vivado)])
    return command


def simulation_log(repo_root: Path, project_arg: Path) -> Path:
    project = project_arg.expanduser()
    if not project.is_absolute():
        project = repo_root / project
    project = project.resolve()
    return (
        project.parent
        / f"{project.stem}.sim"
        / "sim_1"
        / "behav"
        / "xsim"
        / "simulate.log"
    )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--project",
        type=Path,
        default=Path("AI_Trigger_System/AI_Trigger_System.xpr"),
    )
    parser.add_argument("--vivado", type=Path)
    parser.add_argument("--testhex-dir", type=Path)
    parser.add_argument("--x-npy", type=Path, default=Path("data/X_test_data.npy"))
    parser.add_argument("--output-dir", type=Path, default=Path("build/trigger_mode_sweep"))
    parser.add_argument("--num-samples", type=int, default=1000)
    parser.add_argument("--score-threshold", type=float, default=0.0)
    parser.add_argument("--cnn-thresh-raw", type=int, default=0)
    parser.add_argument("--force-trigger-interval", type=int, default=4)
    parser.add_argument("--force-trigger-beat", type=int, default=31)
    parser.add_argument("--hl-thresh", type=int, default=192)
    parser.add_argument("--hilo-window", type=int, default=5)
    parser.add_argument("--coinc-window", type=int, default=32)
    parser.add_argument("--bin-thr", type=int, default=2)
    parser.add_argument("--analyze-only", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    repo_root = Path(__file__).resolve().parents[1]
    testhex_dir = (
        args.testhex_dir.expanduser().resolve()
        if args.testhex_dir
        else find_default_testhex(repo_root)
    )
    output_dir = args.output_dir.expanduser()
    if not output_dir.is_absolute():
        output_dir = repo_root / output_dir
    output_dir = output_dir.resolve()
    output_dir.mkdir(parents=True, exist_ok=True)

    labels = testhex_dir / "labels.hex"
    if not labels.is_file():
        raise SystemExit(f"ERROR: labels.hex not found: {labels}")

    if not args.analyze_only:
        source_log = simulation_log(repo_root, args.project)
        for mode in MODES:
            mode_dir = output_dir / f"mode_{mode:04b}"
            mode_dir.mkdir(parents=True, exist_ok=True)
            command = build_mode_command(args, repo_root, testhex_dir, mode_dir, mode)
            print(f"INFO: running trigger mode {mode:04b}", flush=True)
            subprocess.run(command, cwd=repo_root, check=True)
            if not source_log.is_file():
                raise SystemExit(f"ERROR: Vivado did not produce {source_log}")
            shutil.copy2(source_log, mode_dir / "simulate.log")

    x_npy = args.x_npy.expanduser()
    if not x_npy.is_absolute():
        x_npy = repo_root / x_npy
    analyze_command = [
        sys.executable,
        str(repo_root / "scripts" / "analyze_trigger_mode_sweep.py"),
        "--sweep-dir",
        str(output_dir),
        "--labels",
        str(labels),
        "--force-trigger-interval",
        str(args.force_trigger_interval),
        "--hl-thresh",
        str(args.hl_thresh),
        "--hilo-window",
        str(args.hilo_window),
        "--coinc-window",
        str(args.coinc_window),
        "--bin-thr",
        str(args.bin_thr),
        "--output",
        str(output_dir / "summary.json"),
    ]
    if x_npy.is_file() and args.num_samples == 1000:
        analyze_command.extend(["--x-npy", str(x_npy.resolve())])
    subprocess.run(analyze_command, cwd=repo_root, check=True)
    print(f"INFO: mode sweep complete: {output_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
