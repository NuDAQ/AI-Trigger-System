#!/usr/bin/env python3
"""Behavior checks for DAQ bring-up simulation stimulus generation."""

from __future__ import annotations

import csv
import subprocess
import sys
import tempfile
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "run_bringup_sim.py"


class BringupSimulationTest(unittest.TestCase):
    def run_generate(self, *args: str) -> Path:
        out_dir = Path(tempfile.mkdtemp(prefix="ai-trigger-bringup-"))
        subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                "--generate-only",
                "--out-dir",
                str(out_dir),
                *args,
            ],
            cwd=ROOT,
            check=True,
        )
        return out_dir

    def test_bipolar_sweep_generates_ch0_only_50mv_pulse_manifest(self) -> None:
        out_dir = self.run_generate("--stimulus", "bipolar-sweep")

        testhex_dir = out_dir / "bipolar_sweep" / "testhex_stream"
        labels = (testhex_dir / "labels.hex").read_text(encoding="utf-8").splitlines()
        with (out_dir / "bipolar_sweep" / "manifest.csv").open(newline="", encoding="utf-8") as csv_file:
            manifest_rows = list(csv.DictReader(csv_file))
        sample0 = (testhex_dir / "test_input_sample0.hex").read_text(encoding="utf-8").splitlines()

        self.assertEqual(len(labels), 242)
        self.assertTrue(all(label == "0" for label in labels))
        self.assertEqual(len(manifest_rows), 242)
        self.assertEqual(manifest_rows[0]["stim_kind"], "bipolar_sweep")
        self.assertEqual(manifest_rows[0]["pulse_offset_sample"], "0")
        self.assertEqual(manifest_rows[-1]["pulse_offset_sample"], "241")
        self.assertEqual(manifest_rows[0]["pulse_peak_mv"], "50.000")
        self.assertEqual(manifest_rows[0]["adc_code_pos"], "256")
        self.assertEqual(manifest_rows[0]["adc_code_neg"], "-256")
        self.assertEqual(manifest_rows[0]["pulse_channel"], "0")

        self.assertEqual(len(sample0), 256)
        self.assertEqual(sample0[0:5], ["0000000000000100"] * 5)
        self.assertEqual(sample0[5:10], ["0000000000000000"] * 5)
        self.assertEqual(sample0[10:15], ["0000000000000f00"] * 5)
        self.assertEqual(sample0[15:], ["0000000000000000"] * (256 - 15))

    def test_zero_stimulus_generates_all_zero_chunks(self) -> None:
        out_dir = self.run_generate("--stimulus", "zero", "--num-zero-samples", "3")

        testhex_dir = out_dir / "zero" / "testhex_stream"
        labels = (testhex_dir / "labels.hex").read_text(encoding="utf-8").splitlines()
        sample2 = (testhex_dir / "test_input_sample2.hex").read_text(encoding="utf-8").splitlines()
        with (out_dir / "zero" / "manifest.csv").open(newline="", encoding="utf-8") as csv_file:
            manifest_rows = list(csv.DictReader(csv_file))

        self.assertEqual(labels, ["0", "0", "0"])
        self.assertEqual(len(sample2), 256)
        self.assertEqual(set(sample2), {"0000000000000000"})
        self.assertEqual([row["stim_kind"] for row in manifest_rows], ["zero", "zero", "zero"])
        self.assertEqual([row["pulse_offset_sample"] for row in manifest_rows], ["-1", "-1", "-1"])

    def test_bringup_runner_disables_raw_channel_mirroring(self) -> None:
        testbench = (ROOT / "HDL" / "sim" / "tb_ai_trigger_top.sv").read_text(encoding="utf-8")
        run_sim_tcl = (ROOT / "run_sim.tcl").read_text(encoding="utf-8")
        run_vivado_sim = (ROOT / "scripts" / "run_vivado_sim.py").read_text(encoding="utf-8")
        bringup_runner = SCRIPT.read_text(encoding="utf-8")

        self.assertIn("MIRROR_RAW_CHANNELS", testbench)
        self.assertIn("RUN_SIM_MIRROR_RAW_CHANNELS", run_sim_tcl)
        self.assertIn("--mirror-raw-channels", run_vivado_sim)
        self.assertIn('"--mirror-raw-channels"', bringup_runner)
        self.assertIn('"0"', bringup_runner)


if __name__ == "__main__":
    unittest.main()
