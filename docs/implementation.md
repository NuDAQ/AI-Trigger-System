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

The current routed reports were generated from the `AI_TRIGGER_TOP`
out-of-context block implementation after the five-lane, 200 MHz `CLK_CNN`
updates. They are suitable for the current block-level timing and resource
assessment. SAIF power should be regenerated after functional or activity
profile changes.

Report context:

| Item | Value |
| --- | --- |
| Vivado | 2023.2 |
| Device | `xcku5p-ffvb676-2-e` |
| Build style | Out-of-context block implementation |
| CNN lanes | 5 |
| `CLK_ADC` | 62.5 MHz |
| `CLK_CNN` | 200.000 MHz |

## Post-Implementation Simulation

The latest behavioral Vivado simulation completed successfully with the
existing testbench and the functional threshold used for validation:

| Metric | Value |
| --- | ---: |
| Samples sent | 1000 |
| Results received | 1000 |
| Chunk overflows | 0 |
| Correct predictions | 981 / 1000 |
| Average latency | 202.0 `CLK_CNN` cycles |
| Average latency | 1.010 us |

The run used `CNN_THRESH_RAW = 0` and `SCORE_THRESHOLD = 0.0`. The routed
gate-level and SAIF simulations should be rerun when sign-off power or
post-route functional evidence is needed.

## Timing Result

The routed timing report closes timing at the current clock targets:

| Metric | Value |
| --- | ---: |
| WNS | 1.109 ns |
| TNS | 0 ns |
| WHS | 0.007 ns |
| THS | 0 ns |

Per-clock timing summary:

| Clock | WNS | TNS | WHS | THS |
| --- | ---: | ---: | ---: | ---: |
| `CLK_ADC` | 12.266 ns | 0 ns | 0.039 ns | 0 ns |
| `CLK_CNN` | 1.109 ns | 0 ns | 0.007 ns | 0 ns |

The routed report has no failing setup or hold endpoints and all
user-specified timing constraints are met. The methodology report still flags
zero-delay OOC boundary assumptions and clock-group constraints that override
several point-to-point max-delay checks. The CDC report also still needs review
before system-level sign-off.

## Resource Result

The routed utilization result is:

| Resource | Used | Device utilization |
| --- | ---: | ---: |
| CLB LUT | 28,692 | 13.22% |
| CLB register | 17,886 | 4.12% |
| BRAM tile | 94 | 19.58% |
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
| CLB register | about 3.3k |
| RAMB36/FIFO | 14 |
| RAMB18 | 1 |
| DSP | 4 |

Across five lanes this accounts for the reported 20 DSPs.

## SAIF Power Result

The current routed OOC power report is vectorless and should be treated as an
estimate until a fresh SAIF run is available:

| Metric | Value |
| --- | ---: |
| Total on-chip power | 1.676 W |
| Dynamic power | 1.215 W |
| Static power | 0.461 W |
| Confidence | Medium |
| Design nets matched | NA |

The main dynamic contributors are:

| Component | Dynamic power |
| --- | ---: |
| CLB logic | 0.459 W |
| Signals | 0.372 W |
| Block RAM | 0.237 W |
| Clocks | 0.130 W |
| DSPs | 0.016 W |

The SAIF logging script first tries explicit hierarchy scopes, then falls back
to full-DUT recursive logging if too few objects are matched. Previous SAIF
runs produced high-confidence power estimates, but those reports predate the
latest CDC and lane-handshake fixes and should not be treated as the current
power sign-off result.

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
