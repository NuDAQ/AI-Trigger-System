# AI-Trigger-System

[![MIT license](https://img.shields.io/badge/license-MIT-green)](LICENSE)

## Overview

This repository contains an FPGA AI trigger path for continuous radio detector
ADC data. The current top-level design accepts four channels of 1 Gsps ADC data,
groups the stream into 256-sample chunks, and distributes those chunks across
five parallel CNN inference lanes. The number of lanes is parameterized.

The CNN IP is provided by the `cnn-core` and `cnn-core-wrapper` Bender
dependencies.

## Design Figures

The current implementation follows the continuous lane-parallel trigger
architecture shown below.

![Continuous lane-parallel AI trigger system](pic/figure_C_continuous_lane_parallel_ai_trigger.png)

The CNN core itself comes from the post-baseline streaming optimization flow:

![Post-baseline streaming optimization](pic/figure_D_post_baseline_streaming_optimization.png)

## Dependency Management

This repository uses Bender to manage the external CNN RTL dependencies.

Install and update dependencies:

```bash
cargo install bender
bender update
```

Regenerate Vivado source scripts when dependencies change:

```bash
bender script vivado -t vivado > add_files.tcl
bender script vivado-sim -t sim > add_sim_files.tcl
```

If the generated Tcl files contain a hardcoded `ROOT`, update it for the local
checkout or regenerate the scripts on the target machine.

## Current Architecture

Top-level hierarchy:

```text
AI_TRIGGER_TOP              HDL/rtl/AI_TRIGGER_TOP.vhd
  AI_TRIGGER_PKG            HDL/rtl/AI_TRIGGER_PKG.vhd
  ADC_CHUNK_DISTRIBUTOR     HDL/rtl/ADC_CHUNK_DISTRIBUTOR.vhd
  CNN_CORE_LANE x 5         HDL/rtl/CNN_CORE_LANE.vhd
    fifo_async_1024_to_64   Vivado FIFO Generator IP
    WRAPPER_TOP             cnn-core-wrapper dependency
      cnn_core              cnn-core dependency
```

### Clock Domains

| Clock | Nominal rate | Function |
| --- | ---: | --- |
| `CLK_ADC` | 62.5 MHz | Accepts 16 ADC samples per cycle per channel, equivalent to 1 Gsps per channel. |
| `CLK_CNN` | 200 MHz | Streams data into the CNN wrappers, runs inference, and aggregates trigger results. |

The reset input `RST` is active high and generated in the ADC domain. Each
`CNN_CORE_LANE` retimes reset into the CNN clock domain before driving the
active-low reset expected by `WRAPPER_TOP`.

### ADC Input Format

The simulation wrapper exposes the four-channel ADC input as a flat 768-bit
vector:

```text
4 channels x 16 samples per ADC cycle x 12 bits = 768 bits
```

The SystemVerilog testbench and VHDL wrapper use this convention:

```text
ADC_DATA4_FLAT[(ch * 16 + sample) * 12 +: 12] <-> ADC_DATA4(ch)(sample)
```

The CNN test vectors store one timestep as four packed 12-bit values:

```text
raw[11: 0] = ch0
raw[23:12] = ch1
raw[35:24] = ch2
raw[47:36] = ch3
raw[63:48] = unused
```

The distributor scales each 12-bit channel value down by one bit, saturates it
to the signed 9-bit CNN input range, and sign-extends it to the 16-bit
AXI-stream lane container expected by the wrapper:

```text
axis_word[15: 0] = sign_extend(saturate(ch0[11:0] >>> 1, -256, 255))
axis_word[31:16] = sign_extend(saturate(ch1[11:0] >>> 1, -256, 255))
axis_word[47:32] = sign_extend(saturate(ch2[11:0] >>> 1, -256, 255))
axis_word[63:48] = sign_extend(saturate(ch3[11:0] >>> 1, -256, 255))
```

## Data Flow

`ADC_CHUNK_DISTRIBUTOR` runs in the ADC clock domain. Each `DATA_STR` cycle
contains 16 timesteps for all four channels. A CNN chunk is 256 timesteps, so
one chunk is complete after 16 ADC cycles.

For every chunk:

1. The distributor selects a lane in round-robin order.
2. If the selected lane is available, all 16 ADC batches are written into that
   lane's async FIFO as 1024-bit words.
3. If the selected lane is busy at the start of the chunk, the whole chunk is
   dropped and `CHUNK_OVERFLOW` is asserted for that ADC cycle.
4. The CNN side reads the FIFO as 128-bit words and emits 128 consecutive
   128-bit AXI-stream words to `WRAPPER_TOP`.

The async FIFO uses a 1024-bit write port and a 128-bit read port. Xilinx FIFO
Generator emits the high 128-bit segment of each 1024-bit write first, so the
distributor stores the eight 128-bit CNN beats in reverse segment order. This
preserves chronological CNN input order at the FIFO read side.

`CNN_CORE_LANE` releases `CHUNK_BUSY` after the 128 input beats have been
accepted by the CNN input stream. It does not wait for the CNN score output.
This allows the input side of a lane to accept a later chunk while the previous
chunk is still propagating through the CNN pipeline.

## Timing and Throughput

At 1 Gsps, one 256-sample chunk arrives every:

```text
256 samples / 1 GHz = 256 ns
```

With five lanes, each lane receives a new chunk every:

```text
5 x 256 ns = 1280 ns
```

The CNN wrapper 4.x single-core transaction interval is about 177-178 CNN clock
cycles in the wrapper/core reports. The minimum CNN clock to sustain the ADC
stream is therefore approximately:

```text
f_CNN >= CNN_interval_cycles / (N_LANES x 256 ns)
```

Using 178 cycles and 5 lanes:

```text
f_CNN >= 178 / 1280 ns = 139.1 MHz
```

Using the measured per-core latency of about 183 CNN cycles as a conservative
interval estimate:

```text
f_CNN >= 183 / 1280 ns = 143.0 MHz
```

The current 200 MHz CNN clock target leaves margin while matching the poster
architecture with five replicated cores.

The latest full-system behavioral check, using 256 samples at
`CLK_CNN = 200 MHz` and `CNN_THRESH_RAW = 0`, reports:

```text
Samples sent:     256
Results received: 256
Chunk overflows:  0
Accuracy:         253 / 256 = 98.83%
Avg latency:      202.0 CNN cycles = 1.010 us
Throughput:       3.86 Mchunks/s
RTL/Keras score correlation: 0.9763
RTL/Keras trigger agreement: 254 / 256 = 99.22%
RTL/Keras mean absolute score difference: 0.666
```

The reported latency is end-to-end from the start of the ADC chunk to
`CNN_OUT_VALID`. It includes ADC batching, FIFO/CDC, CNN input streaming, CNN
pipeline latency, and output aggregation. It is not the steady-state output
interval. In steady state, accepted chunks are launched at the ADC chunk rate
across the five lanes. Keras comparison is used as a sanity check for score
alignment; exact score equality is not expected because the RTL is fixed-point
HLS output.

## Output Score and Trigger Threshold

`WRAPPER_TOP` returns an `ap_fixed<22,11>` score byte-aligned into a 32-bit output
word. The score is decoded using the same convention as the wrapper reference
testbench:

```text
score_float = signed(CNN_OUT_DATA[21:0]) / 2048.0
```

`AI_TRIGGER_TOP` compares the low 22 bits of each lane score against the low
22 bits of `CNN_THRESH` as signed `ap_fixed<22,11>` values:

```text
CNN_TRIG = 1 when signed(score[21:0]) > signed(CNN_THRESH[21:0])
```

Common raw threshold values:

| Float threshold | Raw `CNN_THRESH` |
| ---: | ---: |
| -6.0 | -12288 |
| -0.5 | -1024 |
| 0.0 | 0 |
| 0.5 | 1024 |
| 1.0 | 2048 |

The simulation default is `SCORE_THRESHOLD=-6.0` and `CNN_THRESH_RAW=-12288`,
matching the wrapper behavioral reference run.

## Main RTL Files

| File | Description |
| --- | --- |
| `HDL/rtl/AI_TRIGGER_PKG.vhd` | Shared constants and array types. `N_LANES` is currently 5. |
| `HDL/rtl/AI_TRIGGER_TOP.vhd` | Structural top level, result aggregation, and threshold comparison. |
| `HDL/rtl/ADC_CHUNK_DISTRIBUTOR.vhd` | ADC-domain chunk formation and round-robin lane assignment. |
| `HDL/rtl/CNN_CORE_LANE.vhd` | Per-lane async FIFO, CDC counters, AXI-stream input FSM, and CNN wrapper instance. |
| `HDL/sim/AI_TRIGGER_TOP_TB_WRAP.vhd` | Mixed-language simulation wrapper for the VHDL top-level input type. |
| `HDL/sim/tb_ai_trigger_top.sv` | SystemVerilog simulation testbench. |
| `scripts/run_vivado_sim.py` | Batch-mode Vivado simulation launcher. |
| `run_sim.tcl` | Vivado simulation setup used by both GUI and batch flows. |

## Simulation

The recommended terminal flow is:

```bash
python3 scripts/run_vivado_sim.py --num-samples 1000
```

The script opens `AI_Trigger_System/AI_Trigger_System.xpr`, sources
`run_sim.tcl`, and runs the behavioral xsim testbench in Vivado batch mode.

Useful options:

```bash
python3 scripts/run_vivado_sim.py \
  --num-samples 1000 \
  --score-threshold -6.0 \
  --cnn-thresh-raw -12288
```

Vivado GUI flow:

```tcl
open_project AI_Trigger_System/AI_Trigger_System.xpr
source run_sim.tcl
```

The testbench reads `testhex_stream/test_input_sample*.hex` and
`testhex_stream/labels.hex`. `run_sim.tcl` creates a symlink to the
`cnn-core-wrapper` checkout's `testhex_stream` directory when the Bender
dependency is present.

Simulation output is written to:

```text
AI_Trigger_System/AI_Trigger_System.sim/sim_1/behav/xsim/ai_trigger_results.csv
```

## Synthesis and Implementation Notes

The current design is intended to be analyzed with Vivado synthesis and
implementation using the committed project:

```text
AI_Trigger_System/AI_Trigger_System.xpr
```

Primary checks for the next analysis step:

1. Confirm `CLK_CNN` timing closure at 200 MHz.
2. Confirm `CLK_ADC` timing closure at 62.5 MHz.
3. Review resource use for five CNN wrappers plus five async FIFOs.
4. Check FIFO Generator resource mapping and reset behavior.
5. Review inter-clock timing constraints between `CLK_ADC` and `CLK_CNN`.

The recommended OOC build command is:

```bash
python3 scripts/run_vivado_build.py --impl
```

This flow uses Bender to collect RTL sources, removes dependency board-level
constraints, applies `HDL/constraints/ai_trigger_ooc.xdc`, and runs the block
out-of-context. This is intentional: `AI_TRIGGER_TOP` is a DAQ subsystem block,
not the package-level FPGA top. Running normal top-level implementation on this
entity would map the wide ADC and score interfaces to package IO and produce
misleading resource, timing, and IO utilization results.

OOC build reports are written under:

```text
build/vivado_ooc_ai_trigger_wrap/reports/
```

Post-implementation SAIF and timing reports are written under:

```text
build/vivado_post_impl_saif/reports/
```

Current routed result summary:

| Metric | Current report |
| --- | ---: |
| Timing | WNS 1.114 ns, TNS 0, WHS 0.020 ns |
| `CLK_ADC` | 62.5 MHz |
| `CLK_CNN` | 200 MHz target |
| LUT | 28,315 |
| FF | 16,283 |
| BRAM tiles | 72.5 |
| DSP | 20 |
| IOB | 0 |
| SAIF power | 1.380 W total, High confidence |
| Dynamic power | 0.922 W |
| Static power | 0.458 W |
| SAIF net match | 99% |

The hierarchical utilization report should show all five lanes present. Each lane
contains one CNN wrapper and one async FIFO, so the CNN datapath was not
optimized away in implementation.

The latest SAIF hierarchy report shows dynamic power dominated by the five CNN
lanes. Each lane is about 0.182-0.186 W, including about 0.146-0.150 W in the
wrapper and about 0.035 W in the FIFO. The distributor is about 0.007 W.

The current timing report still contains OOC boundary warnings for missing
input and output delays. There are no unconstrained internal endpoints and all
user-specified timing constraints are met, but the boundary assumptions should
be reviewed before using the result as final system-level sign-off.

The main throughput target is one 256-sample chunk every 256 ns at the ADC
input. At five lanes, the CNN domain should have enough margin if the single
core transaction interval remains near 177-178 cycles and the implemented
`CLK_CNN` frequency is at or above 200 MHz.

More detailed report interpretation and the current sign-off checklist are in
`docs/implementation.md`.

## Post-Implementation SAIF Power Flow

For power analysis, use a routed netlist simulation to collect switching
activity and feed the resulting SAIF back into `report_power`:

```bash
python3 scripts/run_post_impl_saif.py --samples 64
```

The run uses the flat-port simulation wrapper as the OOC top, runs the existing
testbench, starts SAIF recording after a 2 us warm-up window, writes
`build/vivado_post_impl_saif/activity/ai_trigger_post_impl.saif`, and reports
power to:

```text
build/vivado_post_impl_saif/reports/post_route_power_saif.rpt
```

The default gate simulation is functional, without SDF annotation, because the
SAIF goal is representative switching activity rather than exhaustive timing
simulation. For a short timing smoke test, reduce the sample count and enable
SDF:

```bash
python3 scripts/run_post_impl_saif.py --samples 16 --sdf max
```

Longer SAIF windows, such as 32 or 64 samples, can be used when runtime is
acceptable and a more representative average activity profile is needed.
For faster debug runs, use `--saif-scope lane0`, `--saif-scope lanes2`, or
`--saif-scope lanes4`. The script prints object counts and elapsed time for
each SAIF logging chunk so long setup phases can be distinguished from a hang.
It also fails the run if fewer than 1000 simulation objects are logged, which
helps catch bad hierarchy patterns before producing a misleading power report.
The logged object count is determined by the xsim `get_objects` scope patterns,
not by timing constraints. The scope list is specified in
`scripts/vivado_post_impl_saif.tcl` so the intended SAIF coverage is explicit.
If scoped logging matches too few objects, the default flow falls back to a raw
full-DUT recursive `get_objects -r /tb_AI_TRIGGER_TOP/dut/*` pass and prints a
clear message before doing so. Use `--no-saif-fallback-all` to disable that
fallback during debugging.

The current high-confidence power report was generated by this full-DUT
fallback. The scoped hierarchy patterns matched only the top-level DUT signals
in xsim; the fallback logged 133,881 objects and produced a 99% SAIF net match.
On the reference Ubuntu run, the full-DUT object enumeration took about 67
minutes. The 64-sample gate simulation then completed in about 2.2 minutes. The
detailed xsim trace is kept in `build/vivado_post_impl_saif/xsim/xsim.log`.

The current SAIF run used the default trigger threshold
`CNN_THRESH_RAW = -12288` (`-6.0`). That threshold makes the post-implementation
testbench trigger on nearly every sample and is useful for switching activity,
but the behavioral functional validation above uses `CNN_THRESH_RAW = 0`.
Use matching threshold arguments if the SAIF run also needs to report functional
accuracy under the same operating point:

```bash
python3 scripts/run_post_impl_saif.py \
  --samples 64 \
  --score-threshold 0.0 \
  --cnn-thresh-raw 0
```
