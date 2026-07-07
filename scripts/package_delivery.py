#!/usr/bin/env python3
"""Build a small self-contained DAQ delivery package."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
from datetime import datetime, timezone
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import zipfile


ROOT = Path(__file__).resolve().parents[1]
CORE_RTL_REL = Path("hls_streaming/cnn_core_streaming_prj/solution1/impl/verilog")
PACKAGE_PREFIX = "ai-trigger-daq"


@dataclass(frozen=True)
class CopiedSource:
    source_label: str
    package_path: Path


def run(cmd: list[str], cwd: Path = ROOT, check: bool = False) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        cmd,
        cwd=cwd,
        check=check,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )


def git_value(args: list[str], default: str) -> str:
    result = run(["git", *args])
    if result.returncode == 0:
        value = result.stdout.strip()
        if value:
            return value
    return default


def git_dirty_suffix() -> str:
    result = run(["git", "status", "--short"])
    if result.returncode == 0 and result.stdout.strip():
        return "-dirty"
    return ""


def sanitize_version(version: str) -> str:
    value = version.strip()
    if not value:
        raise ValueError("version must not be empty")
    return re.sub(r"[^A-Za-z0-9._-]+", "-", value)


def parse_bender_sources() -> list[Path]:
    result = run(["bender", "sources", "-f", "-t", "vivado"])
    if result.returncode != 0:
        return []

    text = result.stdout
    start = text.find("[")
    end = text.rfind("]")
    if start < 0 or end < start:
        return []

    try:
        packages = json.loads(text[start : end + 1])
    except json.JSONDecodeError:
        return []

    files: list[Path] = []
    for package in packages:
        for item in package.get("files", []):
            path = Path(item)
            if path.suffix.lower() in {".v", ".sv", ".vhd", ".vhdl"}:
                files.append(path)
    return files


def parse_ai_trigger_sources_from_bender_yml() -> list[Path]:
    sources: list[Path] = []
    in_sources = False
    for line in (ROOT / "Bender.yml").read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        if stripped == "sources:":
            in_sources = True
            continue
        if not in_sources:
            continue
        if stripped.startswith("- target:"):
            break
        match = re.match(r"-\s+(HDL/rtl/[^#\s]+)", stripped)
        if match:
            sources.append(ROOT / match.group(1))
    return sources


def parse_cnn_core_override_path() -> Path | None:
    path = ROOT / "Bender.local"
    if not path.exists():
        return None

    text = path.read_text(encoding="utf-8")
    match = re.search(r"cnn-core:\s*\{\s*path:\s*\"([^\"]+)\"", text)
    if not match:
        return None
    return Path(match.group(1)).expanduser()


def parse_cnn_core_lock_path() -> Path | None:
    path = ROOT / "Bender.lock"
    if not path.exists():
        return None

    in_core = False
    for line in path.read_text(encoding="utf-8").splitlines():
        if re.match(r"\s{2}cnn-core:\s*$", line):
            in_core = True
            continue
        if in_core and re.match(r"\s{2}[A-Za-z0-9_-]+:\s*$", line):
            return None
        match = re.match(r"\s{6}Path:\s*(.+)\s*$", line)
        if in_core and match:
            return Path(match.group(1)).expanduser()
    return None


def find_cnn_core_verilog_dir() -> Path:
    candidates: list[Path] = []
    for base in (parse_cnn_core_override_path(), parse_cnn_core_lock_path()):
        if base is not None:
            candidates.append(base / CORE_RTL_REL)
    candidates.extend(ROOT.glob(".bender/git/checkouts/cnn-core-*/" + str(CORE_RTL_REL)))

    for candidate in candidates:
        if (candidate / "cnn_core.v").exists():
            return candidate

    searched = "\n".join(str(path) for path in candidates) or "(no candidates)"
    raise FileNotFoundError(
        "Could not find generated cnn-core Verilog. Run bender update/checkouts "
        "or set Bender.local cnn-core path.\nSearched:\n" + searched
    )


def cnn_core_sources() -> list[Path]:
    source_dir = find_cnn_core_verilog_dir()
    files = sorted(source_dir.glob("*.v"))
    files.sort(key=lambda path: (path.name != "cnn_core.v", path.name))
    return files


def wrapper_sources(bender_sources: list[Path]) -> list[Path]:
    sources = [
        path
        for path in bender_sources
        if path.name == "cnn_core_wrapper_top.v" and path.exists()
    ]
    if sources:
        return sources

    sources = sorted(ROOT.glob(".bender/git/checkouts/cnn-core-wrapper-*/hw/rtl/cnn_core_wrapper_top.v"))
    if sources:
        return [sources[0]]

    raise FileNotFoundError("Could not find cnn_core_wrapper_top.v from Bender sources or .bender checkout")


def ai_trigger_sources(bender_sources: list[Path]) -> list[Path]:
    sources = [
        path
        for path in bender_sources
        if path.is_relative_to(ROOT / "HDL" / "rtl") and path.exists()
    ]
    if sources:
        return sources

    sources = parse_ai_trigger_sources_from_bender_yml()
    missing = [path for path in sources if not path.exists()]
    if missing:
        raise FileNotFoundError("Missing AI trigger RTL source: " + ", ".join(str(path) for path in missing))
    return sources


def copy_sources(paths: list[Path], dest_dir: Path, source_root: Path | None = None) -> list[CopiedSource]:
    copied: list[CopiedSource] = []
    dest_dir.mkdir(parents=True, exist_ok=True)
    for path in paths:
        dest = dest_dir / path.name
        shutil.copy2(path, dest)
        if source_root is not None:
            try:
                label = str(path.relative_to(source_root))
            except ValueError:
                label = path.name
        else:
            label = path.name
        copied.append(CopiedSource(label, dest.relative_to(dest_dir.parents[1])))
    return copied


def tcl_path(path: Path) -> str:
    return " ".join(path.parts)


def write_add_files_tcl(package_dir: Path, rtl_paths: list[Path]) -> None:
    script_dir = package_dir / "scripts"
    script_dir.mkdir(parents=True, exist_ok=True)
    lines = [
        "# Vivado source list for the AI Trigger DAQ delivery package.",
        "# Source this file after creating/opening a Vivado project.",
        "",
        "set PKG_ROOT [file normalize [file join [file dirname [info script]] ..]]",
        "",
        "add_files -norecurse -fileset [current_fileset] [list \\",
    ]
    for path in rtl_paths:
        lines.append(f"    [file join $PKG_ROOT {tcl_path(path)}] \\")
    lines.extend(
        [
            "]",
            "",
            "add_files -fileset constrs_1 [file join $PKG_ROOT constraints ai_trigger_ooc.xdc]",
            "",
            "set_property top AI_TRIGGER_TOP [current_fileset]",
            "set_property target_language VHDL [current_project]",
            "set_property simulator_language Mixed [current_project]",
            "set_property verilog_define [list TARGET_FPGA TARGET_SYNTHESIS TARGET_VIVADO TARGET_XILINX] [current_fileset]",
            "update_compile_order -fileset sources_1",
            "",
        ]
    )
    (script_dir / "add_files.tcl").write_text("\n".join(lines), encoding="utf-8")


def write_version(package_dir: Path, version: str) -> None:
    commit = git_value(["rev-parse", "--short=12", "HEAD"], "unknown") + git_dirty_suffix()
    branch = git_value(["branch", "--show-current"], "unknown")
    wrapper_revision = "unknown"
    lock = ROOT / "Bender.lock"
    if lock.exists():
        match = re.search(r"cnn-core-wrapper:.*?revision:\s*([0-9a-f]+)", lock.read_text(encoding="utf-8"), re.S)
        if match:
            wrapper_revision = match.group(1)

    content = "\n".join(
        [
            f"Package: {PACKAGE_PREFIX}-{version}",
            f"Source commit: {commit}",
            f"Source branch: {branch}",
            f"Generated UTC: {datetime.now(timezone.utc).isoformat(timespec='seconds')}",
            "Top: AI_TRIGGER_TOP",
            "Vivado target: 2023.2",
            "Device used for OOC reports: xcku5p-ffvb676-2-e",
            "CLK_ADC target: 250 MHz",
            "CLK_CNN target: 200 MHz",
            "cnn-core-wrapper revision: " + wrapper_revision,
            "",
        ]
    )
    (package_dir / "VERSION.txt").write_text(content, encoding="utf-8")


def write_manifest(package_dir: Path, files: list[Path]) -> None:
    lines = [
        "AI Trigger DAQ delivery package",
        "",
        "This package contains only the files needed for first DAQ integration testing.",
        "Use scripts/add_files.tcl to add RTL and constraints to a Vivado project.",
        "",
        "Files:",
    ]
    for path in sorted(files, key=lambda item: str(item)):
        lines.append(f"- {path.as_posix()}")
    lines.append("")
    (package_dir / "MANIFEST.txt").write_text("\n".join(lines), encoding="utf-8")


def create_zip(package_dir: Path) -> Path:
    zip_path = package_dir.parent / f"{package_dir.name}.zip"
    if zip_path.exists():
        zip_path.unlink()
    with zipfile.ZipFile(zip_path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for path in sorted(package_dir.rglob("*")):
            if path.is_file():
                archive.write(path, path.relative_to(package_dir.parent))
    return zip_path


def build_package(version: str, out_dir: Path, make_zip: bool) -> Path:
    version = sanitize_version(version)
    package_dir = out_dir / f"{PACKAGE_PREFIX}-{version}"
    if package_dir.exists():
        shutil.rmtree(package_dir)
    package_dir.mkdir(parents=True)

    bender_sources = parse_bender_sources()
    core_sources = cnn_core_sources()
    wrap_sources = wrapper_sources(bender_sources)
    ai_sources = ai_trigger_sources(bender_sources)

    shutil.copy2(ROOT / "docs" / "Deliverables.md", package_dir / "README.md")

    copied_files: list[Path] = [Path("README.md")]
    rtl_paths: list[Path] = []

    for source in core_sources:
        dest = package_dir / "rtl" / "cnn-core" / source.name
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, dest)
        rel = dest.relative_to(package_dir)
        copied_files.append(rel)
        rtl_paths.append(rel)

    for source in wrap_sources:
        dest = package_dir / "rtl" / "cnn-core-wrapper" / "hw" / "rtl" / source.name
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, dest)
        rel = dest.relative_to(package_dir)
        copied_files.append(rel)
        rtl_paths.append(rel)

    for source in ai_sources:
        dest = package_dir / "rtl" / "ai-trigger" / source.name
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, dest)
        rel = dest.relative_to(package_dir)
        copied_files.append(rel)
        rtl_paths.append(rel)

    constraints_dir = package_dir / "constraints"
    constraints_dir.mkdir(parents=True, exist_ok=True)
    shutil.copy2(ROOT / "HDL" / "constraints" / "ai_trigger_ooc.xdc", constraints_dir / "ai_trigger_ooc.xdc")
    copied_files.append(Path("constraints/ai_trigger_ooc.xdc"))

    write_add_files_tcl(package_dir, rtl_paths)
    copied_files.append(Path("scripts/add_files.tcl"))

    write_version(package_dir, version)
    copied_files.append(Path("VERSION.txt"))

    write_manifest(package_dir, copied_files + [Path("MANIFEST.txt")])

    if make_zip:
        zip_path = create_zip(package_dir)
        print(f"Wrote {zip_path}")
    print(f"Wrote {package_dir}")
    return package_dir


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--version",
        default=git_value(["describe", "--tags", "--always"], "untagged"),
        help="Delivery package version suffix.",
    )
    parser.add_argument(
        "--out-dir",
        default=str(ROOT / "dist"),
        help="Output directory for the generated package.",
    )
    parser.add_argument("--no-zip", action="store_true", help="Do not create a zip archive.")
    args = parser.parse_args(argv)

    try:
        build_package(args.version, Path(args.out_dir), make_zip=not args.no_zip)
    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
