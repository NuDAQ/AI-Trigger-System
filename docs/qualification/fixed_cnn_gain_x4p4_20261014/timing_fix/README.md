# ADC gain timing remediation

The first full-board 260/195 MHz gain-4.4 route fails ADC setup at -0.068 ns;
CNN setup passes at +0.087 ns and overall hold at +0.014 ns. The critical
path runs from gated raw_batch_r_reg[124] to lane-1 input FIFO DINBDIN[21],
through 14 logic levels. Gateware commit 052bd6c retains this failing case.

AI_TRIGGER_PKG.adc_to_axis16 now evaluates its exact integer division into
a 256-entry constant table at elaboration. The run-time lookup is purely
combinational. Widened magnitude, 233-code saturation, symmetric sign and
existing latency are preserved; no clock, constraint, pipeline, model or
interface changes are made. This fixes the measured gain path rather than
relaxing its timing requirement.

All 4096 signed ADC codes still match the original independent native HLS
reference exactly, and all 39 GHDL benches pass. The HLS/Verilator reference
input and score files remain byte-identical. Server real-XPM simulations,
OOC and a fresh full-board build will qualify this implementation next.
