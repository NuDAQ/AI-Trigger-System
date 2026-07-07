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
            r"set_false_path\s+-hold\s+-from\s+\[get_ports\s+-quiet\s+\{DATA_STR ADC_DATA\*\}\]",
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

    def test_ooc_flow_rejects_stale_or_wrong_top_builds(self) -> None:
        tcl = read("scripts/vivado_ooc_build.tcl")

        self.assertIn("file delete -force $rpt_dir $dcp_dir $gen_dir", tcl)
        self.assertIn("assert_file_contains $bender_script {AI_TRIGGER_CORE.vhd}", tcl)
        self.assertIn("assert_daq_top_boundary", tcl)
        self.assertRegex(tcl, r"get_ports\s+-quiet\s+ADC_SRC_CLK")
        self.assertRegex(tcl, r"get_clocks\s+-quiet\s+ADC_SRC_CLK")
        self.assertRegex(tcl, r"get_cells\s+-quiet\s+-hierarchical\s+\*u_ADC_INPUT\*")
        self.assertNotIn("fifo_async_1024_to_64", tcl)
        self.assertNotIn("synth_ip", tcl)

    def test_ooc_flow_does_not_add_simulation_wrapper(self) -> None:
        tcl = read("scripts/vivado_ooc_build.tcl")

        self.assertNotIn("AI_TRIGGER_TOP_TB_WRAP.vhd", tcl)
        self.assertNotIn("adding flat-port wrapper source", tcl)

    def test_ooc_flow_does_not_lock_lane_fifo_placement(self) -> None:
        tcl = read("scripts/vivado_ooc_build.tcl")
        preserve_match = re.search(
            r"(?s)set preserve_cells \[get_cells .*?-filter \{(.*?)\}\]",
            tcl,
        )

        self.assertIsNotNone(preserve_match)
        preserve_filter = preserve_match.group(1)
        self.assertIn("u_WRAPPER", preserve_filter)
        self.assertIn("cnn_core_inst", preserve_filter)
        self.assertNotIn("u_FIFO", preserve_filter)
        self.assertIn("set_property DONT_TOUCH true $preserve_cells", tcl)

    def test_rtl_avoids_vhdl_2008_only_process_all(self) -> None:
        rtl_sources = (ROOT / "HDL/rtl").glob("*.vhd")

        for source in rtl_sources:
            text = source.read_text(encoding="utf-8")
            self.assertNotRegex(
                text,
                r"process\s*\(\s*all\s*\)",
                msg=f"{source.relative_to(ROOT)} uses process(all), which the Vivado OOC flow does not parse as VHDL-2008",
            )

    def test_event_metadata_outputs_have_ooc_boundary_delay(self) -> None:
        xdc = read("HDL/constraints/ai_trigger_ooc.xdc")

        event_output_delay_lines = [
            line for line in xdc.splitlines()
            if line.strip().startswith("set_output_delay") and "CLK_ADC" in line
        ]
        self.assertTrue(event_output_delay_lines)
        event_output_delay = " ".join(event_output_delay_lines)
        self.assertIn("EVENT_TIMESTAMP*", event_output_delay)
        self.assertNotIn("EVENT_CHUNK_ID", event_output_delay)
        self.assertNotIn("EVENT_SCORE", event_output_delay)

    def test_daq_top_has_only_adc_and_cnn_clocks(self) -> None:
        xdc = read("HDL/constraints/ai_trigger_ooc.xdc")
        top = read("HDL/rtl/AI_TRIGGER_TOP.vhd")

        self.assertNotIn("ADC_SRC_CLK", xdc)
        self.assertNotIn("ADC_SRC_CLK", top)
        self.assertRegex(
            xdc,
            r"create_clock\s+-name\s+CLK_ADC\s+-period\s+4\.000\s+\[get_ports\s+CLK_ADC\]",
        )
        self.assertRegex(
            xdc,
            r"create_clock\s+-name\s+CLK_CNN\s+-period\s+5\.000\s+\[get_ports\s+CLK_CNN\]",
        )
        self.assertRegex(top, r"DATA_STR\s+:\s+in\s+std_logic")
        self.assertRegex(top, r"ADC_DATA\s+:\s+in\s+std_logic_vector\(RAW_ADC_BATCH_WIDTH - 1 downto 0\)")

    def test_public_adc_interface_contract_uses_four_sample_beats(self) -> None:
        pkg = read("HDL/rtl/AI_TRIGGER_PKG.vhd")
        top = read("HDL/rtl/AI_TRIGGER_TOP.vhd")
        xdc = read("HDL/constraints/ai_trigger_ooc.xdc")
        analyzer = read("scripts/analyze_vivado_sim_results.py")

        self.assertRegex(pkg, r"constant\s+N_BATCH_S\s*:\s*integer\s*:=\s*4\b")
        self.assertRegex(pkg, r"constant\s+N_BATCHES\s*:\s*integer\s*:=\s*64\b")
        self.assertRegex(pkg, r"constant\s+RAW_ADC_BATCH_WIDTH\s*:\s*integer\s*:=\s*N_ADC_CH\s*\*\s*N_BATCH_S\s*\*\s*12\b")
        self.assertRegex(pkg, r"constant\s+EVENT_OUTPUT_FIFO_ADDR_WIDTH\s*:\s*integer\s*:=\s*7\b")
        self.assertRegex(pkg, r"constant\s+LANE_FIFO_WRITE_WIDTH\s*:\s*integer\s*:=\s*N_BATCH_S\s*\*\s*64\b")
        self.assertRegex(pkg, r"constant\s+LANE_FIFO_READ_WIDTH\s*:\s*integer\s*:=\s*128\b")
        self.assertRegex(pkg, r"constant\s+LANE_FIFO_WRITE_DEPTH\s*:\s*integer\s*:=\s*2\s+\*\*\s+LANE_FIFO_WRITE_ADDR_WIDTH\b")
        self.assertNotIn("1536-bit ADC_DATA", top)
        self.assertIn("EVENT_BATCHES_PER_CAPTURE = 64", analyzer)
        self.assertIn("EVENT_DATA_HEX_DIGITS = 96", analyzer)
        self.assertRegex(
            xdc,
            r"create_clock\s+-name\s+CLK_ADC\s+-period\s+4\.000\s+\[get_ports\s+CLK_ADC\]",
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

    def test_cnn_threshold_uses_config_cdc_and_lane_snapshot(self) -> None:
        core = read("HDL/rtl/AI_TRIGGER_CORE.vhd")
        lane = read("HDL/rtl/CNN_CORE_LANE.vhd")
        event_path = read("HDL/rtl/EVENT_CAPTURE_PATH.vhd")

        self.assertIn("xpm_cdc_array_single", core)
        self.assertIn("cnn_thresh_cnn", core)
        self.assertIn("agg_score_thresh", core)
        self.assertRegex(core, r"LANE_THRESH\s*=>\s*lane_thresh\(i\)")
        self.assertRegex(core, r"(?s)CNN_THRESH\s*=>\s*agg_score_thresh")
        self.assertNotRegex(core, r"signed\(CNN_THRESH\(21 downto 0\)\)")

        self.assertIn("score_thresh_mem", lane)
        self.assertIn("LANE_THRESH", lane)
        self.assertRegex(lane, r"score_thresh_mem\(score_id_wr_idx\)\s*<=\s*CNN_THRESH")
        self.assertRegex(lane, r"lane_thresh_r\s*<=\s*score_thresh_mem\(score_id_rd_idx\)")

        self.assertRegex(event_path, r"CNN_THRESH\s+:\s+in\s+std_logic_vector\(31 downto 0\)")

    def test_core_synchronizes_external_reset_before_domain_fanout(self) -> None:
        bender = read("Bender.yml")
        core = read("HDL/rtl/AI_TRIGGER_CORE.vhd")

        self.assertIn("HDL/rtl/RESET_SYNC.vhd", bender)
        self.assertIn("signal rst_adc", core)
        self.assertIn("u_RST_ADC", core)
        self.assertNotIn("u_RST_ADC_SRC", core)
        self.assertNotIn("rst_adc_src", core)
        self.assertIn("u_RST_CNN", core)
        self.assertRegex(core, r"(?s)u_DIST\s*:\s*entity work\.ADC_CHUNK_DISTRIBUTOR.*?RST\s*=>\s*rst_adc")
        self.assertRegex(core, r"(?s)u_LANE\s*:\s*entity work\.CNN_CORE_LANE.*?RST_ASYNC\s*=>\s*RST")
        self.assertRegex(core, r"(?s)u_LANE\s*:\s*entity work\.CNN_CORE_LANE.*?RST_ADC\s*=>\s*rst_adc")
        self.assertRegex(core, r"(?s)u_LANE\s*:\s*entity work\.CNN_CORE_LANE.*?RST_CNN\s*=>\s*rst_cnn")
        self.assertRegex(core, r"(?s)u_EVENT_PATH\s*:\s*entity work\.EVENT_CAPTURE_PATH.*?RST_ADC\s*=>\s*rst_adc")
        self.assertRegex(core, r"(?s)u_EVENT_PATH\s*:\s*entity work\.EVENT_CAPTURE_PATH.*?RST_CNN\s*=>\s*rst_cnn")

    def test_cross_domain_modules_do_not_derive_cnn_reset_from_adc_reset(self) -> None:
        lane = read("HDL/rtl/CNN_CORE_LANE.vhd")
        event_path = read("HDL/rtl/EVENT_CAPTURE_PATH.vhd")

        for source in (lane, event_path):
            self.assertIn("RST_ADC", source)
            self.assertIn("RST_CNN", source)
            self.assertNotIn("rst_cnn_ff", source)
            self.assertNotRegex(source, r"rst_n_cnn\s*<=\s*not\s+rst_cnn_ff")

        self.assertIn("RST_ASYNC", lane)
        self.assertRegex(lane, r"(?s)u_FIFO\s*:\s*xpm_fifo_async.*?rst\s*=>\s*RST_ASYNC")
        self.assertRegex(lane, r"WRITE_DATA_WIDTH\s+=>\s+LANE_FIFO_WRITE_WIDTH")
        self.assertRegex(lane, r"READ_DATA_WIDTH\s+=>\s+LANE_FIFO_READ_WIDTH")
        self.assertRegex(lane, r"FIFO_WRITE_DEPTH\s+=>\s+LANE_FIFO_WRITE_DEPTH")

    def test_sim_wrapper_owns_source_clock_cdc_not_synth_top(self) -> None:
        top = read("HDL/rtl/AI_TRIGGER_TOP.vhd")
        wrap = read("HDL/sim/AI_TRIGGER_TOP_TB_WRAP.vhd")

        self.assertNotIn("ADC_INPUT_CDC_FIFO", top)
        self.assertNotIn("ADC_SRC_CLK", top)
        self.assertIn("ADC_INPUT_CDC_FIFO", wrap)
        self.assertIn("ADC_SRC_CLK", wrap)


if __name__ == "__main__":
    unittest.main()
