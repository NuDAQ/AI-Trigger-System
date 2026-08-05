from __future__ import annotations

import os
from pathlib import Path
import subprocess
import unittest


ROOT = Path(__file__).resolve().parents[1]
TIMING_GATE = ROOT / "scripts" / "vivado_timing_gate.tcl"


class VivadoTimingGateTest(unittest.TestCase):
    @staticmethod
    def _summary(wns: str, whs: str, wpws: str) -> str:
        return f"""
| Design Timing Summary
| ---------------------

    WNS(ns) TNS(ns) TNS Failing Endpoints TNS Total Endpoints WHS(ns) THS(ns) THS Failing Endpoints THS Total Endpoints WPWS(ns) TPWS(ns) TPWS Failing Endpoints TPWS Total Endpoints
    ------- ------- --------------------- ------------------- ------- ------- --------------------- ------------------- -------- -------- ---------------------- --------------------
    {wns} 0.000 0 63711 {whs} 0.000 0 62481 {wpws} 0.000 0 26453
"""

    def _run_gate(self, summary: str) -> subprocess.CompletedProcess[str]:
        program = f"""
if {{[catch {{
  source {{{TIMING_GATE}}}
  ai_trigger_require_timing $::env(AI_TRIGGER_TIMING_SUMMARY)
}} message]}} {{
  puts stderr $message
  exit 1
}}
"""
        return subprocess.run(
            ["tclsh"],
            input=program,
            capture_output=True,
            text=True,
            env={**os.environ, "AI_TRIGGER_TIMING_SUMMARY": summary},
        )

    def test_positive_setup_hold_and_pulse_width_pass(self) -> None:
        result = self._run_gate(self._summary("0.115", "0.007", "1.300"))

        self.assertEqual(result.returncode, 0, result.stderr)

    def test_negative_setup_slack_fails(self) -> None:
        result = self._run_gate(self._summary("-0.125", "0.007", "1.300"))

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Timing constraints are not met: WNS=-0.125", result.stderr)

    def test_negative_hold_and_pulse_width_slack_fail(self) -> None:
        result = self._run_gate(self._summary("0.115", "-0.010", "-0.020"))

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("WHS=-0.010", result.stderr)
        self.assertIn("WPWS=-0.020", result.stderr)

    def test_unparseable_summary_fails_closed(self) -> None:
        result = self._run_gate("timing report is incomplete")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Design Timing Summary metrics are unavailable", result.stderr)


if __name__ == "__main__":
    unittest.main()
