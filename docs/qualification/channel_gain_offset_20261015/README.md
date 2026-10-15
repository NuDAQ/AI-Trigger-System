# CNN-only per-channel gain and offset

Starting point: AI-Trigger-System v4.1 `9d5023c`; gateware `69fae94` on
`oct_15_gain_offset`. Commits use the existing Albert identity. No push or
board programming is authorized by this qualification.

The agreed test seams are raw ADC to packed native CNN input, native CNN
input/output against independent HLS C++, and system ADC to score/event
output. Raw event samples must remain byte-for-byte identical to ADC input;
Hi-Lo continues to use raw samples. Continuous and gated AI share calibration.

For channels 0..3, subtract the measured baseline before applying gain:

| Channel | Gain | Baseline to subtract (mV) |
| --- | ---: | ---: |
| 0 | 4.421578 | -0.468 |
| 1 | 4.475522 | -0.014 |
| 2 | 4.417241 | +1.118 |
| 3 | 4.400045 | +0.585 |

Gain uses the prior conversation's 12.5 mV / de-meaned noise RMS values,
rounded to one part per million. The ADC scale is 800 mVpp / 4096 codes.
Fractional baseline codes are retained until the final native AP_RND /
AP_SAT_SYM conversion. Static calibration is isolated from stream control;
constant tables combine offset, gain and native quantization at elaboration.
The existing latency, model, score /1024 and external threshold /16 remain.

Work proceeds in red/green slices, then local GHDL/Verilator qualification,
server Vivado real-XPM simulation and routed OOC, then gateware integration,
synthesis, implementation and bitgen. Reports will distinguish each stage.

Local qualification: 40/40 GHDL benches pass. All 16,384 conversions match
independent native HLS quantization, and 1,096 normalized windows plus one
gated window match the real CNN in Verilator exactly. Every cached Verilator
RTL/ROM/testbench hash and executable hash was rechecked. The old gain-4.4
score reference fails at window 0 against the new inputs. Unity/zero-baseline
and replacement gain/baseline profiles pass through the public input packer.

All other 105 Python checks pass. Two Python provenance tests also fail on the untouched 9d5023c baseline with
the existing local path overrides: one pins an old dependency commit, and one
expects a Git revision for a null-revision path dependency. These unrelated
scripts and lock configuration were left unchanged. Logs retain the full
suite failure and the isolated baseline reproductions.

Server Vivado 2022.2 rebuilt the reference with original Vitis HLS headers;
all six data-file hashes match the local reference exactly. All nine real-XPM
system cases pass: continuous, gaps/phase, positive/negative/extreme thresholds,
lane reset/backpressure, modes and overload. Continuous/gaps yield 324 events;
external word +32 yields 143 and word -32 yields 1056. Gated score is
16584/1024 = 16.1953125; adjacent threshold words 259/260 accept/reject it.
All event payload assertions compare the full eight-channel raw ADC words.
Routed OOC passes in Vivado 2022.2 on KU5P -2 at unchanged ADC/CNN
250/200 MHz: WNS +0.188 ns, WHS +0.024 ns, TNS/THS zero.
No pipeline, clock, constraint, model or raw-event-path change was needed.

Gateware delivery is complete on `oct_15_gain_offset`, delivery commit
`950ff61` (build input commit `efb00fd`). Local integration passes and all
60 production RTL/ROM files match this OOC source closure. All other 349
existing source/model/wrapper/Hi-Lo/IP/constraint/build-script inputs remain
byte-identical; only necessary source-list additions and delivery metadata
accompany the calibration packages.

Vivado 2022.2 full-board synthesis, implementation and bitgen pass at the
unchanged 260 MHz ADC / 195 MHz CNN clocks: WNS +0.268 ns, WHS +0.005 ns,
TNS/THS zero. The matching bitstream, LTX and routed DCP are retrieved and
SHA-256 verified locally in sibling gateware `build/qualification-gain-offset/`.
Full reports and CDC qualification are in the sibling gateware repository's
`validation/vivado-2022.2/gain-offset-20261015/` directory. Exactly 23 known
legacy DAQ reset CDC rows return to the previously documented baseline;
Trigger/configuration has no new CDC rows. No unrelated DAQ fix was made.
Both repositories retain default Albert commits. No push or programming
was performed; functional hardware testing is outside this build evidence.
