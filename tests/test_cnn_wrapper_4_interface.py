#!/usr/bin/env python3
"""Interface checks for the cnn-core-wrapper 4.x integration."""

from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


class CnnWrapper4InterfaceTest(unittest.TestCase):
    def test_bender_lock_uses_wrapper_4(self) -> None:
        lock = read("Bender.lock")
        self.assertIn("version: 4.0.0", lock)
        self.assertIn("revision: 1a9554f554c495730117a688b5bb953cfddb89f1", lock)

    def test_system_uses_five_lanes_with_250_mhz_ingest_and_200_mhz_cnn(self) -> None:
        pkg = read("HDL/rtl/AI_TRIGGER_PKG.vhd")
        xdc = read("HDL/constraints/ai_trigger_ooc.xdc")
        sv_tb = read("HDL/sim/tb_ai_trigger_top.sv")
        saif = read("scripts/vivado_post_impl_saif.tcl")

        self.assertRegex(pkg, r"N_LANES\s+:\s+integer\s*:=\s*5")
        self.assertNotIn("ADC_SRC_CLK", xdc)
        self.assertRegex(xdc, r"create_clock\s+-name\s+CLK_ADC\s+-period\s+4\.000")
        self.assertRegex(xdc, r"create_clock\s+-name\s+CLK_CNN\s+-period\s+5\.000")
        # The source clock is simulation stimulus only; the OOC trigger top starts at CLK_ADC.
        self.assertIn("parameter ADC_SRC_CLK_PERIOD = 4.0", sv_tb)
        self.assertIn("parameter CLK_ADC_PERIOD = 4.000", sv_tb)
        self.assertIn("parameter CLK_CNN_PERIOD =  5.000", sv_tb)
        self.assertIn("CNN cores:        5", sv_tb)
        self.assertIn(r"gen_lanes\[4\].u_LANE", saif)
        self.assertNotIn(r"gen_lanes\[5\].u_LANE", saif)

    def test_top_level_score_interface_is_32_bit(self) -> None:
        top = read("HDL/rtl/AI_TRIGGER_TOP.vhd")
        core = read("HDL/rtl/AI_TRIGGER_CORE.vhd")
        wrap = read("HDL/sim/AI_TRIGGER_TOP_TB_WRAP.vhd")
        sv_tb = read("HDL/sim/tb_ai_trigger_top.sv")

        self.assertRegex(top, r"CNN_THRESH\s+:\s+in\s+std_logic_vector\(31 downto 0\)")
        self.assertNotRegex(top, r"CNN_OUT_DATA\s+:\s+out")
        self.assertNotRegex(top, r"CNN_OUT_CHUNK_ID\s+:\s+out")
        self.assertRegex(top, r"EVENT_DATA\s+:\s+out\s+std_logic_vector\(RAW_ADC_BATCH_WIDTH - 1 downto 0\)")
        self.assertRegex(top, r"EVENT_TIMESTAMP\s+:\s+out\s+std_logic_vector\(TIMESTAMP_WIDTH - 1 downto 0\)")
        self.assertRegex(top, r"EVENT_READY\s+:\s+in\s+std_logic")
        self.assertNotRegex(top, r"DROPPED_TRIGGER_COUNT\s+:\s+out")
        self.assertNotRegex(top, r"RING_MISS_COUNT\s+:\s+out")
        self.assertRegex(core, r"CNN_OUT_DATA\s+:\s+out\s+std_logic_vector\(31 downto 0\)")
        self.assertRegex(core, r"CNN_OUT_CHUNK_ID\s+:\s+out\s+chunk_id_t")
        self.assertRegex(core, r"DROPPED_TRIGGER_COUNT\s+:\s+out\s+unsigned\(31 downto 0\)")
        self.assertRegex(core, r"RING_MISS_COUNT\s+:\s+out\s+unsigned\(31 downto 0\)")
        self.assertRegex(wrap, r"CNN_THRESH\s+:\s+in\s+std_logic_vector\(31 downto 0\)")
        self.assertRegex(wrap, r"CNN_OUT_DATA\s+:\s+out\s+std_logic_vector\(31 downto 0\)")
        self.assertRegex(wrap, r"CNN_OUT_CHUNK_ID\s*:\s+out\s+std_logic_vector\(CHUNK_ID_WIDTH - 1 downto 0\)")
        self.assertRegex(wrap, r"EVENT_DATA\s+:\s+out\s+std_logic_vector\(RAW_ADC_BATCH_WIDTH - 1 downto 0\)")
        self.assertRegex(wrap, r"EVENT_TIMESTAMP\s+:\s+out\s+std_logic_vector\(TIMESTAMP_WIDTH - 1 downto 0\)")
        self.assertRegex(wrap, r"DROPPED_TRIGGER_COUNT\s+:\s+out\s+std_logic_vector\(31 downto 0\)")
        self.assertRegex(wrap, r"RING_MISS_COUNT\s+:\s+out\s+std_logic_vector\(31 downto 0\)")
        self.assertRegex(sv_tb, r"reg\s+\[31:0\]\s+cnn_thresh")
        self.assertRegex(sv_tb, r"wire\s+\[31:0\]\s+cnn_out_data")
        self.assertRegex(sv_tb, r"wire\s+\[15:0\]\s+cnn_out_chunk_id")
        self.assertRegex(sv_tb, r"wire\s+\[383:0\]\s+event_data")
        self.assertRegex(sv_tb, r"wire\s+\[23:0\]\s+event_timestamp")
        self.assertRegex(sv_tb, r"wire\s+\[31:0\]\s+dropped_trigger_count")
        self.assertRegex(sv_tb, r"wire\s+\[31:0\]\s+ring_miss_count")

    def test_top_level_adc_input_is_clk_adc_domain_flat_stream(self) -> None:
        top = read("HDL/rtl/AI_TRIGGER_TOP.vhd")
        core = read("HDL/rtl/AI_TRIGGER_CORE.vhd")
        wrap = read("HDL/sim/AI_TRIGGER_TOP_TB_WRAP.vhd")

        self.assertNotRegex(top, r"ADC_SRC_CLK\s+:\s+in\s+std_logic")
        self.assertNotRegex(top, r"ADC_SRC_VALID\s+:\s+in\s+std_logic")
        self.assertNotRegex(top, r"ADC_SRC_READY\s+:\s+out\s+std_logic")
        pkg = read("HDL/rtl/AI_TRIGGER_PKG.vhd")

        self.assertRegex(pkg, r"N_ADC_CH\s+:\s+integer\s*:=\s*8")
        self.assertRegex(pkg, r"N_TRIGGER_CH\s+:\s+integer\s*:=\s*4")
        self.assertRegex(top, r"DATA_STR\s+:\s+in\s+std_logic")
        self.assertRegex(top, r"ADC_DATA\s+:\s+in\s+std_logic_vector\(RAW_ADC_BATCH_WIDTH - 1 downto 0\)")
        self.assertNotIn("ADC_INPUT_CDC_FIFO", top)
        self.assertNotIn("DATA_STR_INTERNAL", top)
        self.assertRegex(core, r"ADC_DATA4\s+:\s+in\s+adc_data4_t")
        self.assertIn("ADC_INPUT_CDC_FIFO", wrap)
        self.assertRegex(wrap, r"ADC_SRC_READY\s+:\s+out\s+std_logic")

    def test_lane_streams_128_bit_beats_to_wrapper(self) -> None:
        lane = read("HDL/rtl/CNN_CORE_LANE.vhd")

        self.assertRegex(lane, r"INPUT_WIDTH\s+:\s+integer\s*:=\s*128")
        self.assertRegex(lane, r"OUTPUT_WIDTH\s+:\s+integer\s*:=\s*32")
        self.assertRegex(lane, r"input_data\s+:\s+in\s+std_logic_vector\(127 downto 0\)")
        self.assertRegex(lane, r"output_data\s+:\s+out\s+std_logic_vector\(31 downto 0\)")
        self.assertRegex(lane, r"cnn_in_data\s+:\s+std_logic_vector\(127 downto 0\)")
        self.assertRegex(lane, r"cnn_out_data\s+:\s+std_logic_vector\(31 downto 0\)")
        self.assertRegex(lane, r"stream_cnt\s+<=\s+N_CHUNK_BEATS_CNN")
        self.assertRegex(lane, r"cnn_in_data\s+<=\s+fifo_dout")
        self.assertNotIn("word_sel", lane)

    def test_score_decode_uses_ap_fixed_22_11(self) -> None:
        core = read("HDL/rtl/AI_TRIGGER_CORE.vhd")
        sv_tb = read("HDL/sim/tb_ai_trigger_top.sv")

        self.assertIn("ap_fixed<22,11>", core)
        self.assertRegex(core, r"lane_score\(i\)\(21 downto 0\)")
        self.assertRegex(core, r"CNN_THRESH\(21 downto 0\)")
        self.assertIn("/ 2048.0", sv_tb)
        self.assertIn("cnn_thresh_raw = 0", sv_tb)


if __name__ == "__main__":
    unittest.main()
