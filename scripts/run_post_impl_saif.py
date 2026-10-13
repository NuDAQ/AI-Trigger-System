#!/usr/bin/env python3
"""Run routed gate-level xsim to generate SAIF and a power report.

Default flow:
    python3 scripts/run_post_impl_saif.py

The script first builds a routed OOC checkpoint for the production top, then
runs a production-port testbench against the routed netlist, writes SAIF
activity, and feeds that SAIF into Vivado report_power.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import signal
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path


DEFAULT_NPZ = "../CNN-Core-Generator/data/verification_data_2cv_k5s3_f12_es0.npz"


def tcl_quote(value: str | Path) -> str:
    text = str(value)
    return "{" + text.replace("\\", "\\\\").replace("}", "\\}") + "}"


def find_executable(explicit: str | None, env_name: str, program: str) -> str:
    if explicit:
        return explicit

    env_value = os.environ.get(env_name)
    if env_value:
        return env_value

    found = shutil.which(program)
    if found:
        return found

    raise SystemExit(
        f"ERROR: {program} not found. Add it to PATH or pass --{program} /path/to/{program}."
    )


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def validate_reference(
    reference: Path,
    npz: Path,
    start_window: int,
    chunks: int,
) -> dict[str, object]:
    if chunks < 1:
        raise SystemExit("ERROR: --chunks must be positive")
    if start_window < 0:
        raise SystemExit("ERROR: --start-window must be nonnegative")

    manifest_path = reference / "reference.json"
    if not manifest_path.is_file():
        raise SystemExit(f"ERROR: reference manifest not found: {manifest_path}")
    if not npz.is_file():
        raise SystemExit(f"ERROR: NPZ input not found: {npz}")

    try:
        metadata = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise SystemExit(f"ERROR: invalid reference manifest: {exc}") from exc

    if metadata.get("npz_sha256") != sha256(npz):
        raise SystemExit("ERROR: reference npz_sha256 does not match --npz")

    try:
        windows = int(metadata["windows"])
        recorded_files = metadata["files"]
    except (KeyError, TypeError, ValueError) as exc:
        raise SystemExit("ERROR: reference manifest is missing windows or files") from exc
    if start_window + chunks > windows:
        raise SystemExit(
            f"ERROR: requested reference range {start_window}..{start_window + chunks - 1} "
            f"exceeds {windows} available windows"
        )

    for name in ("adc.hex", "all_expected.hex"):
        path = reference / name
        expected = recorded_files.get(name) if isinstance(recorded_files, dict) else None
        if not path.is_file() or not expected:
            raise SystemExit(f"ERROR: reference is missing hashed file: {name}")
        if sha256(path) != expected:
            raise SystemExit(f"ERROR: reference hash mismatch: {name}")
    return metadata


def required_artifacts(out_dir: Path) -> list[Path]:
    return [
        out_dir / "activity" / "ai_trigger_post_impl.saif",
        out_dir / "xsim" / "xsim.log",
        out_dir / "reports" / "post_route_power_saif.rpt",
        out_dir / "reports" / "post_route_utilization_for_saif.rpt",
        out_dir / "reports" / "post_route_timing_summary_for_saif.rpt",
    ]


def clear_required_artifacts(out_dir: Path) -> None:
    for path in required_artifacts(out_dir):
        try:
            path.unlink()
        except FileNotFoundError:
            pass


def validate_outputs(out_dir: Path, chunks: int) -> None:
    for path in required_artifacts(out_dir):
        if not path.is_file() or path.stat().st_size == 0:
            raise SystemExit(f"ERROR: missing required SAIF artifact: {path}")

    transcript = (out_dir / "xsim" / "xsim.log").read_text(
        encoding="utf-8", errors="replace"
    )
    marker = f"PASS production SAIF chunks={chunks}"
    if marker not in transcript:
        raise SystemExit(f"ERROR: XSim completion marker not found: {marker}")


def git_text(repo_root: Path, *args: str) -> str:
    result = subprocess.run(
        ["git", *args],
        cwd=repo_root,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
    )
    return result.stdout.strip() if result.returncode == 0 else "unknown"


def write_run_manifest(
    args: argparse.Namespace,
    repo_root: Path,
    out_dir: Path,
    dcp: Path,
    npz: Path,
    reference: Path,
    reference_metadata: dict[str, object],
    vivado: str,
) -> None:
    source_paths = [
        repo_root / "Bender.lock",
        repo_root / "HDL" / "constraints" / "ai_trigger_ooc.xdc",
        repo_root / "HDL" / "sim" / "tb_ai_trigger_power.sv",
        repo_root / "scripts" / "run_post_impl_saif.py",
        repo_root / "scripts" / "vivado_ooc_build.tcl",
        repo_root / "scripts" / "vivado_post_impl_saif.tcl",
    ]
    outputs = {
        str(path.relative_to(out_dir)): sha256(path)
        for path in required_artifacts(out_dir)
    }
    manifest = {
        "schema_version": 1,
        "generated_utc": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "top": "AI_TRIGGER_TOP",
        "part": args.part,
        "clocks_mhz": {"CLK_ADC": 250, "CLK_CNN": 200},
        "git": {
            "commit": git_text(repo_root, "rev-parse", "HEAD"),
            "branch": git_text(repo_root, "branch", "--show-current"),
            "tracked_worktree_dirty": bool(git_text(repo_root, "status", "--short", "--untracked-files=no")),
        },
        "activity": {
            "chunks": args.chunks,
            "start_window": args.start_window,
            "cnn_thresh_raw": args.cnn_thresh_raw,
            "sdf_mode": args.sdf,
            "saif_start_us": args.saif_start_us,
        },
        "inputs": {
            "npz": str(npz),
            "npz_sha256": sha256(npz),
            "reference": str(reference),
            "reference_manifest_sha256": sha256(reference / "reference.json"),
            "reference_windows": reference_metadata.get("windows"),
            "dcp": str(dcp),
            "dcp_sha256": sha256(dcp),
        },
        "tools": {"vivado": vivado},
        "sources": {
            str(path.relative_to(repo_root)): sha256(path)
            for path in source_paths
            if path.is_file()
        },
        "outputs": outputs,
    }
    (out_dir / "run_manifest.json").write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


def run_process(cmd: list[str], cwd: Path, env: dict[str, str]) -> int:
    print("INFO: running:", " ".join(cmd), flush=True)
    proc = subprocess.Popen(cmd, cwd=cwd, env=env)
    try:
        return proc.wait()
    except KeyboardInterrupt:
        print("\nINFO: interrupt received; terminating Vivado...", flush=True)
        proc.send_signal(signal.SIGINT)
        try:
            return proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            proc.terminate()
            try:
                return proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                proc.kill()
                return proc.wait()


def build_ooc_launcher(args: argparse.Namespace, repo_root: Path, build_dir: Path) -> str:
    return "\n".join(
        [
            "# Auto-generated by scripts/run_post_impl_saif.py",
            f"set ::RUN_BUILD_REPO_ROOT {tcl_quote(repo_root)}",
            f"set ::RUN_BUILD_OUT_DIR {tcl_quote(build_dir)}",
            f"set ::RUN_BUILD_PART {args.part}",
            "set ::RUN_BUILD_TOP AI_TRIGGER_TOP",
            "set ::RUN_BUILD_IMPL 1",
            f"set ::RUN_BUILD_THREADS {args.threads}",
            f"cd {tcl_quote(repo_root)}",
            f"source {tcl_quote(repo_root / 'scripts' / 'vivado_ooc_build.tcl')}",
            "exit",
            "",
        ]
    )


def build_saif_launcher(
    args: argparse.Namespace,
    repo_root: Path,
    dcp: Path,
    out_dir: Path,
    reference: Path,
) -> str:
    lines = [
        "# Auto-generated by scripts/run_post_impl_saif.py",
        f"set_param general.maxThreads {args.threads}",
        f"set ::RUN_SAIF_REPO_ROOT {tcl_quote(repo_root)}",
        f"set ::RUN_SAIF_DCP {tcl_quote(dcp)}",
        f"set ::RUN_SAIF_OUT_DIR {tcl_quote(out_dir)}",
        f"set ::RUN_SAIF_REFERENCE {tcl_quote(reference)}",
        f"set ::RUN_SAIF_CHUNKS {args.chunks}",
        f"set ::RUN_SAIF_START_WINDOW {args.start_window}",
        f"set ::RUN_SAIF_CNN_THRESH_RAW {args.cnn_thresh_raw}",
        f"set ::RUN_SAIF_SDF_MODE {args.sdf}",
        f"set ::RUN_SAIF_START_US {args.saif_start_us}",
        f"set ::RUN_SAIF_MIN_OBJECTS {args.saif_min_objects}",
    ]
    lines.extend(
        [
            f"cd {tcl_quote(repo_root)}",
            f"source {tcl_quote(repo_root / 'scripts' / 'vivado_post_impl_saif.tcl')}",
            "exit",
            "",
        ]
    )
    return "\n".join(lines)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Generate post-implementation SAIF activity and a Vivado power report."
    )
    parser.add_argument(
        "--vivado",
        help="Vivado executable path. Defaults to $VIVADO or vivado in PATH.",
    )
    parser.add_argument(
        "--bender",
        help="Bender executable path. Defaults to $BENDER or bender in PATH.",
    )
    parser.add_argument(
        "--build-dir",
        default="build/vivado_ooc_ai_trigger",
        help="OOC implementation directory for the production AI_TRIGGER_TOP checkpoint.",
    )
    parser.add_argument(
        "--out-dir",
        default="build/vivado_post_impl_saif_30chunks",
        help="Output directory for netlist, xsim files, SAIF, and reports.",
    )
    parser.add_argument(
        "--dcp",
        help="Use an existing routed AI_TRIGGER_TOP checkpoint instead of rebuilding it.",
    )
    parser.add_argument(
        "--skip-build",
        action="store_true",
        help="Do not rebuild the production OOC checkpoint before gate simulation.",
    )
    parser.add_argument(
        "--chunks",
        "--samples",
        dest="chunks",
        type=int,
        default=30,
        help="Number of 256-sample acquisition chunks to simulate. Default: 30.",
    )
    parser.add_argument(
        "--reference",
        default="build/native_validation/reference",
        help="ADC-aware native reference directory containing adc.hex and all_expected.hex.",
    )
    parser.add_argument(
        "--npz",
        default=DEFAULT_NPZ,
        help="Original NPZ used to build the native reference.",
    )
    parser.add_argument(
        "--start-window",
        type=int,
        default=96,
        help="First reference window to simulate. Default: 96, the first supplied NPZ window.",
    )
    parser.add_argument(
        "--sdf",
        choices=["none", "min", "typ", "max"],
        default="none",
        help="SDF annotation mode. Use none for faster SAIF; max for a short timing smoke test.",
    )
    parser.add_argument(
        "--saif-start-us",
        type=float,
        default=0.5,
        help="Delay before SAIF recording starts, in microseconds. Default: 0.5.",
    )
    parser.add_argument(
        "--saif-min-objects",
        type=int,
        default=1000,
        help="Fail if SAIF logging matches fewer objects than this. Default: 1000.",
    )
    parser.add_argument(
        "--cnn-thresh-raw",
        type=int,
        default=0,
        help="Signed external CNN_THRESH word driven into the DUT (unit 1/16).",
    )
    parser.add_argument(
        "--part",
        default="xcku5p-ffvb676-2-e",
        help="Target FPGA part used when building the production checkpoint.",
    )
    parser.add_argument(
        "--threads",
        type=int,
        default=8,
        help="Vivado general.maxThreads value.",
    )
    parser.add_argument(
        "--keep-tcl",
        action="store_true",
        help="Keep generated launcher Tcl files.",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    repo_root = Path(__file__).resolve().parents[1]

    build_dir = Path(args.build_dir).expanduser()
    if not build_dir.is_absolute():
        build_dir = repo_root / build_dir
    build_dir.mkdir(parents=True, exist_ok=True)

    out_dir = Path(args.out_dir).expanduser()
    if not out_dir.is_absolute():
        out_dir = repo_root / out_dir
    out_dir.mkdir(parents=True, exist_ok=True)

    reference = Path(args.reference).expanduser()
    if not reference.is_absolute():
        reference = repo_root / reference
    reference = reference.resolve()

    npz = Path(args.npz).expanduser()
    if not npz.is_absolute():
        npz = repo_root / npz
    npz = npz.resolve()
    reference_metadata = validate_reference(
        reference, npz, args.start_window, args.chunks
    )

    if args.dcp:
        dcp = Path(args.dcp).expanduser()
        if not dcp.is_absolute():
            dcp = repo_root / dcp
    else:
        dcp = build_dir / "checkpoints" / "post_route.dcp"

    vivado = find_executable(args.vivado, "VIVADO", "vivado")
    env = os.environ.copy()
    vivado_dir = str(Path(vivado).resolve().parent)
    env["PATH"] = vivado_dir + os.pathsep + env.get("PATH", "")

    if not args.skip_build:
        bender = find_executable(args.bender, "BENDER", "bender")
        bender_dir = str(Path(bender).resolve().parent)
        env["PATH"] = bender_dir + os.pathsep + env.get("PATH", "")

        build_gen_dir = build_dir / "generated"
        build_gen_dir.mkdir(parents=True, exist_ok=True)
        build_tcl = build_gen_dir / "run_vivado_ooc_build.tcl"
        build_tcl.write_text(build_ooc_launcher(args, repo_root, build_dir), encoding="utf-8")
        ret = run_process([vivado, "-mode", "batch", "-source", str(build_tcl)], repo_root, env)
        if ret != 0:
            return ret
        if not args.keep_tcl:
            try:
                build_tcl.unlink()
            except OSError:
                pass

    if not dcp.exists():
        raise SystemExit(f"ERROR: routed checkpoint not found: {dcp}")

    saif_gen_dir = out_dir / "generated"
    saif_gen_dir.mkdir(parents=True, exist_ok=True)
    saif_tcl = saif_gen_dir / "run_vivado_post_impl_saif.tcl"
    saif_tcl.write_text(
        build_saif_launcher(args, repo_root, dcp, out_dir, reference),
        encoding="utf-8",
    )
    clear_required_artifacts(out_dir)
    ret = run_process([vivado, "-mode", "batch", "-source", str(saif_tcl)], repo_root, env)
    if not args.keep_tcl:
        try:
            saif_tcl.unlink()
        except OSError:
            pass
    if ret != 0:
        return ret
    validate_outputs(out_dir, args.chunks)
    write_run_manifest(
        args,
        repo_root,
        out_dir,
        dcp.resolve(),
        npz,
        reference,
        reference_metadata,
        vivado,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
