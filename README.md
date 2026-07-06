# AI-Trigger-System

[![MIT license](https://img.shields.io/badge/license-MIT-green)](LICENSE)

## Overview

This repository contains an FPGA AI trigger path for continuous radio detector
ADC data. The current top-level design accepts eight channels of 1 Gsps ADC
data, groups the stream into 256-sample chunks, and distributes the leading
four channels across five parallel CNN inference lanes. The number of lanes is
parameterized.

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
  AI_TRIGGER_CORE           HDL/rtl/AI_TRIGGER_CORE.vhd
  AI_TRIGGER_PKG            HDL/rtl/AI_TRIGGER_PKG.vhd
  ADC_CHUNK_DISTRIBUTOR     HDL/rtl/ADC_CHUNK_DISTRIBUTOR.vhd
  CNN_CORE_LANE x 5         HDL/rtl/CNN_CORE_LANE.vhd
    fifo_async_1024_to_64   Vivado FIFO Generator IP
    WRAPPER_TOP             cnn-core-wrapper dependency
      cnn_core              cnn-core dependency
  EVENT_CAPTURE_PATH        HDL/rtl/EVENT_CAPTURE_PATH.vhd
    WAVEFORM_RING_BUFFER    HDL/rtl/WAVEFORM_RING_BUFFER.vhd
    TRIGGER_DECISION        HDL/rtl/TRIGGER_DECISION.vhd
    TRIGGER_CDC_FIFO        HDL/rtl/TRIGGER_CDC_FIFO.vhd
    EVENT_CAPTURE_CTRL      HDL/rtl/EVENT_CAPTURE_CTRL.vhd
    EVENT_OUTPUT_FIFO       HDL/rtl/EVENT_OUTPUT_FIFO.vhd
```

Functional data flow:

```text
DAQ ADC batches @ CLK_ADC
  -> DATA_STR + ADC_DATA[1535:0]
     -> AI_TRIGGER_TOP flat-bus unpack
        -> AI_TRIGGER_CORE
           -> ADC_CHUNK_DISTRIBUTOR
              -> 256-timestep chunks, round-robin assigned to five CNN_CORE_LANE blocks
                 -> async FIFO + chunk-id CDC per lane
                    -> WRAPPER_TOP/cnn_core @ CLK_CNN
                       -> score + chunk id
                          -> threshold compare and event capture

The raw eight-channel ADC stream is also written into WAVEFORM_RING_BUFFER.
When a CNN score from channels 0-3 crosses CNN_THRESH, TRIGGER_DECISION sends
the trigger through TRIGGER_CDC_FIFO back to the ADC domain. TRIGGER_CDC_FIFO
keeps a 32-entry trigger descriptor queue in the CNN clock domain and uses an
XPM handshake CDC for the descriptor crossing. EVENT_CAPTURE_CTRL then reads
the corresponding triggered-chunk waveform window from the ring buffer and
writes all eight raw channels into EVENT_OUTPUT_FIFO. The DAQ-facing EVENT_*
ready/valid interface drains that FIFO.
```

The event waveform window is currently one chunk: the chunk whose CNN score
crossed `CNN_THRESH`.  Each event therefore emits 16 ADC-domain batches, with
`EVENT_LAST` asserted on the final batch.  A 24-bit timestamp is assigned after
16 accepted `DATA_STR` beats and is carried with the
triggered chunk to `EVENT_TIMESTAMP`.

### Clock Domains

| Clock | Nominal rate | Function |
| --- | ---: | --- |
| `CLK_ADC` | 70 MHz target | DAQ-facing ADC ingest and event output clock. |
| `CLK_CNN` | 200 MHz | Streams data into the CNN wrappers, runs inference, and aggregates trigger results. |

The reset input `RST` is active high and may be driven by an upper-level DAQ or
global-control reset source. It is treated as an asynchronous assertion at the
AI trigger boundary, then released through local reset synchronizers in the
`CLK_ADC` and `CLK_CNN` domains before fanning out to domain logic. The
delivered OOC top has no ADC source-clock domain; any 62.5 MHz source-side
stimulus or CDC belongs outside the delivered trigger block. The simulation
wrapper still uses `ADC_SRC_CLK` to model 1 GSa/s test input batches.

### Event Timestamp

`EVENT_TIMESTAMP` is a 24-bit relative timestamp in the trigger ingest
`CLK_ADC` domain. It increments once per accepted 256-sample chunk:

```text
1 timestamp tick = 16 accepted ADC batches = 256 samples/channel
```

The timestamp is generated before the CNN chunk assembly/distribution path, so
it can be shared by the current CNN trigger path and future trigger paths that
may bypass the CNN chunk assembler.  In the current contiguous stream, the
timestamp advances with the chunk window.  When a chunk triggers, the trigger
descriptor carries the timestamp through the CNN-to-ADC trigger CDC FIFO, and
the event readout presents it on every beat of the corresponding event.

At the nominal 1 GSa/s source rate, the 24-bit timestamp wraps after about
4.29 s. Relative time comparisons should be performed modulo 24 bits.

### ADC Input Format

The DAQ-facing top exposes the eight-channel ADC input as a flat 1536-bit
vector in the `CLK_ADC` domain:

```text
8 channels x 16 samples per ADC cycle x 12 bits = 1536 bits
```

The top-level port and SystemVerilog testbench use this convention:

```text
ADC_DATA[(ch * 16 + sample) * 12 +: 12] <-> ADC_DATA4(ch)(sample)
```

The CNN test vectors store one timestep as four packed 12-bit values.  The
Vivado testbench mirrors these four channels into input channels 4-7 so the
event payload is eight channels while CNN trigger decisions remain based on
channels 0-3:

```text
raw[11: 0] = ch0
raw[23:12] = ch1
raw[35:24] = ch2
raw[47:36] = ch3
raw[63:48] = unused
```

DAQ-side logic provides 12-bit signed two's-complement samples for all eight
channels in this packing.  The distributor performs the CNN-side fixed-point
conversion internally only for channels 0-3.  It converts each
`ap_fixed<12,6>`-style raw sample to the raw representation used by the CNN
input `ap_fixed<9,4>` lane: arithmetic right shift by one bit, saturate to the
9-bit raw range, then sign-extend into the 16-bit AXI-stream lane container
expected by the wrapper.  The 9-bit raw range is `-256..255`, which corresponds
to approximately `-8.0..7.96875` for `ap_fixed<9,4>`:

```text
axis_word[15: 0] = sign_extend(saturate(ch0[11:0] >>> 1, -256, 255))
axis_word[31:16] = sign_extend(saturate(ch1[11:0] >>> 1, -256, 255))
axis_word[47:32] = sign_extend(saturate(ch2[11:0] >>> 1, -256, 255))
axis_word[63:48] = sign_extend(saturate(ch3[11:0] >>> 1, -256, 255))
```

The saturation prevents fixed-point overflow wraparound.  Values already inside
the `ap_fixed<9,4>` raw range are unchanged; values above the range clamp to
`255`, and values below the range clamp to `-256`.

## Data Flow

`AI_TRIGGER_TOP` accepts `DATA_STR` and a flat 1536-bit `ADC_DATA` bus directly
in the `CLK_ADC` domain. Each valid batch contains 16 timesteps for all eight
raw ADC channels. `ADC_CHUNK_DISTRIBUTOR` runs in this same domain. A CNN chunk
is 256 timesteps, so one chunk is complete after 16 accepted `DATA_STR` beats.

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

The event readout path includes a synchronous `EVENT_OUTPUT_FIFO` in the
`CLK_ADC` domain. `EVENT_CAPTURE_CTRL` writes raw waveform batches plus
internal chunk id, timestamp, and score into this FIFO. The delivered top
exports only `EVENT_DATA`, `EVENT_LAST`, and `EVENT_TIMESTAMP`; chunk id, score,
and health counters remain internal/debug-only.

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

The latest full-system behavioral check, using 1000 samples at
`CLK_CNN = 200 MHz` and `CNN_THRESH_RAW = 0`, reports:

```text
Samples sent:     1000
Results received: 1000
Chunk overflows:  0
ADC input overflows: 0
Events saved:     163
Event batches:    2608
Dropped triggers: 0
Ring misses:      0
Accuracy:         981 / 1000 = 98.10%
Avg latency:      223.4 CNN cycles = 1.117 us
Reported TB throughput: 3.34 M samples/s
RTL/Keras score correlation: 0.9759
RTL/Keras trigger agreement: 986 / 1000 = 98.60%
RTL/Keras mean absolute score difference: 0.647
```

The reported latency is end-to-end from the start of the ADC chunk to
`CNN_OUT_VALID`. It includes ADC batching, FIFO/CDC, CNN input streaming, CNN
pipeline latency, and output aggregation. It is not the steady-state output
interval. In steady state, accepted chunks are launched at the ADC chunk rate
across the five lanes. Keras comparison is used as a sanity check for score
alignment; exact score equality is not expected because the RTL is fixed-point
HLS output.

## Output Score and Trigger Threshold

`WRAPPER_TOP` returns the CNN score in a 32-bit output word for AXI-stream
byte alignment.  The numerical score is only the low 22 bits:

```text
CNN_OUT_DATA[31:22] = padding / not used by the comparator
CNN_OUT_DATA[21:0]  = signed ap_fixed<22,11> raw score
```

`ap_fixed<22,11>` has 22 total bits, 11 integer bits including the sign bit,
and 11 fractional bits.  The score is decoded using the same convention as the
wrapper reference testbench:

```text
score_float = signed(CNN_OUT_DATA[21:0]) / 2048.0
```

`AI_TRIGGER_CORE` compares the low 22 bits of each lane score against the low
22 bits of `CNN_THRESH` as signed `ap_fixed<22,11>` values:

```text
CNN_TRIG = 1 when signed(score[21:0]) > signed(CNN_THRESH[21:0])
```

From the host/software point of view, the hardware register or port to drive is
`CNN_THRESH[31:0]`, but the comparator only uses `CNN_THRESH[21:0]`.  Configure
it as a signed 22-bit raw fixed-point value:

```text
CNN_THRESH_raw = threshold_float * 2048
threshold_float = CNN_THRESH_raw / 2048
```

The representable threshold range is:

```text
CNN_THRESH_raw: [-2097152, 2097151]
threshold_float: [-1024.0, 1023.99951171875]
```

Common raw threshold values:

| Float threshold | Raw `CNN_THRESH` |
| ---: | ---: |
| -6.0 | -12288 |
| -0.5 | -1024 |
| 0.0 | 0 |
| 0.5 | 1024 |
| 1.0 | 2048 |

The default testbench and launcher configuration uses the current full-system
functional validation point: `SCORE_THRESHOLD=0.0` and `CNN_THRESH_RAW=0`.
The older wrapper-reference fallback threshold is still available by passing
`SCORE_THRESHOLD=-6.0` and `CNN_THRESH_RAW=-12288` explicitly.

## Output Interfaces

The event stream is a `CLK_ADC` ready/valid interface.  `EVENT_DATA` carries
eight-channel raw ADC waveform batches, not the CNN fixed-point converted
values.  Its bit packing matches the ADC batch packing:

```text
EVENT_DATA[(ch * 16 + sample) * 12 + 11 : (ch * 16 + sample) * 12]
  = raw 12-bit signed ADC sample for channel ch, sample index sample
```

For the current one-chunk event window, each event emits 16 `EVENT_VALID` beats.
`EVENT_TIMESTAMP` remains constant across those 16 beats, and `EVENT_LAST` is
asserted on the final beat. The delivered top does not expose CNN score, chunk
id, overflow counters, or trigger debug pulses.

## Main RTL Files

| File | Description |
| --- | --- |
| `HDL/rtl/AI_TRIGGER_PKG.vhd` | Shared constants and array types. `N_LANES` is currently 5. |
| `HDL/rtl/AI_TRIGGER_TOP.vhd` | DAQ-facing OOC top with flat ADC/event buses and timestamp-only event metadata. |
| `HDL/rtl/AI_TRIGGER_CORE.vhd` | Internal trigger core, result aggregation, and threshold comparison. |
| `HDL/rtl/ADC_INPUT_CDC_FIFO.vhd` | Simulation/helper CDC FIFO for source-clock test streams; not instantiated by the delivered OOC top. |
| `HDL/rtl/ADC_CHUNK_DISTRIBUTOR.vhd` | ADC-domain chunk formation and round-robin lane assignment. |
| `HDL/rtl/CNN_CORE_LANE.vhd` | Per-lane async FIFO, CDC counters, AXI-stream input FSM, and CNN wrapper instance. |
| `HDL/rtl/EVENT_CAPTURE_PATH.vhd` | Trigger decision, trigger CDC, waveform ring buffer, and event readout path. |
| `HDL/rtl/WAVEFORM_RING_BUFFER.vhd` | ADC-domain circular storage for recent raw waveform chunks. |
| `HDL/rtl/EVENT_CAPTURE_CTRL.vhd` | ADC-domain event window readout controller. |
| `HDL/rtl/EVENT_OUTPUT_FIFO.vhd` | Synchronous output FIFO that decouples event capture from short downstream stalls. |
| `HDL/sim/AI_TRIGGER_TOP_TB_WRAP.vhd` | Mixed-language simulation wrapper that models source-clock test input and instantiates `AI_TRIGGER_CORE`. |
| `HDL/sim/tb_ai_trigger_top.sv` | SystemVerilog simulation testbench. |
| `scripts/run_vivado_sim.py` | Batch-mode Vivado simulation launcher. |
| `run_sim.tcl` | Vivado simulation setup used by both GUI and batch flows. |

## Simulation

The recommended terminal flow for the current functional validation point is:

```bash
python3 scripts/run_vivado_sim.py \
  --num-samples 1000
```

The script opens `AI_Trigger_System/AI_Trigger_System.xpr`, sources
`run_sim.tcl`, and runs the behavioral xsim testbench in Vivado batch mode.

To reproduce the wrapper-reference fallback threshold instead:

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

Triggered waveform events are written to:

```text
AI_Trigger_System/AI_Trigger_System.sim/sim_1/behav/xsim/ai_trigger_events.csv
```

The event CSV includes `event_timestamp`, a 24-bit chunk timestamp that is
constant across all 16 batches of a triggered-chunk event.

After a full-system run, validate the score CSV, event CSV, and simulation log
with:

```bash
python3 scripts/analyze_vivado_sim_results.py \
  AI_Trigger_System/AI_Trigger_System.sim/sim_1/behav/xsim/ai_trigger_results.csv \
  --log AI_Trigger_System/AI_Trigger_System.sim/sim_1/behav/xsim/simulate.log \
  --event-csv AI_Trigger_System/AI_Trigger_System.sim/sim_1/behav/xsim/ai_trigger_events.csv \
  --expected-samples 1000 \
  --expected-cores 5 \
  --expected-cnn-mhz 200 \
  --expected-thresh-raw 0 \
  --max-overflows 0
```

At the current threshold-0 validation point, every `score > CNN_THRESH` chunk is
expected to produce exactly one 16-batch event. The latest checked run has 163
positive-score chunks and 163 complete events, with no missing, duplicate, or
extra event chunks.

## Continuous Validation Plots

Full-dataset score validation plots are generated with PyROOT:

```bash
python3 analysis/Continuous/plot_continuous_validation.py
```

The script reads the Vivado simulation score CSV and the Keras comparison CSV,
then writes:

```text
analysis/Continuous/continuous_validation.root
analysis/Continuous/continuous_validation_report.pdf
```

The report includes score agreement, score residuals, absolute score error,
threshold-0 confusion matrices, latency, and score distributions by label.

## Synthesis and Implementation Notes

The current design is intended to be analyzed with Vivado synthesis and
implementation using the committed project:

```text
AI_Trigger_System/AI_Trigger_System.xpr
```

Primary checks for the next analysis step:

1. Confirm `CLK_CNN` timing closure at 200 MHz.
2. Confirm `CLK_ADC` timing closure at 70 MHz.
3. Review resource use for five CNN wrappers plus the event/lane FIFOs.
4. Check XPM/FIFO Generator resource mapping and reset behavior.
5. Review inter-clock timing constraints between `CLK_ADC` and `CLK_CNN`.

The recommended OOC build command is:

```bash
python3 scripts/run_vivado_build.py --impl
```

This flow uses Bender to collect RTL sources, removes dependency board-level
constraints, applies `HDL/constraints/ai_trigger_ooc.xdc`, and runs the block
out-of-context. This is intentional: `AI_TRIGGER_TOP` is a DAQ subsystem block,
not the package-level FPGA top. Running normal top-level implementation on this
entity would map the wide ADC/event interfaces to package IO and produce
misleading resource, timing, and IO utilization results.

OOC build reports are written under:

```text
build/vivado_ooc_ai_trigger/reports/
```

Post-implementation SAIF and timing reports are written under:

```text
build/vivado_post_impl_saif/reports/
```

The current checked-in reports predate the DAQ-facing top split and should be
refreshed on the server before sign-off. The previous routed OOC result
summary, after the input CDC FIFO, 70 MHz ingest clock target, CDC cleanup, and
lane FIFO placement optimization, was:

| Metric | Current report |
| --- | ---: |
| Timing | WNS 1.176 ns, TNS 0, WHS 0.024 ns |
| `CLK_ADC` | 70 MHz target |
| `CLK_CNN` | 200 MHz target |
| CDC | `CDC-1 Critical = 0`; only recognized CDC info/reset warnings remain |
| CLB LUT | 28,990 |
| CLB registers | 19,830 |
| BRAM tiles | 112 |
| DSP | 20 |
| IOB | 0 |
| Vectorless power | 1.652 W total, Medium confidence |
| Dynamic power | 1.191 W |
| Static power | 0.460 W |

The hierarchical utilization report should show all five lanes present. Each
lane contains one CNN wrapper and one async FIFO, so the CNN datapath was not
optimized away in implementation.

The previous SAIF hierarchy report showed dynamic power dominated by the five CNN
lanes. Each lane is about 0.182-0.186 W, including about 0.146-0.150 W in the
wrapper and about 0.035 W in the FIFO. The distributor is about 0.007 W.

The OOC build flow preserves the CNN wrapper/core hierarchy but intentionally
does not apply `DONT_TOUCH` to the per-lane FIFO Generator instances. Leaving
the lane FIFOs optimizable restored the 200 MHz `CLK_CNN` margin by allowing
Vivado to improve BRAM-heavy FIFO placement/routing.

The refreshed routed timing report should confirm the two-clock OOC boundary:
`CLK_ADC` at 70 MHz and `CLK_CNN` at 200 MHz. The OOC constraints intentionally
use zero-delay IO boundary assumptions, so methodology warnings around IO delay
and clock-group/max-delay interactions still need review before system-level
sign-off.

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

The latest checked high-confidence SAIF report was a 16-sample smoke run
generated by this full-DUT fallback. The scoped hierarchy patterns matched only
the top-level DUT signals in xsim; the fallback logged 136,469 objects and the
power report matched 93% of design nets. The report estimates 0.684 W total
on-chip power, with 0.231 W dynamic and 0.453 W static power. On the reference
Ubuntu run, the full-DUT object enumeration took about 68 minutes; the actual
16-sample gate simulation completed in about one minute. The detailed xsim trace
is kept in `build/vivado_post_impl_saif/xsim/xsim.log`.

High power confidence means Vivado received good switching activity coverage
for this workload window. It does not, by itself, prove that datapath logic was
preserved. Logic preservation is checked separately through hierarchical
utilization, timing, and simulation: the current reports still show all five
lanes, all five CNN wrappers, lane FIFOs, and 20 DSP blocks present.

The default SAIF wrapper now uses the same threshold-0 operating point as the
behavioral functional validation.  Pass explicit threshold arguments only when
you intentionally want a different activity profile:

```bash
python3 scripts/run_post_impl_saif.py \
  --samples 64
```
