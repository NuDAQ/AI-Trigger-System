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

    def test_system_uses_five_lanes_at_200_mhz(self) -> None:
        pkg = read("HDL/rtl/AI_TRIGGER_PKG.vhd")
        xdc = read("HDL/constraints/ai_trigger_ooc.xdc")
        sv_tb = read("HDL/sim/tb_ai_trigger_top.sv")
        saif = read("scripts/vivado_post_impl_saif.tcl")

        self.assertRegex(pkg, r"N_LANES\s+:\s+integer\s*:=\s*5")
        self.assertRegex(xdc, r"create_clock\s+-name\s+CLK_CNN\s+-period\s+5\.000")
        self.assertIn("parameter CLK_CNN_PERIOD =  5.000", sv_tb)
        self.assertIn("CNN cores:        5", sv_tb)
        self.assertIn(r"gen_lanes\[4\].u_LANE", saif)
        self.assertNotIn(r"gen_lanes\[5\].u_LANE", saif)

    def test_top_level_score_interface_is_32_bit(self) -> None:
        top = read("HDL/rtl/AI_TRIGGER_TOP.vhd")
        wrap = read("HDL/sim/AI_TRIGGER_TOP_TB_WRAP.vhd")
        sv_tb = read("HDL/sim/tb_ai_trigger_top.sv")

        self.assertRegex(top, r"CNN_THRESH\s+:\s+in\s+std_logic_vector\(31 downto 0\)")
        self.assertRegex(top, r"CNN_OUT_DATA\s+:\s+out\s+std_logic_vector\(31 downto 0\)")
        self.assertRegex(wrap, r"CNN_THRESH\s+:\s+in\s+std_logic_vector\(31 downto 0\)")
        self.assertRegex(wrap, r"CNN_OUT_DATA\s+:\s+out\s+std_logic_vector\(31 downto 0\)")
        self.assertRegex(sv_tb, r"reg\s+\[31:0\]\s+cnn_thresh")
        self.assertRegex(sv_tb, r"wire\s+\[31:0\]\s+cnn_out_data")

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
        top = read("HDL/rtl/AI_TRIGGER_TOP.vhd")
        sv_tb = read("HDL/sim/tb_ai_trigger_top.sv")

        self.assertIn("ap_fixed<22,11>", top)
        self.assertRegex(top, r"lane_score\(i\)\(21 downto 0\)")
        self.assertRegex(top, r"CNN_THRESH\(21 downto 0\)")
        self.assertIn("/ 2048.0", sv_tb)
        self.assertIn("-12288", sv_tb)


if __name__ == "__main__":
    unittest.main()
