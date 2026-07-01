# Implementation Notes

This document summarizes the current synthesis, implementation, and power
analysis status for `AI_TRIGGER_TOP`. It is intended to capture report-level
details that are too specific for the main README.

## Flow

The implementation flow is block-level and out-of-context. `AI_TRIGGER_TOP` is
a DAQ subsystem block, not the package-level FPGA top, so the build avoids
mapping the wide ADC and score interfaces to package IO.

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

The checked-in RTL includes an input CDC FIFO between the ADC/decoder source
stream and the trigger ingest domain, a downstream event output FIFO, and
XPM-based control CDC for lane metadata and CNN-to-ADC trigger descriptors. The
current pulled OOC reports were generated after these CDC changes and after the
OOC flow stopped applying `DONT_TOUCH` to the per-lane FIFO Generator
instances.

Report context:

| Item | Value |
| --- | --- |
| Vivado | 2023.2 |
| Device | `xcku5p-ffvb676-2-e` |
| Build style | Out-of-context block implementation |
| CNN lanes | 5 |
| `ADC_SRC_CLK` | 62.5 MHz nominal source-side batch clock |
| `CLK_ADC` | 70 MHz target |
| `CLK_CNN` | 200.000 MHz |

## Behavioral Simulation

The latest pulled behavioral Vivado simulation completed successfully using the
functional threshold used for validation:

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

The run used `CNN_THRESH_RAW = 0` and `SCORE_THRESHOLD = 0.0`. The routed
gate-level and SAIF simulations should be rerun when sign-off power or
post-route functional evidence is needed.

## Timing Result

The current routed timing report closes timing at the intended OOC clock
targets:

| Metric | Value |
| --- | ---: |
| WNS | 1.176 ns |
| TNS | 0 ns |
| WHS | 0.024 ns |
| THS | 0 ns |

Per-clock timing summary:

| Clock | WNS | TNS | WHS | THS |
| --- | ---: | ---: | ---: | ---: |
| `ADC_SRC_CLK` | 12.972 ns | 0 ns | 0.041 ns | 0 ns |
| `CLK_ADC` | 8.605 ns | 0 ns | 0.024 ns | 0 ns |
| `CLK_CNN` | 1.176 ns | 0 ns | 0.027 ns | 0 ns |

The routed report has no failing setup or hold endpoints and all
user-specified timing constraints are met. The worst setup margin is still in
the `CLK_CNN` domain. Earlier runs showed a tighter `CLK_CNN` path through the
per-lane FIFO Generator BRAM read side. Removing `DONT_TOUCH` from those FIFO
instances allowed placement/routing optimization and restored WNS from
0.654 ns to 1.176 ns.

The methodology report still flags zero-delay OOC boundary assumptions and
clock-group constraints that override several point-to-point max-delay checks.
These are OOC constraint-quality items, not current timing failures.

## Resource Result

The routed utilization result is:

| Resource | Used | Device utilization |
| --- | ---: | ---: |
| CLB LUT | 28,990 | 13.36% |
| CLB register | 19,830 | 4.57% |
| BRAM tile | 112 | 23.33% |
| DSP | 20 | 1.10% |
| IOB | 0 | 0.00% |

The zero IOB count is intentional for the OOC flow. It indicates that the DAQ
subsystem was not implemented as a package-level IO top.

## Hierarchy Preservation

The hierarchical utilization report shows all five generated lanes after
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

The current routed CDC report has no critical unknown CDC paths:

| CDC item | Count |
| --- | ---: |
| `CDC-1 Critical` | 0 |
| `CDC-3 Info` | 29 |
| `CDC-26 Warning` | 13 |

The `CDC-3` entries are recognized synchronizer/XPM crossings. The remaining
`CDC-26` warnings are reset-related paths under the OOC false-path reset
assumption. The input ADC source crossing is implemented by `ADC_INPUT_CDC_FIFO`
with `xpm_fifo_async`; its XPM reset is driven by the source-clock synchronized
reset. CNN lane metadata and trigger descriptors use XPM handshake CDC.

## SAIF Power Result

The current routed OOC power report is vectorless and should be treated as an
estimate until a fresh SAIF run is available:

| Metric | Value |
| --- | ---: |
| Total on-chip power | 1.652 W |
| Dynamic power | 1.191 W |
| Static power | 0.460 W |
| Confidence | Medium |
| Design nets matched | NA |

The main dynamic contributors are:

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

Before treating the implementation as sign-off quality:

1. Confirm whether the remaining input/output delay warnings are acceptable for
   this OOC block context.
2. Confirm hierarchical utilization still shows five CNN lanes and 20 DSPs
   after any RTL or constraint change.
3. Re-run post-implementation simulation when changing the testbench stimulus,
   threshold, lane count, CDC logic, or CNN clock.
4. Re-run SAIF power after any timing, placement, CDC, or activity-profile
   change.
5. For higher workload coverage, compare a short 16-sample power run against a
   longer 32- or 64-sample SAIF run.
