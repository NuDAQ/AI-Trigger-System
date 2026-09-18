#!/usr/bin/env python3
"""Build a small self-contained DAQ delivery package."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import zipfile


ROOT = Path(__file__).resolve().parents[1]
PACKAGE_PREFIX = "ai-trigger-daq"
DELIVERY_ASSETS = [
    ROOT / "docs" / "score_vs_offset.png",
]
HILO_RTL_ORDER = [
    "PRE_TRIGGER_PKG.vhd",
    "Mult_to_bin.vhd",
    "Pre_trigger_1ch.vhd",
    "Pre_trigger.vhd",
]


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
        raise RuntimeError("Bender source resolution failed: " + result.stderr.strip())
    packages = json.loads(result.stdout)
    files = [Path(item) for package in packages for item in package.get("files", [])
             if Path(item).suffix.lower() in {".v", ".sv", ".vhd", ".vhdl", ".vh", ".dat"}]
    if not files or any(not path.is_file() for path in files):
        raise FileNotFoundError("Bender source closure is empty or contains missing assets")
    return files


def cnn_core_sources(bender_sources: list[Path]) -> list[Path]:
    tops = [path for path in bender_sources if path.name == "cnn_core.v"]
    if len(tops) != 1:
        raise ValueError("Bender must resolve exactly one generated cnn_core.v")
    return [path for path in bender_sources if path.parent == tops[0].parent]


def wrapper_sources(bender_sources: list[Path]) -> list[Path]:
    sources = [path for path in bender_sources if path.name == "cnn_core_wrapper_top.v"]
    if len(sources) != 1:
        raise ValueError("Bender must resolve exactly one CNN wrapper")
    return sources


def hilo_trigger_sources(bender_sources: list[Path]) -> list[Path]:
    sources = []
    for name in HILO_RTL_ORDER:
        matches = [path for path in bender_sources if path.name.lower() == name.lower()]
        if len(matches) != 1:
            raise ValueError("Bender must resolve exactly one " + name)
        sources.extend(matches)
    return sources


def ai_trigger_sources(bender_sources: list[Path]) -> list[Path]:
    sources = [path for path in bender_sources if path.is_relative_to(ROOT / "HDL/rtl")]
    if not sources:
        raise ValueError("Bender did not resolve AI trigger RTL")
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
            "# Keep the integrator's existing project top unchanged.",
            "# Instantiate AI_TRIGGER_TOP from the system top, or set it manually for standalone OOC checks.",
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
    core_revision = "unknown"
    lock = ROOT / "Bender.lock"
    if lock.exists():
        match = re.search(r"cnn-core-wrapper:.*?revision:\s*([0-9a-f]+)", lock.read_text(encoding="utf-8"), re.S)
        if match:
            wrapper_revision = match.group(1)
        match = re.search(r"cnn-core:.*?revision:\s*([0-9a-f]+)", lock.read_text(encoding="utf-8"), re.S)
        if match:
            core_revision = match.group(1)

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
            "cnn-core revision: " + core_revision,
            "CNN lanes: 2",
            "CNN input: 32 x 512-bit transfers per 256 x 4 window",
            "Score format: signed low 21 bits / 512",
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


def write_package_readme(package_dir: Path) -> list[Path]:
    readme_text = (ROOT / "docs" / "Deliverables.md").read_text(encoding="utf-8")
    copied: list[Path] = []

    for source in DELIVERY_ASSETS:
        if not source.exists():
            raise FileNotFoundError(f"Missing delivery asset: {source}")
        asset_rel = Path("assets") / source.name
        asset_dest = package_dir / asset_rel
        asset_dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, asset_dest)
        copied.append(asset_rel)

        source_text = str(source)
        readme_text = readme_text.replace(source_text, asset_rel.as_posix())

    (package_dir / "README.md").write_text(readme_text, encoding="utf-8")
    return [Path("README.md"), *copied]


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
    core_sources = cnn_core_sources(bender_sources)
    wrap_sources = wrapper_sources(bender_sources)
    hilo_sources = hilo_trigger_sources(bender_sources)
    ai_sources = ai_trigger_sources(bender_sources)

    copied_files: list[Path] = write_package_readme(package_dir)
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

    for source in hilo_sources:
        dest = package_dir / "rtl" / "hilo-trigger" / source.name
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

    # Hash every delivered source, header, ROM and document, so a package can
    # be audited without the source checkout or personal Bender overrides.
    checksums = [f"{hashlib.sha256(path.read_bytes()).hexdigest()}  {path.relative_to(package_dir).as_posix()}"
                 for path in sorted(package_dir.rglob("*")) if path.is_file()]
    (package_dir / "SHA256SUMS").write_text("\n".join(checksums) + "\n")

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
