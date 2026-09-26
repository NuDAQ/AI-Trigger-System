# 30-chunk routed SAIF power qualification

This package records a short activity-based OOC power estimate for the current
two-lane production `AI_TRIGGER_TOP`. It is intended to replace the previous
five-lane power number as the current block-level estimate.

## Qualified configuration

| Item | Value |
| --- | --- |
| Source commit | `978e6ee0a0421f7d18d8b32cc2d6ef5cff0c996e` |
| Tool | Vivado 2023.2 build 4029153, Linux |
| Part | `xcku5p-ffvb676-2-e` |
| Clocks | `CLK_ADC=250 MHz`, `CLK_CNN=200 MHz` |
| Activity | 30 chunks, reference windows 96 through 125 |
| Mode / threshold | continuous AI / `CNN_THRESH=0` |
| Simulation | post-route functional, no SDF |
| SAIF capture start | 0.5 us |
| Routed DCP SHA-256 | `877465bfcb5552639473f3650fdd40006975c02099b188032b1782142103ab6a` |
| NPZ SHA-256 | `c662edb897f09ea93de1f524b1ce12f00e54b9b028565d4d2082d4c1bb0b64a4` |
| Reference manifest SHA-256 | `392bc2c60dc40b85957e8c77cf1d95338e30fe2696cea1783fa3d67827b755bc` |

The reference contains 1,096 windows. Windows 0 through 95 are the built-in
Vitis cross-check corpus, so window 96 is the first window from the supplied
NPZ.

## Result

| Metric | Result |
| --- | ---: |
| Total on-chip power | 1.972 W |
| Dynamic power | 1.510 W |
| Device static power | 0.463 W |
| Vivado confidence | High |
| Design nets matched | 173,782 / 174,661 (99.497%) |
| Junction temperature | 28.4 C |
| Setup WNS / TNS | 0.180 ns / 0 ns |
| Hold WHS / THS | 0.007 ns / 0 ns |
| Pulse-width WPWS / TPWS | 1.300 ns / 0 ns |

Dynamic component estimates are 0.545 W signals, 0.520 W CLB logic, 0.261 W
clocks, 0.082 W block RAM, 0.054 W URAM, and 0.047 W DSPs. The power report uses
the default 25 C ambient, 250 LFM airflow, medium-profile heat sink, and
12-to-15-layer medium board assumptions.

The routed design uses 61,026 CLB LUTs, 45,588 CLB registers, 21 block RAM
tiles, 6 URAMs, and 128 DSPs. All 108,150 routable nets are fully routed and no
routing errors are reported. All user timing constraints are met.

## Functional and activity checks

XSim printed:

```text
PASS production SAIF chunks=30 events=10 start_window=96
```

The testbench compared every expected decision and complete eight-channel raw
event waveform and rejected event loss. The SAIF logger required both routed
CNN lane scopes to be present independently.

| Logged scope | Objects |
| --- | ---: |
| Top boundary | 33 |
| Core boundary | 173 |
| ADC/CNN reset logic | 5 / 4 |
| Live distributor | 560 |
| CNN lane 0 | 50,312 |
| CNN lane 1 | 50,285 |
| Result arbiter | 102 |
| Multimode event path | 7,003 |
| Total | 108,477 |

Vivado imported the SAIF successfully and matched 99.497% of design nets. The
remaining activity was estimated probabilistically.

## Warnings and limits

- This is OOC FPGA block power, not full gateware, board, supply, or thermal
  validation. Wide DAQ ports are not assigned to package pins.
- Thirty chunks are enough for a quick representative result, but not for a
  precise workload distribution. Different thresholds, trigger modes, event
  rates, noise records, or longer input traces can change dynamic power.
- The gate simulation is functional and does not annotate SDF. Static routed
  timing is reported separately; the SAIF waveform is not timing-accurate.
- Vivado warns that high-fanout reset activity is asserted for an excessive
  period in the sampled trace. The warning is retained because it can bias the
  estimate.
- The OOC checkpoint has idealized block-boundary clocking and emits the usual
  missing `HD.CLK_SRC` warnings. Full integration must recheck clock insertion,
  I/O delays, CDC, timing, and power.
- DRC reports 559 warnings and no errors: 302 `DPIP-2`, 128 `DPOP-3`, 128
  `DPOP-4`, and one `RTSTAT-10`. The first 558 are DSP pipeline recommendations;
  the last is a no-routable-load warning.
- `run_manifest.json` records `tracked_worktree_dirty=true` because the fresh
  build updates version-controlled generated checkpoints and reports before the
  manifest is written. The source commit and individual source-file hashes are
  recorded in the same manifest; the source checkout was clean before the
  build.

## Reproduction

From the repository root on the configured Ubuntu host:

```bash
python3 scripts/run_post_impl_saif.py \
  --vivado /tools/Xilinx/Vivado/2023.2/bin/vivado \
  --bender /home/work1/.cargo/bin/bender \
  --npz input/verification_data_2cv_k5s3_f12_es0.npz \
  --reference build/native_validation/reference \
  --keep-tcl
```

The run first creates a fresh routed production checkpoint and then runs XSim,
imports the generated SAIF, and writes the power, utilization, and timing
reports. `run_manifest.json` hashes the large ignored SAIF plus every retained
report.

## Retained evidence

- `post_route_power_saif.rpt`: activity-based Vivado power report.
- `post_route_timing_summary_for_saif.rpt`: timing summary for the same routed
  checkpoint.
- `post_route_utilization_for_saif.rpt`: utilization for that checkpoint.
- `post_route_status.rpt` and `post_route_drc.rpt`: route completeness and DRC.
- `xsim.log`: scope counts and functional completion marker.
- `run_manifest.json`: inputs, tool, source identities, DCP hash, and output
  hashes.
- `run_vivado_post_impl_saif.tcl`: generated launcher with the exact run
  parameters.
- `SHA256SUMS`: integrity checks for this evidence package.
