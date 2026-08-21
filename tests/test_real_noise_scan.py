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

    def test_prepare_cli_discovers_all_scope_files_and_writes_745_windows_each(self) -> None:
        out_dir = Path(tempfile.mkdtemp(prefix="ai-trigger-real-noise-data-"))

        subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                "--prepare-only",
                "--out-dir",
                str(out_dir),
            ],
            cwd=ROOT,
            check=True,
        )

        self.assertEqual(
            sorted(path.name for path in out_dir.iterdir() if path.is_dir()),
            ["signal_10", "signal_2", "signal_3", "signal_4"],
        )
        for case_name in ("signal_10", "signal_2", "signal_3", "signal_4"):
            with (out_dir / case_name / "manifest.csv").open(
                newline="", encoding="utf-8"
            ) as csv_file:
                manifest = list(csv.DictReader(csv_file))
            self.assertEqual(len(manifest), 745)
            self.assertEqual(manifest[0]["window_start_ns"], "-100.000000")
            self.assertEqual(manifest[-1]["window_start_ns"], "644.000000")
            self.assertEqual(manifest[-1]["window_end_ns"], "899.000000")

    def test_prepare_cli_rejects_scope_data_without_one_ns_spacing(self) -> None:
        work_dir = Path(tempfile.mkdtemp(prefix="ai-trigger-real-noise-spacing-"))
        input_csv = work_dir / "bad_spacing.csv"
        out_dir = work_dir / "out"
        rows = ["x-axis,1", "second,Volt"]
        for sample_index in range(256):
            time_ns = -100 + sample_index
            if sample_index == 128:
                time_ns += 0.5
            rows.append(f"{time_ns * 1e-9:.12e},0.0")
        input_csv.write_text("\n".join(rows) + "\n", encoding="utf-8")

        result = subprocess.run(
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
            check=False,
            text=True,
            capture_output=True,
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("1 ns sample spacing", result.stderr)

    def test_prepare_cli_records_adc_conversion_and_saturation(self) -> None:
        work_dir = Path(tempfile.mkdtemp(prefix="ai-trigger-real-noise-adc-"))
        input_csv = work_dir / "saturation.csv"
        out_dir = work_dir / "out"
        voltages = [0.0] * 256
        voltages[0] = -0.500
        voltages[1] = 0.500
        rows = ["x-axis,1", "second,Volt"]
        rows.extend(
            f"{sample_index * 1e-9:.12e},{voltage:.12e}"
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

        with (out_dir / "saturation" / "manifest.csv").open(
            newline="", encoding="utf-8"
        ) as csv_file:
            manifest_row = next(csv.DictReader(csv_file))
        sample = (
            out_dir / "saturation" / "testhex_stream" / "test_input_sample0.hex"
        ).read_text(encoding="utf-8").splitlines()

        self.assertEqual(sample[:2], ["0000000000000800", "00000000000007ff"])
        self.assertEqual(manifest_row["adc_vfs_v"], "0.800000")
        self.assertEqual(manifest_row["adc_code_min"], "-2048")
        self.assertEqual(manifest_row["adc_code_max"], "2047")
        self.assertEqual(manifest_row["adc_saturated_samples"], "2")


if __name__ == "__main__":
    unittest.main()
