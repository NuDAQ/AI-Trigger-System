# Implementation Notes

This document summarizes implementation and report status for `AI_TRIGGER_TOP`.
It records the current 250 MHz DAQ-facing interface implementation result and
keeps historical report context separate where it still matters.

## Flow

The implementation flow is block-level and out-of-context. `AI_TRIGGER_TOP` is
a DAQ subsystem block, not the package-level FPGA top, so the build avoids
mapping the wide ADC/event interfaces to package IO.

Run synthesis and implementation with:

```bash
python3 scripts/run_vivado_build.py --impl
```

The build uses Bender for RTL source collection, applies
`HDL/constraints/ai_trigger_ooc.xdc`, and writes reports to:

```text
build/vivado_ooc_ai_trigger/reports/
```

The post-implementation SAIF flow uses the flat-port simulation wrapper and the
routed checkpoint:

```bash
python3 scripts/run_post_impl_saif.py
```

## Current Report Set

The intended delivery model uses `AI_TRIGGER_TOP` as a DAQ-facing two-clock OOC
top: ADC input and event output are in `CLK_ADC`, and CNN inference is in
`CLK_CNN`. `CLK_ADC` is the 250 MHz clock arriving from the frontend ADC side,
with four samples/channel per beat. Source-clock input CDC, upstream async
FIFOs, and input gearboxes are no longer part of the trigger-system boundary.
The current version scope is only the CNN trigger wrapper path.

Current interface target:

| Item | Value |
| --- | --- |
| Build style | Out-of-context block implementation |
| CNN lanes | 5 |
| `CLK_ADC` | 250 MHz target |
| `CLK_CNN` | 200.000 MHz |
| Input beat | `ADC_DATA[383:0]` = 8 channels x 4 samples/channel x 12 bits |
| Event beat | `EVENT_DATA[383:0]`, same packing as `ADC_DATA` |
| Event length | 64 beats for one 256-sample chunk |
| Event output FIFO target | 128 beats |
| Trigger source | CNN trigger wrapper only |

Interface semantics:

- External input and event samples are clean 12-bit signed values; there is no
  external 16-bit container or low-bit zero padding.
- `DATA_STR` is beat-valid. Continuous input may assert it every `CLK_ADC`
  cycle.
- There is no upstream `ADC_READY` backpressure. When `DATA_STR=1`, the
  trigger system must synchronously accept the 384-bit beat. When `DATA_STR=0`,
  the trigger system must not advance chunk assembly, timestamp generation,
  waveform ring writes, or lane FIFO writes.
- `EVENT_VALID=0` is normal idle when no event data is available. Downstream
  samples event outputs only on `EVENT_VALID && EVENT_READY`.
- `EVENT_READY` describes peak sink capability. The trigger normally reduces
  data volume, so the output FIFO may often be empty.
- The delivered top keeps the active-high `RST` input. Internally, reset release
  is synchronized into the `CLK_ADC` and `CLK_CNN` domains and must clear state
  machines, FIFO/ring pointers, metadata-valid flags, and output-valid flags so
  reset release cannot create a false chunk or false event.

Aggregation and metadata rules:

- CNN chunks remain 256 samples/channel, so one chunk is 64 accepted `CLK_ADC`
  beats at four samples/channel per beat.
- ADC-domain aggregation should be streaming/pipelined: form CNN input write
  units as accepted beats arrive rather than buffering a full chunk before
  feeding the lane FIFO.
- `EVENT_TIMESTAMP` is a chunk-index timestamp. It labels the triggered
  256-sample chunk, not the output time, and is repeated across all 64 output
  beats for that event.
- `CHUNK_ID` and `CHUNK_TIMESTAMP` may increment at the same cadence, but keep
  their roles distinct: `CHUNK_ID` is for internal ring-buffer/metadata
  matching; `EVENT_TIMESTAMP` is externally visible.
- Event output contains only the triggered chunk itself. Do not add pre-trigger
  or post-trigger chunks in the current version.
- Internal status such as `CHUNK_OVERFLOW` may remain for simulation/debug, but
  it is not part of the first-version delivered external interface. The normal
  throughput assumption is that round-robin lane assignment plus CNN processing
  rate prevents chunk drops.
- Keep the existing five CNN lanes for the 250 MHz / 4-sample interface
  migration. The duplicate lanes are throughput resources, not separate
  configuration domains. Round-robin assignment to fixed-latency, matching CNN
  lanes is expected to preserve result order; use `CHUNK_ID` metadata to match
  and check results, but do not add a complex reorder buffer in the first
  version.
- `EVENT_OUTPUT_FIFO` should be widened/kept to the canonical 384-bit event
  beat and targeted to 128 beats of depth, buffering two complete triggered
  chunks for short downstream stalls.
- `CNN_THRESH` remains a single global 32-bit threshold container. Only bits
  `[21:0]` are interpreted as signed `ap_fixed<22,11>`. Since the external
  configuration source may not be synchronous to `CLK_CNN`, implement an
  explicit configuration CDC path and latch a threshold snapshot at CNN chunk
  start so one chunk is compared against one stable threshold value.

Current report context:

| Item | Value |
| --- | --- |
| Vivado | 2023.2 |
| Device | `xcku5p-ffvb676-2-e` |
| Build style | Out-of-context block implementation |
| CNN lanes | 5 |
| `CLK_ADC` | 250 MHz target |
| `CLK_CNN` | 200.000 MHz |

The pulled OOC reports below are the current 250 MHz / four-sample-per-beat
implementation record.

## Behavioral Simulation

The latest pulled behavioral Vivado simulation completed successfully for the
250 MHz, four-sample-per-beat interface using the functional threshold used for
validation:

| Metric | Value |
| --- | ---: |
| Samples sent | 1000 |
| Results received | 1000 |
| Chunk overflows | 0 |
| ADC input overflows | 0 |
| Dropped triggers | 0 |
| Ring misses | 0 |
| Events saved | 162 |
| Event batches | 10368 |
| Correct predictions | 982 / 1000 |
| Average latency | 203.6 `CLK_CNN` cycles |
| Average latency | 1.018 us |

The run used `CNN_THRESH_RAW = 0` and `SCORE_THRESHOLD = 0.0`. Payload reverse
matching showed all 10368 event beats aligned to the same sample/chunk and
batch index (`delta = 0`), confirming that trigger chunk id, ring-buffer chunk
id, and `EVENT_TIMESTAMP` remain aligned after the streaming 4-sample-beat
aggregation.

## Timing Result

The current routed timing report closes timing at the 250 MHz `CLK_ADC` and
200 MHz `CLK_CNN` OOC clock targets:

| Metric | Value |
| --- | ---: |
| WNS | 1.085 ns |
| TNS | 0 ns |
| WHS | 0.009 ns |
| THS | 0 ns |

Per-clock timing summary:

| Clock | WNS | TNS | WHS | THS |
| --- | ---: | ---: | ---: | ---: |
| `CLK_ADC` | 1.085 ns | 0 ns | 0.039 ns | 0 ns |
| `CLK_CNN` | 1.208 ns | 0 ns | 0.009 ns | 0 ns |

The routed report has no failing setup or hold endpoints and all user-specified
timing constraints were met. The worst `CLK_ADC` setup path is in
`WAVEFORM_RING_BUFFER` tag-memory write enable logic. The worst `CLK_CNN` setup
path is inside the HLS dense layer pipeline in one CNN lane. Earlier runs showed
a tighter `CLK_CNN` path through the per-lane FIFO Generator BRAM read side.
Removing `DONT_TOUCH` from those FIFO instances remains the intended placement
policy.

Timing lint is clean at the register level: the post-route report shows zero
unconstrained internal endpoints, zero unclocked register/latch pins, and zero
multiple-clock register/latch pins. The remaining methodology noise is
constraint-boundary related: Vivado reports 828 `XDCH-2` warnings because the
OOC input/output delays use the same 0 ns min/max value on the wide ADC/event
ports. These warnings document the current block-level zero-delay boundary
assumption; they are not routed timing failures. Board-level integration should
replace or justify these OOC boundary delays with system timing constraints.

## Resource Result

The current routed utilization result is:

| Resource | Used | Device utilization |
| --- | ---: | ---: |
| CLB LUT | 28,864 | 13.30% |
| CLB register | 18,847 | 4.34% |
| BRAM tile | 26 | 5.42% |
| URAM | 6 | 9.38% |
| DSP | 20 | 1.10% |
| IOB | 0 | 0.00% |

The zero IOB count is intentional for the OOC flow. It indicates that the DAQ
subsystem was not implemented as a package-level IO top.

## Hierarchy Preservation

The current hierarchical utilization report shows all five generated lanes after
implementation. Each lane contains one `WRAPPER_TOP` CNN wrapper, one async
FIFO, and 4 DSPs. This is the main check that the CNN datapath was preserved
and not optimized away as unused logic.

Typical per-lane usage:

| Resource | Per lane |
| --- | ---: |
| CLB LUT | about 5.6k |
| CLB register | about 3.4k |
| RAMB36/FIFO | 4 |
| DSP | 4 |

Across five lanes this accounts for the reported 20 DSPs.

The OOC build still preserves CNN wrapper/core cells through implementation,
but it no longer marks `u_FIFO` cells as `DONT_TOUCH`. This keeps the CNN
datapath visible while leaving FIFO Generator BRAM placement and physical
optimization free to improve timing.

## CDC Result

The current routed CDC report contains the expected XPM/handshake CDC structures
plus an OOC input-port/reset item:

| CDC item | Count |
| --- | ---: |
| `CDC-1 Critical` | 40 |
| `CDC-3 Info` | 27 |
| `CDC-6 Warning` | 10 |
| `CDC-15 Warning` | 247 |
| `CDC-26 Warning` | 2 |

The safe CDC crossings are the per-lane async FIFOs, XPM handshake metadata,
and the CNN-trigger descriptor return path. The `CDC-1` entries are tied to the
OOC input-port/reset false-path context and should remain a constraint-quality
review item before board-level sign-off, not a current routed timing failure.
The clock-interaction report classifies the two intra-clock domains as clean and
timed, while the `CLK_ADC` to `CLK_CNN` and `CLK_CNN` to `CLK_ADC` crossings are
intentionally ignored by asynchronous clock groups and covered by explicit FIFO
or handshake CDC structures.

## SAIF Power Result

The current routed OOC power report is vectorless and should be treated as an
estimate until a fresh 250 MHz-interface SAIF run is available:

| Metric | Value |
| --- | ---: |
| Total on-chip power | 1.301 W |
| Dynamic power | 0.844 W |
| Static power | 0.458 W |
| Confidence | Medium |
| Design nets matched | NA |

The current hierarchy report shows power dominated by the five CNN lanes:

| Component | Power |
| --- | ---: |
| `gen_lanes[0].u_LANE` | 0.151 W |
| `gen_lanes[1].u_LANE` | 0.152 W |
| `gen_lanes[2].u_LANE` | 0.154 W |
| `gen_lanes[3].u_LANE` | 0.155 W |
| `gen_lanes[4].u_LANE` | 0.153 W |
| `u_EVENT_PATH` | 0.073 W |
| `u_DIST` | 0.005 W |

The SAIF logging script first tries explicit hierarchy scopes, then falls back
to full-DUT recursive logging if too few objects are matched. Previous SAIF
runs produced high-confidence power estimates, but those reports predate the
latest CDC, input FIFO, event output FIFO, and OOC placement-flow fixes and
should not be treated as the current power sign-off result.

The full-DUT `get_objects -r /tb_AI_TRIGGER_TOP/dut/*` enumeration dominated
runtime. On the reference Ubuntu run it took about 100 minutes; the actual
post-implementation simulation completed in less than one minute after the SAIF
objects were registered.

## Sign-Off Checklist

Server rerun commands for the two-clock OOC top after the interface migration:

```bash
python3 scripts/run_vivado_sim.py --num-samples 1000
python3 scripts/run_vivado_build.py --impl
```

Before treating the implementation as sign-off quality:

1. Confirm whether the remaining input/output delay warnings are acceptable for
   this OOC block context.
2. Confirm `CLK_ADC` closes at 250 MHz and `CLK_CNN` closes at 200 MHz.
3. Confirm hierarchical utilization still shows five CNN lanes and 20 DSPs
   after any RTL or constraint change.
4. Confirm the event path emits only the triggered chunk itself: 64 beats per
   triggered 256-sample chunk, no pre/post chunks.
5. Confirm `EVENT_TIMESTAMP` is constant across those 64 beats and aligned with
   the triggered chunk id.
6. Re-run post-implementation simulation when changing the testbench stimulus,
   threshold, lane count, CDC logic, or CNN clock.
7. Re-run SAIF power after any timing, placement, CDC, or activity-profile
   change.
8. For higher workload coverage, compare a short smoke power run against a
   longer SAIF stimulus window.
