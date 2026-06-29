#!/usr/bin/env python3
"""Static checks for the Vivado OOC implementation flow."""

from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


class OocFlowChecks(unittest.TestCase):
    def test_reset_is_not_timed_as_ooc_data_input(self) -> None:
        xdc = read("HDL/constraints/ai_trigger_ooc.xdc")
        input_delay_lines = [
            line for line in xdc.splitlines() if line.strip().startswith("set_input_delay")
        ]

        self.assertTrue(input_delay_lines)
        self.assertFalse(any(re.search(r"\bRST\b", line) for line in input_delay_lines))
        self.assertRegex(xdc, r"set_false_path\s+-from\s+\[get_ports\s+RST\]")

    def test_ooc_input_hold_checks_are_cut_at_block_boundary(self) -> None:
        xdc = read("HDL/constraints/ai_trigger_ooc.xdc")

        self.assertRegex(
            xdc,
            r"set_false_path\s+-hold\s+-from\s+\[get_ports\s+-quiet\s+\{DATA_STR ADC_DATA4\* EVENT_READY\}\]",
        )
        self.assertRegex(
            xdc,
            r"set_false_path\s+-hold\s+-from\s+\[get_ports\s+-quiet\s+\{CNN_THRESH\*\}\]",
        )

    def test_ooc_flow_writes_detailed_cdc_reports(self) -> None:
        tcl = read("scripts/vivado_ooc_build.tcl")

        self.assertIn("post_synth_cdc_details.rpt", tcl)
        self.assertIn("post_route_cdc_details.rpt", tcl)
        self.assertRegex(tcl, r"report_cdc\s+-details")


if __name__ == "__main__":
    unittest.main()
