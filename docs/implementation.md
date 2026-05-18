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

The current post-implementation reports were generated from the flat-port
wrapper design after the 170 MHz `CLK_CNN` update. They are suitable for the
current block-level timing, resource, and SAIF power assessment.

Report context:

| Item | Value |
| --- | --- |
| Vivado | 2023.2 |
| Device | `xcku5p-ffvb676-2-e` |
| Build style | Out-of-context block implementation |
| CNN lanes | 7 |
| `CLK_ADC` | 62.5 MHz |
| `CLK_CNN` | 170.010 MHz |

## Post-Implementation Simulation

The current gate-level functional simulation completed successfully with the
existing testbench:

| Metric | Value |
| --- | ---: |
| Samples sent | 16 |
| Results received | 16 |
| Chunk overflows | 0 |
| Correct predictions | 16 / 16 |
| Average latency | 286.6 `CLK_CNN` cycles |
| Average latency | 1.686 us |

The run used `CNN_THRESH=-96`, corresponding to a threshold of -6.0. The only
positive label in the 16-sample window was sample 9, and the post-implementation
simulation predicted it correctly.

## Timing Result

The routed timing report closes timing at the current clock targets:

| Metric | Value |
| --- | ---: |
| WNS | 1.504 ns |
| TNS | 0 ns |
| WHS | 0.029 ns |
| THS | 0 ns |

Per-clock timing summary:

| Clock | WNS | TNS | WHS | THS |
| --- | ---: | ---: | ---: | ---: |
| `CLK_ADC` | 12.903 ns | 0 ns | 0.030 ns | 0 ns |
| `CLK_CNN` | 1.504 ns | 0 ns | 0.029 ns | 0 ns |

The report still contains OOC boundary warnings for missing input and output
delays: 779 input ports and 12 output ports. There are no unconstrained
internal endpoints and all user-specified timing constraints are met. The
boundary warnings should still be reviewed before system-level sign-off.

## Resource Result

The routed utilization result is:

| Resource | Used | Device utilization |
| --- | ---: | ---: |
| LUT | 29,105 | 13.41% |
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

Typical per-lane usage:

| Resource | Per lane |
| --- | ---: |
| LUT | about 4.1k |
| FF | about 2.3k |
| RAMB36/FIFO | 14 |
| RAMB18 | 1 |
| DSP | 11 |

Across seven lanes this accounts for the reported 77 DSPs.

## SAIF Power Result

The current power report uses switching activity from post-implementation xsim:

| Metric | Value |
| --- | ---: |
| Total on-chip power | 1.414 W |
| Dynamic power | 0.955 W |
| Static power | 0.458 W |
| Confidence | High |
| Design nets matched | 98% |

The main dynamic contributors are:

| Component | Dynamic power |
| --- | ---: |
| Signals | 0.343 W |
| CLB logic | 0.320 W |
| Block RAM | 0.147 W |
| Clocks | 0.107 W |
| DSPs | 0.039 W |

The SAIF logging script first tries explicit hierarchy scopes, then falls back
to full-DUT recursive logging if too few objects are matched. In the current
xsim log, the explicit scopes matched only 14 top-level DUT objects. The
fallback logged 162,789 additional objects, for a total logged object count of
162,803. This produced the 98% SAIF net match and High power confidence.

The full-DUT `get_objects -r /tb_AI_TRIGGER_TOP/dut/*` enumeration dominated
runtime. On the reference Ubuntu run it took about 100 minutes; the actual
post-implementation simulation completed in less than one minute after the SAIF
objects were registered.

## Sign-Off Checklist

Before treating the implementation as sign-off quality:

1. Confirm whether the remaining input/output delay warnings are acceptable for
   this OOC block context.
2. Confirm hierarchical utilization still shows seven CNN lanes and 77 DSPs
   after any RTL or constraint change.
3. Re-run post-implementation simulation when changing the testbench stimulus,
   threshold, lane count, or CNN clock.
4. Re-run SAIF power after any timing, placement, or activity-profile change.
5. For higher workload coverage, compare the 16-sample power result against a
   longer 32- or 64-sample SAIF run.
