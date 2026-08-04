#!/usr/bin/env python3
"""Run the local VHDL testbenches against the Bender-resolved RTL graph."""

from __future__ import annotations

import argparse
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
XPM_STUB = ROOT / "tests" / "support" / "xpm_vcomponents_stub.vhd"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Compile and run isolated GHDL tests using Bender source order."
    )
    parser.add_argument(
        "tests",
        nargs="*",
        help="Testbench stems or paths. Defaults to every tests/tb_*.vhd file.",
    )
    parser.add_argument("--ghdl", default="ghdl", help="GHDL executable.")
    parser.add_argument("--bender", default="bender", help="Bender executable.")
    parser.add_argument(
        "--stop-time",
        default="100us",
        help="Per-test simulation stop time. Default: 100us.",
    )
    parser.add_argument("--list", action="store_true", help="List tests and exit.")
    return parser.parse_args()


def require_tool(command: str) -> str:
    resolved = shutil.which(command)
    if resolved is None:
        raise SystemExit(f"ERROR: required tool not found on PATH: {command}")
    return resolved


def bender_vhdl_sources(bender: str) -> list[Path]:
    result = subprocess.run(
        [bender, "script", "flist", "-t", "rtl"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    if result.returncode != 0:
        sys.stderr.write(result.stderr)
        raise SystemExit("ERROR: bender script flist -t rtl failed")

    sources = [
        Path(line.strip())
        for line in result.stdout.splitlines()
        if line.strip().lower().endswith((".vhd", ".vhdl"))
    ]
    if not sources:
        raise SystemExit("ERROR: Bender returned no VHDL RTL sources")
    missing = [path for path in sources if not path.is_file()]
    if missing:
        rendered = "\n".join(f"  {path}" for path in missing)
        raise SystemExit(f"ERROR: Bender returned missing VHDL sources:\n{rendered}")
    return sources


def all_tests() -> list[Path]:
    return sorted((ROOT / "tests").glob("tb_*.vhd"))


def select_tests(requested: list[str]) -> list[Path]:
    available = {path.stem: path for path in all_tests()}
    if not requested:
        return list(available.values())

    selected: list[Path] = []
    for value in requested:
        candidate = Path(value)
        stem = candidate.stem
        if stem not in available:
            names = ", ".join(sorted(available))
            raise SystemExit(f"ERROR: unknown test '{value}'. Available tests: {names}")
        selected.append(available[stem])
    return selected


def run_command(command: list[str], *, cwd: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(command, cwd=cwd, text=True, capture_output=True)


def run_test(
    ghdl: str,
    sources: list[Path],
    test_path: Path,
    stop_time: str,
) -> tuple[bool, str]:
    with tempfile.TemporaryDirectory(prefix=f"ai-trigger-ghdl-{test_path.stem}-") as tmp:
        workdir = Path(tmp)
        common = ["--std=08", f"-P{workdir}", f"--workdir={workdir}"]

        commands = [
            [
                ghdl,
                "-a",
                "--std=08",
                "--work=xpm",
                f"--workdir={workdir}",
                str(XPM_STUB),
            ],
            [ghdl, "-a", *common, *(str(path) for path in sources)],
            [ghdl, "-a", *common, str(test_path)],
            [ghdl, "-e", *common, test_path.stem],
            [
                ghdl,
                "-r",
                *common,
                test_path.stem,
                "--assert-level=error",
                "--ieee-asserts=disable-at-0",
                f"--stop-time={stop_time}",
            ],
        ]

        transcript: list[str] = []
        for command in commands:
            result = run_command(command, cwd=ROOT)
            if result.stdout:
                transcript.append(result.stdout)
            if result.stderr:
                transcript.append(result.stderr)
            if result.returncode != 0:
                transcript.append("COMMAND: " + " ".join(command))
                return False, "".join(transcript)

        output = "".join(transcript)
        if re.search(r"simulation stopped by --stop-time", output, re.IGNORECASE):
            output += f"ERROR: {test_path.stem} reached --stop-time without stopping itself\n"
            return False, output
        return True, output


def main() -> int:
    args = parse_args()
    tests = select_tests(args.tests)
    if args.list:
        for path in tests:
            print(path.stem)
        return 0

    ghdl = require_tool(args.ghdl)
    bender = require_tool(args.bender)
    sources = bender_vhdl_sources(bender)

    failures = 0
    for test_path in tests:
        print(f"[ RUN      ] {test_path.stem}", flush=True)
        passed, output = run_test(ghdl, sources, test_path, args.stop_time)
        if passed:
            print(f"[       OK ] {test_path.stem}", flush=True)
        else:
            failures += 1
            print(output, file=sys.stderr, end="")
            print(f"[  FAILED  ] {test_path.stem}", flush=True)

    passed_count = len(tests) - failures
    print(f"GHDL: {passed_count} passed, {failures} failed, {len(tests)} total")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
