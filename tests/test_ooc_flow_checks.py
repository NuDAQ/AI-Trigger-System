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
            r"set_false_path\s+-hold\s+-from\s+\[get_ports\s+-quiet\s+\{ADC_SRC_VALID ADC_SRC_DATA4\*\}\]",
        )
        self.assertRegex(
            xdc,
            r"set_false_path\s+-hold\s+-from\s+\[get_ports\s+-quiet\s+\{EVENT_READY\}\]",
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

    def test_event_metadata_outputs_have_ooc_boundary_delay(self) -> None:
        xdc = read("HDL/constraints/ai_trigger_ooc.xdc")

        event_output_delay_lines = [
            line for line in xdc.splitlines()
            if line.strip().startswith("set_output_delay") and "CLK_ADC" in line
        ]
        self.assertTrue(event_output_delay_lines)
        event_output_delay = " ".join(event_output_delay_lines)
        self.assertIn("EVENT_CHUNK_ID*", event_output_delay)
        self.assertIn("EVENT_TIMESTAMP*", event_output_delay)
        self.assertIn("EVENT_SCORE*", event_output_delay)

    def test_adc_source_boundary_has_own_clock_and_delays(self) -> None:
        xdc = read("HDL/constraints/ai_trigger_ooc.xdc")

        self.assertRegex(xdc, r"create_clock\s+-name\s+ADC_SRC_CLK\s+-period\s+16\.000")
        self.assertRegex(
            xdc,
            r"set_input_delay\s+0\.000\s+-clock\s+\[get_clocks\s+ADC_SRC_CLK\]\s+"
            r"\[get_ports\s+-quiet\s+\{ADC_SRC_VALID ADC_SRC_DATA4\*\}\]",
        )
        self.assertRegex(
            xdc,
            r"set_output_delay\s+0\.000\s+-clock\s+\[get_clocks\s+ADC_SRC_CLK\]\s+"
            r"\[get_ports\s+-quiet\s+\{ADC_SRC_READY ADC_INPUT_OVERFLOW_COUNT\*\}\]",
        )

    def test_lane_chunk_id_metadata_uses_xpm_handshake(self) -> None:
        lane = read("HDL/rtl/CNN_CORE_LANE.vhd")

        self.assertNotIn("u_CHUNK_ID_FIFO", lane)
        self.assertNotIn("entity work.CHUNK_ID_CDC_FIFO", lane)
        self.assertIn("xpm_cdc_handshake", lane)
        self.assertRegex(lane, r"DEST_EXT_HSK\s+=>\s+0")
        self.assertIn("chunk_id_meta_valid", lane)

    def test_lane_xpm_source_request_is_held_until_ack(self) -> None:
        lane = read("HDL/rtl/CNN_CORE_LANE.vhd")

        self.assertRegex(
            lane,
            r"if\s+chunk_id_src_rcv\s*=\s*'1'\s+then\s+"
            r"chunk_id_src_send\s*<=\s*'0';\s+"
            r"chunk_id_src_pending\s*<=\s*'0';\s+"
            r"else\s+"
            r"chunk_id_src_send\s*<=\s*chunk_id_src_pending;",
        )

    def test_lane_xpm_dest_request_is_consumed_once(self) -> None:
        lane = read("HDL/rtl/CNN_CORE_LANE.vhd")

        self.assertIn("chunk_id_dest_seen", lane)
        self.assertRegex(lane, r"if\s+chunk_id_dest_req\s*=\s*'0'\s+then\s+chunk_id_dest_seen\s*<=\s*'0';")
        self.assertRegex(
            lane,
            r"elsif\s+chunk_id_dest_seen\s*=\s*'0'\s+and\s+chunk_id_meta_valid\s*=\s*'0'\s+then",
        )
        self.assertIn("chunk_id_meta_valid <= '1';", lane)

    def test_trigger_cdc_uses_xpm_handshake_not_custom_async_ram(self) -> None:
        trigger_cdc = read("HDL/rtl/TRIGGER_CDC_FIFO.vhd")

        self.assertIn("xpm_cdc_handshake", trigger_cdc)
        self.assertRegex(trigger_cdc, r"DEST_EXT_HSK\s+=>\s+1")
        self.assertNotIn("rd_gray_wr_ff", trigger_cdc)
        self.assertNotIn("wr_gray_rd_ff", trigger_cdc)
        self.assertNotIn("bin_to_gray", trigger_cdc)

    def test_trigger_cdc_dest_ack_is_registered_in_read_clock_domain(self) -> None:
        trigger_cdc = read("HDL/rtl/TRIGGER_CDC_FIFO.vhd")

        self.assertIn("signal dest_ack_r", trigger_cdc)
        self.assertRegex(trigger_cdc, r"process\s*\(\s*RD_CLK\s*\)")
        self.assertRegex(trigger_cdc, r"if\s+rising_edge\s*\(\s*RD_CLK\s*\)")
        self.assertIn("dest_ack <= dest_ack_r;", trigger_cdc)
        self.assertNotRegex(trigger_cdc, r"dest_ack\s+<=\s+dest_req\s+and\s+RD_READY")

    def test_top_synchronizes_external_reset_before_adc_domain_fanout(self) -> None:
        bender = read("Bender.yml")
        top = read("HDL/rtl/AI_TRIGGER_TOP.vhd")

        self.assertIn("HDL/rtl/RESET_SYNC.vhd", bender)
        self.assertIn("signal rst_adc", top)
        self.assertIn("u_RST_ADC", top)
        self.assertIn("u_RST_ADC_SRC", top)
        self.assertIn("u_RST_CNN", top)
        self.assertRegex(top, r"(?s)u_ADC_INPUT\s*:\s*entity work\.ADC_INPUT_CDC_FIFO.*?WR_RST\s*=>\s*rst_adc_src")
        self.assertRegex(top, r"(?s)u_ADC_INPUT\s*:\s*entity work\.ADC_INPUT_CDC_FIFO.*?RD_RST\s*=>\s*rst_adc")
        self.assertRegex(top, r"(?s)u_DIST\s*:\s*entity work\.ADC_CHUNK_DISTRIBUTOR.*?RST\s*=>\s*rst_adc")
        self.assertRegex(top, r"(?s)u_LANE\s*:\s*entity work\.CNN_CORE_LANE.*?RST_ASYNC\s*=>\s*RST")
        self.assertRegex(top, r"(?s)u_LANE\s*:\s*entity work\.CNN_CORE_LANE.*?RST_ADC\s*=>\s*rst_adc")
        self.assertRegex(top, r"(?s)u_LANE\s*:\s*entity work\.CNN_CORE_LANE.*?RST_CNN\s*=>\s*rst_cnn")
        self.assertRegex(top, r"(?s)u_EVENT_PATH\s*:\s*entity work\.EVENT_CAPTURE_PATH.*?RST_ADC\s*=>\s*rst_adc")
        self.assertRegex(top, r"(?s)u_EVENT_PATH\s*:\s*entity work\.EVENT_CAPTURE_PATH.*?RST_CNN\s*=>\s*rst_cnn")

    def test_cross_domain_modules_do_not_derive_cnn_reset_from_adc_reset(self) -> None:
        lane = read("HDL/rtl/CNN_CORE_LANE.vhd")
        event_path = read("HDL/rtl/EVENT_CAPTURE_PATH.vhd")

        for source in (lane, event_path):
            self.assertIn("RST_ADC", source)
            self.assertIn("RST_CNN", source)
            self.assertNotIn("rst_cnn_ff", source)
            self.assertNotRegex(source, r"rst_n_cnn\s*<=\s*not\s+rst_cnn_ff")

        self.assertIn("RST_ASYNC", lane)
        self.assertRegex(lane, r"(?s)u_FIFO\s*:\s*fifo_async_1024_to_64.*?rst\s*=>\s*RST_ASYNC")


if __name__ == "__main__":
    unittest.main()
