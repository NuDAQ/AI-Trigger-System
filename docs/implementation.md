# Implementation Notes

This document summarizes implementation and report status for `AI_TRIGGER_TOP`.
It separates the current 250 MHz DAQ-facing interface target from historical
Vivado reports that were produced for the earlier 70 MHz, 16-sample-per-beat
interface.

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
`CLK_CNN`. The DAQ-facing `CLK_ADC` interface target is 250 MHz with four
samples/channel per beat. Source-clock input CDC, upstream async FIFOs, and
input gearboxes are no longer part of the trigger-system boundary.

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

Historical report context:

| Item | Value |
| --- | --- |
| Vivado | 2023.2 |
| Device | `xcku5p-ffvb676-2-e` |
| Build style | Out-of-context block implementation |
| CNN lanes | 5 |
| `CLK_ADC` | 70 MHz target |
| `CLK_CNN` | 200.000 MHz |

The pulled OOC reports below are historical 70 MHz results and should be
refreshed on the server before sign-off for the 250 MHz interface.

## Behavioral Simulation

The latest pulled behavioral Vivado simulation completed successfully before
the 250 MHz, four-sample-per-beat interface migration using the functional
threshold used for validation:

| Metric | Value |
| --- | ---: |
| Samples sent | 1000 |
| Results received | 1000 |
| Chunk overflows | 0 |
| ADC input overflows | 0 |
| Dropped triggers | 0 |
| Ring misses | 0 |
| Events saved | 163 |
| Event batches | 2608 |
| Correct predictions | 981 / 1000 |
| Average latency | 223.4 `CLK_CNN` cycles |
| Average latency | 1.117 us |

The run used `CNN_THRESH_RAW = 0` and `SCORE_THRESHOLD = 0.0`. Behavioral
simulation, routed implementation, gate-level simulation, and SAIF should be
rerun on the server for the 250 MHz `CLK_ADC` interface. The post-migration
behavioral run should show zero chunk overflows, zero dropped triggers, zero
ring misses, and one complete 64-beat event for every chunk whose
`score > CNN_THRESH`.

## Timing Result

The previous routed timing report closed timing at the historical 70 MHz
`CLK_ADC` and 200 MHz `CLK_CNN` OOC clock targets:

| Metric | Value |
| --- | ---: |
| WNS | 1.176 ns |
| TNS | 0 ns |
| WHS | 0.024 ns |
| THS | 0 ns |

Per-clock timing summary:

| Clock | WNS | TNS | WHS | THS |
| --- | ---: | ---: | ---: | ---: |
| `CLK_ADC` | 8.605 ns | 0 ns | 0.024 ns | 0 ns |
| `CLK_CNN` | 1.176 ns | 0 ns | 0.027 ns | 0 ns |

The historical routed report has no failing setup or hold endpoints and all
user-specified timing constraints were met for that run. It is not sign-off
evidence for 250 MHz `CLK_ADC`. The worst setup margin was in the `CLK_CNN`
domain. Earlier runs showed a tighter `CLK_CNN` path through the per-lane FIFO
Generator BRAM read side. Removing `DONT_TOUCH` from those FIFO instances
allowed placement/routing optimization and restored WNS from 0.654 ns to
1.176 ns.

The methodology report still flags zero-delay OOC boundary assumptions and
clock-group constraints that override several point-to-point max-delay checks.
These are OOC constraint-quality items, not current timing failures.

## Resource Result

The historical routed utilization result is:

| Resource | Used | Device utilization |
| --- | ---: | ---: |
| CLB LUT | 28,990 | 13.36% |
| CLB register | 19,830 | 4.57% |
| BRAM tile | 112 | 23.33% |
| DSP | 20 | 1.10% |
| IOB | 0 | 0.00% |

The zero IOB count is intentional for the OOC flow. It indicates that the DAQ
subsystem was not implemented as a package-level IO top. Resource use should be
rechecked after the 384-bit input/output interface migration.

## Hierarchy Preservation

The historical hierarchical utilization report shows all five generated lanes after
implementation. Each lane contains one `WRAPPER_TOP` CNN wrapper, one async
FIFO, and 4 DSPs. This is the main check that the CNN datapath was preserved
and not optimized away as unused logic.

Typical per-lane usage:

| Resource | Per lane |
| --- | ---: |
| CLB LUT | about 5.6k |
| CLB register | about 3.4k |
| RAMB36/FIFO | about 13-14 |
| RAMB18 | 1 |
| DSP | 4 |

Across five lanes this accounts for the reported 20 DSPs.

The OOC build still preserves CNN wrapper/core cells through implementation,
but it no longer marks `u_FIFO` cells as `DONT_TOUCH`. This keeps the CNN
datapath visible while leaving FIFO Generator BRAM placement and physical
optimization free to improve timing.

## CDC Result

The previous routed CDC report had no critical unknown CDC paths:

| CDC item | Count |
| --- | ---: |
| `CDC-1 Critical` | 0 |
| `CDC-3 Info` | 29 |
| `CDC-26 Warning` | 13 |

The `CDC-3` entries are recognized synchronizer/XPM crossings. The remaining
`CDC-26` warnings are reset-related paths under the OOC false-path reset
assumption. For the intended 250 MHz delivered top, the expected functional CDCs
are the per-lane `CLK_ADC` to `CLK_CNN` crossings and the CNN-trigger descriptor
return path from `CLK_CNN` to `CLK_ADC`. CNN lane metadata and trigger
descriptors use XPM handshake CDC.

## SAIF Power Result

The historical routed OOC power report is vectorless and should be treated as
an estimate until a fresh 250 MHz-interface SAIF run is available:

| Metric | Value |
| --- | ---: |
| Total on-chip power | 1.652 W |
| Dynamic power | 1.191 W |
| Static power | 0.460 W |
| Confidence | Medium |
| Design nets matched | NA |

The historical main dynamic contributors are:

| Component | Dynamic power |
| --- | ---: |
| CLB logic | 0.455 W |
| Signals | 0.370 W |
| Block RAM | 0.214 W |
| Clocks | 0.135 W |
| DSPs | 0.016 W |

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
4. Confirm the event path emits 64 beats per triggered 256-sample chunk.
5. Re-run post-implementation simulation when changing the testbench stimulus,
   threshold, lane count, CDC logic, or CNN clock.
6. Re-run SAIF power after any timing, placement, CDC, or activity-profile
   change.
7. For higher workload coverage, compare a short smoke power run against a
   longer SAIF stimulus window.
