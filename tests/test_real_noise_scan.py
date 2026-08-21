#!/usr/bin/env python3
"""Public CLI behavior checks for the real-noise sliding-window scan."""

from __future__ import annotations

import csv
import subprocess
import sys
import tempfile
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "run_real_noise_scan.py"


class RealNoiseScanTest(unittest.TestCase):
    def test_prepare_cli_slides_complete_windows_and_quantizes_scope_volts(self) -> None:
        work_dir = Path(tempfile.mkdtemp(prefix="ai-trigger-real-noise-"))
        input_csv = work_dir / "scope.csv"
        out_dir = work_dir / "out"
        voltages = [0.0] * 257
        voltages[0] = 0.050
        voltages[1] = -0.050
        rows = ["x-axis,1", "second,Volt"]
        rows.extend(
            f"{(-100 + sample_index) * 1e-9:.12e},{voltage:.12e}"
            for sample_index, voltage in enumerate(voltages)
        )
        input_csv.write_text("\n".join(rows) + "\n", encoding="utf-8")

        subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                "--prepare-only",
                "--input-csv",
                str(input_csv),
                "--out-dir",
                str(out_dir),
            ],
            cwd=ROOT,
            check=True,
        )

        case_dir = out_dir / "scope"
        with (case_dir / "manifest.csv").open(newline="", encoding="utf-8") as csv_file:
            manifest = list(csv.DictReader(csv_file))
        sample0 = (
            case_dir / "testhex_stream" / "test_input_sample0.hex"
        ).read_text(encoding="utf-8").splitlines()
        sample1 = (
            case_dir / "testhex_stream" / "test_input_sample1.hex"
        ).read_text(encoding="utf-8").splitlines()
        labels = (case_dir / "testhex_stream" / "labels.hex").read_text(
            encoding="utf-8"
        ).splitlines()

        self.assertEqual(len(manifest), 2)
        self.assertEqual(
            [row["window_start_ns"] for row in manifest],
            ["-100.000000", "-99.000000"],
        )
        self.assertEqual(
            [row["window_end_ns"] for row in manifest],
            ["155.000000", "156.000000"],
        )
        self.assertEqual([row["source_file"] for row in manifest], ["scope.csv"] * 2)
        self.assertEqual(labels, ["0", "0"])
        self.assertEqual(len(sample0), 256)
        self.assertEqual(len(sample1), 256)
        self.assertEqual(sample0[:3], [
            "0000000000000100",
            "0000000000000f00",
            "0000000000000000",
        ])
        self.assertEqual(sample1[:2], [
            "0000000000000f00",
            "0000000000000000",
        ])


if __name__ == "__main__":
    unittest.main()
