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

## Current Baseline

The committed OOC reports are a useful baseline, but they should not be treated
as final sign-off data. They were generated before the latest 170 MHz
`CLK_CNN` update and boundary-constraint cleanup. A fresh OOC implementation
run is required before using the numbers as final timing or power data.

Baseline report context:

| Item | Value |
| --- | --- |
| Vivado | 2023.2 |
| Device | `xcku5p-ffvb676-2-e` |
| Build style | Out-of-context block implementation |
| CNN lanes | 7 |
| Baseline `CLK_ADC` | 62.5 MHz |
| Baseline `CLK_CNN` | 175.0 MHz |

## Timing Baseline

The baseline routed timing report closes timing:

| Metric | Value |
| --- | ---: |
| WNS | 1.284 ns |
| TNS | 0 ns |
| WHS | 0.027 ns |
| THS | 0 ns |

The old report also contains boundary-constraint warnings for missing input and
output delays. Those warnings are expected for that baseline run and are one of
the reasons the report should be refreshed after the current XDC changes. The
next implementation run should confirm that `CLK_CNN` is analyzed at 170 MHz,
that the ADC/CNN clock relationship is handled as intended, and that the
methodology warnings are either resolved or explicitly justified.

## Resource Baseline

The routed utilization baseline is:

| Resource | Used | Device utilization |
| --- | ---: | ---: |
| LUT | 29,102 | 13.41% |
| FF | 15,924 | 3.67% |
| BRAM tile | 101.5 | 21.15% |
| DSP | 77 | 4.22% |
| IOB | 0 | 0.00% |

The zero IOB count is intentional for the OOC flow. It indicates that the DAQ
subsystem was not implemented as a package-level IO top.

## Hierarchy Preservation

The hierarchical utilization report shows all seven generated lanes after
implementation. Each lane contains one `WRAPPER_TOP` CNN wrapper, one async
FIFO, and 11 DSPs. This is the main check that the CNN datapath was preserved
and not optimized away as unused logic.

Typical per-lane baseline usage:

| Resource | Per lane |
| --- | ---: |
| LUT | about 4.1k |
| FF | about 2.3k |
| RAMB36/FIFO | 14 |
| RAMB18 | 1 |
| DSP | 11 |

Across seven lanes this accounts for the reported 77 DSPs.

## Power Baseline

The existing power report is vectorless:

| Metric | Value |
| --- | ---: |
| Total on-chip power | 1.442 W |
| Dynamic power | 0.983 W |
| Static power | 0.459 W |
| Confidence | Medium |

This is not a final power estimate. The report has no SAIF activity file and
Vivado reports less than 25% internal-node activity coverage. Final power
analysis should use the post-implementation SAIF flow and review:

```text
build/vivado_post_impl_saif/reports/post_route_power_saif.rpt
```

## Sign-Off Checklist

Before treating the implementation as sign-off quality:

1. Re-run OOC implementation with the current 170 MHz `CLK_CNN` constraint.
2. Confirm timing closure for `CLK_ADC` and `CLK_CNN`.
3. Confirm boundary timing warnings are resolved or documented.
4. Confirm hierarchical utilization still shows seven CNN lanes and 77 DSPs.
5. Run post-implementation simulation with the testbench and confirm all
   requested samples complete.
6. Generate SAIF from post-implementation simulation and confirm the power
   report uses the activity file with acceptable confidence.
