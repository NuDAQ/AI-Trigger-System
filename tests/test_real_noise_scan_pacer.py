#!/usr/bin/env python3
"""Verilator behavior check for the simulation-only real-noise scan pacer."""

from __future__ import annotations

from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


class RealNoiseScanPacerTest(unittest.TestCase):
    def test_one_chunk_remains_in_flight_until_score_and_event_are_complete(self) -> None:
        verilator = shutil.which("verilator")
        self.assertIsNotNone(verilator, "verilator is required for the pacer behavior test")
        build_dir = Path(tempfile.mkdtemp(prefix="ai-trigger-pacer-verilator-"))
        result = subprocess.run(
            [
                verilator,
                "--binary",
                "--timing",
                "--assert",
                "--top-module",
                "tb_real_noise_scan_pacer",
                "--Mdir",
                str(build_dir / "obj"),
                str(ROOT / "HDL" / "sim" / "REAL_NOISE_SCAN_PACER.sv"),
                str(ROOT / "tests" / "tb_real_noise_scan_pacer.sv"),
            ],
            cwd=ROOT,
            text=True,
            capture_output=True,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

        simulation = subprocess.run(
            [str(build_dir / "obj" / "Vtb_real_noise_scan_pacer")],
            cwd=ROOT,
            text=True,
            capture_output=True,
        )
        self.assertEqual(simulation.returncode, 0, simulation.stdout + simulation.stderr)
        self.assertIn("tb_real_noise_scan_pacer passed", simulation.stdout)


if __name__ == "__main__":
    unittest.main()
