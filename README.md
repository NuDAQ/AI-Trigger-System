# AI-Trigger-System

[![MIT license](https://img.shields.io/badge/license-MIT-green)](LICENSE)

## Overview

This repository contains an FPGA AI trigger path for continuous radio detector
ADC data. The current top-level design accepts four channels of 1 Gsps ADC data,
groups the stream into 256-sample chunks, and distributes those chunks across
seven parallel CNN inference lanes.

The CNN IP is provided by the `cnn-core` and `cnn-core-wrapper` Bender
dependencies. The local RTL handles ADC-domain batching, clock-domain crossing,
lane scheduling, output aggregation, and the trigger threshold comparison.

## Current Architecture

Top-level hierarchy:

```text
AI_TRIGGER_TOP              HDL/rtl/AI_TRIGGER_TOP.vhd
  AI_TRIGGER_PKG            HDL/rtl/AI_TRIGGER_PKG.vhd
  ADC_CHUNK_DISTRIBUTOR     HDL/rtl/ADC_CHUNK_DISTRIBUTOR.vhd
  CNN_CORE_LANE x 7         HDL/rtl/CNN_CORE_LANE.vhd
    fifo_async_1024_to_64   Vivado FIFO Generator IP
    WRAPPER_TOP             cnn-core-wrapper dependency
      cnn_core              cnn-core dependency
```

### Clock Domains

| Clock | Nominal rate | Function |
| --- | ---: | --- |
| `CLK_ADC` | 62.5 MHz | Accepts 16 ADC samples per cycle per channel, equivalent to 1 Gsps per channel. |
| `CLK_CNN` | 170 MHz | Streams data into the CNN wrappers, runs inference, and aggregates trigger results. |

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

The distributor sign-extends each 12-bit channel value to a 16-bit AXI-stream
lane before sending data to the CNN wrapper:

```text
axis_word[15: 0] = sign_extend(ch0[11:0])
axis_word[31:16] = sign_extend(ch1[11:0])
axis_word[47:32] = sign_extend(ch2[11:0])
axis_word[63:48] = sign_extend(ch3[11:0])
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
4. The CNN side reads the FIFO as 128-bit words and emits 256 consecutive
   64-bit AXI-stream words to `WRAPPER_TOP`.

`CNN_CORE_LANE` releases `CHUNK_BUSY` after the 256 input words have been
accepted by the CNN input stream. It does not wait for the CNN score output.
This allows the input side of a lane to accept a later chunk while the previous
chunk is still propagating through the CNN pipeline.

## Timing and Throughput

At 1 Gsps, one 256-sample chunk arrives every:

```text
256 samples / 1 GHz = 256 ns
```

With seven lanes, each lane receives a new chunk every:

```text
7 x 256 ns = 1792 ns
```

The CNN wrapper's single-core transaction interval is about 260-275 CNN clock
cycles in the current behavioral simulation. The minimum CNN clock to sustain
the ADC stream is therefore approximately:

```text
f_CNN >= CNN_interval_cycles / (N_LANES x 256 ns)
```

Using 275 cycles and 7 lanes:

```text
f_CNN >= 275 / 1792 ns = 153.5 MHz
```

Using the measured AI top end-to-end latency of about 288 CNN cycles as a
conservative interval estimate:

```text
f_CNN >= 288 / 1792 ns = 160.7 MHz
```

The current 170 MHz CNN clock target leaves margin while remaining more
conservative for implementation. For comparison, six lanes would require about
179-188 MHz using the same assumptions, which does not leave enough margin at a
170 MHz target.

The measured full-system simulation result after the current fixes is:

```text
Samples sent:     1000
Results received: 1000
Chunk overflows:  0
Accuracy:         955 / 1000 = 95.50%
Latency:          287-288 CLK_CNN cycles
```

The reported latency is end-to-end from the start of the ADC chunk to
`CNN_OUT_VALID`. It includes ADC batching, FIFO/CDC, CNN input streaming, CNN
pipeline latency, and output aggregation. It is not the steady-state output
interval. In steady state, accepted chunks are launched at the ADC chunk rate
across the seven lanes.

## Output Score and Trigger Threshold

`WRAPPER_TOP` returns an `ap_fixed<9,5>` score byte-aligned into a 16-bit output
word. The score is decoded using the same convention as the wrapper reference
testbench:

```text
score_float = signed(CNN_OUT_DATA[8:0]) / 16.0
```

`AI_TRIGGER_TOP` compares the low 9 bits of each lane score against the low
9 bits of `CNN_THRESH` as signed `ap_fixed<9,5>` values:

```text
CNN_TRIG = 1 when signed(score[8:0]) > signed(CNN_THRESH[8:0])
```

Common raw threshold values:

| Float threshold | Raw `CNN_THRESH` |
| ---: | ---: |
| -6.0 | -96 |
| -0.5 | -8 |
| 0.0 | 0 |
| 0.5 | 8 |
| 1.0 | 16 |

The simulation default is `SCORE_THRESHOLD=-6.0` and `CNN_THRESH_RAW=-96`,
matching the wrapper behavioral reference run.

## Main RTL Files

| File | Description |
| --- | --- |
| `HDL/rtl/AI_TRIGGER_PKG.vhd` | Shared constants and array types. `N_LANES` is currently 7. |
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
  --cnn-thresh-raw -96
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

## Bender Dependencies

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

## Synthesis and Implementation Notes

The current design is intended to be analyzed with Vivado synthesis and
implementation using the committed project:

```text
AI_Trigger_System/AI_Trigger_System.xpr
```

Primary checks for the next analysis step:

1. Confirm `CLK_CNN` timing closure at 170 MHz.
2. Confirm `CLK_ADC` timing closure at 62.5 MHz.
3. Review resource use for seven CNN wrappers plus seven async FIFOs.
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

Reports are written under:

```text
build/vivado_ooc_ai_trigger/reports/
```

The main throughput target is one 256-sample chunk every 256 ns at the ADC
input. At seven lanes, the CNN domain should have enough margin if the single
core transaction interval remains near 260-275 cycles and the implemented
`CLK_CNN` frequency is at or above 170 MHz.

## Post-Implementation SAIF Power Flow

For power analysis, use a routed netlist simulation to collect switching
activity and feed the resulting SAIF back into `report_power`:

```bash
python3 scripts/run_post_impl_saif.py
```

The default run uses the flat-port simulation wrapper as the OOC top, runs 16
samples through the existing testbench, starts SAIF recording after a 2 us
warm-up window, writes
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
