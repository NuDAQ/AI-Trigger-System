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

All nine real-XPM Vivado 2022.2 cases pass again for the lookup version.
Continuous/gaps produce 323 events, threshold +32 produces 142, threshold
-32 produces 1056, and minimum/maximum words accept all/reject all. Gated
281/282, resets/backpressure, mode switching and overload recovery pass.
`server/simulation_reports.tar.gz` retains the fresh compilation and logs.

Lookup OOC qualification passes in Vivado 2022.2 at unchanged 250/200 MHz,
KU5P -2: final WNS +0.238 ns, WHS +0.005 ns, TNS/THS zero.
All 23 current trigger RTL hashes match the captured OOC closure.
`server/server_reports.tar.gz` retains routed reports and orchestration.
