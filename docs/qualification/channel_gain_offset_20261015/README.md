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

Two Python provenance tests also fail on the untouched 9d5023c baseline with
the existing local path overrides: one pins an old dependency commit, and one
expects a Git revision for a null-revision path dependency. These unrelated
scripts and lock configuration were left unchanged. Logs retain the full
suite failure and the isolated baseline reproductions.
