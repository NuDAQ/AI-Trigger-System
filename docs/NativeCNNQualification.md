# Native CNN two-lane qualification

Status: native two-lane integration, functional regression and routed OOC qualification passed.
Date: 2026-09-17. Device: `xcku5p-ffvb676-2-e`. Vendor tools: Vivado / Vitis HLS 2023.2 on Ubuntu 22.04.5.

## Source and interface contract

- Wrapper: `a82a717403c8346d027f62b017295d8ea6fa3344`.
- CNN Core: `eca9b12f9f49f4b7324ed9ed241a44086ca9c842`.
- Hi-Lo Trigger: v2.2.4, `5758b7c160fa74c8c55fc2a51ac114834f75bdac`.
- Two CNN lanes, 250 MHz ADC clock and 200 MHz CNN clock.
- Unchanged ADC boundary: eight channels, four signed 12-bit samples per channel per valid beat. No ADC backpressure. Raw event data remains unchanged.
- CNN consumes channels 0–3 at nominal model scale `raw/64`. Native conversion is `clamp(floor((raw+1)/2), -511, 511)`, sign-extended into 16-bit slots.
- Each lane widens two chronological 256-bit writes into one 512-bit word. An inference accepts 32 words, covering 256 times × four channels.
- Native scores occupy signed bits 20:0, scale 512, zero upper eleven bits. Thresholds use the same low-bit format and strict greater-than comparison; thresholds are snapshotted per work item.
- Start acknowledgement, last-input transfer, and result consumption are separate lifecycle events. Sixteen metadata entries have explicit occupancy protection; input storage retains its previous 128 × 256-bit capacity.
- Gated replay registers one raw batch before conversion to split the measured URAM-to-lane-BRAM critical path. Metadata and final-write completion remain aligned. Disabling Hi-Lo clears incomplete, unissued aggregates so mode drain cannot deadlock.

Bender is the only source authority. The lockfile was resolved without local overrides. Native builds record compiled source hashes in `source_manifest.json`. Delivery includes the exact `.v`, `.vh`, and `.dat` assets and a `SHA256SUMS` file. Neither wrapper qualification fixtures nor wrapper OOC constraints are imported.

The current qualified RTL is commit `ba888f65a7b3e03f6ef92c63167366c075880181`.
The system prepares gated-work metadata and event read payloads independently
of the admission control chain; valid signals preserve the original grant,
credit and window checks. No transaction latency or CNN IP change was added.
All 62 OOC manifest entries and all 65 entries per actual-IP case match the
local source exactly. The 35 dependency assets and OOC constraints are unchanged
from the initial integration. See the [source audit](qualification/native_cnn_timing_20260917/source_audit.json)
and [timing comparison](qualification/native_cnn_timing_20260917/README.md).

## Functional evidence

| Boundary | Result |
| --- | --- |
| Local GHDL suite | 39 passed; behavioral XPM models, not vendor timing models |
| Python / CLI suite | 71 passed, including rejection of partial simulation completion |
| ADC conversion | All 4096 signed raw codes agree between the generated native fixed-point type and VHDL conversion |
| ADC-aware corpus | 96 committed windows plus all 1000 supplied NPZ windows; additive coverage |
| Continuous actual-IP / actual-XPM simulation | 1096 exact scores; 475 exact complete eight-channel events; zero normal-operation loss |
| Gaps and phase | Same 1096 windows with nine-cycle ADC gaps and 1.3 ns CNN clock phase; exact scores and events |
| Native lane reset / stalls | Reset during partial input, after complete input, and with held output; restart scores, stable result metadata and threshold snapshots pass |
| Other trigger modes | Capture-All, External, Hi-Lo and Hi-Lo-gated AI pass; deterministic gated reference score raw -1495, window starting at beat 38, anchor beat 69 |
| Runtime switching | Hi-Lo-gated AI to Capture-All passes without resetting waveform history |
| Long sink stall | Controlled loss is reported; 36 returned scores and two retained complete events drain; reset followed by the full 1096-window run recovers exactly |

The reference first encodes floating-point model inputs into signed 12-bit ADC codes (`rint(X*64)` with ADC saturation), then runs those exact ADC-representable samples through the generated native HLS C++. It does not compare lossy ADC data against unmodified floating-point inputs. These are numerical and integration checks, not a new model-accuracy or physical-voltage calibration claim.

`run_native_qualification.py` runs every vendor scenario sequentially and stores compact case logs, source manifests and `summary.json`. The final `timing-qualification-02` suite completed with all five cases passing. Its [summary](qualification/native_cnn_timing_20260917/simulation_summary.json) and [reference manifest](qualification/native_cnn_20260917/reference.json) are checked in. The supplied NPZ SHA256 is `c662edb897f09ea93de1f524b1ce12f00e54b9b028565d4d2082d4c1bb0b64a4`.

## OOC evidence

The final `timing-ooc-02` run completed synthesis, optimization, placement,
physical optimization and routing with exit code zero. Reports are preserved
in [qualification/native_cnn_timing_20260917](qualification/native_cnn_timing_20260917/README.md).

| Check | Final result |
| --- | --- |
| ADC / CNN clocks | 250 / 200 MHz |
| ADC / CNN setup WNS | +0.300 / +0.382 ns |
| Overall hold WHS / pulse-width WPWS | +0.007 / +1.300 ns |
| Setup / hold / pulse-width failing endpoints | 0 / 0 / 0 |
| Routable nets | All 107,883 fully routed; zero routing errors |
| LUT / FF | 60,868 (28.05%) / 45,518 (10.49%) |
| DSP / BRAM tiles / URAM | 128 (7.02%) / 21 (4.38%) / 6 (9.38%) |
| Bonded IOB | 0; subsystem OOC ports |
| CDC | 253 safe endpoints; zero unsafe, unknown or critical crossings |
| DRC | Zero errors; 558 DSP pipeline recommendations and one no-routable-load warning |
| Constraint coverage | Zero unclocked registers, unconstrained internal endpoints or combinational loops |

The ADC setup margin improved from 41 to 300 ps; CNN setup margin improved
from 191 to 382 ps. Overall hold margin decreased from 32 to 7 ps and remains
positive. The final route passes the requested 0.200 ns setup margin gate.
These results qualify this block under
`ai_trigger_ooc.xdc`; integrating it into the full FPGA requires fresh timing
qualification. Boundary delays are zero, input hold checks are excluded,
the two clocks are asynchronous, and external reset is false-pathed. The
reported hold result therefore does not qualify upstream input hold timing.
Clock arrival is ideal at the OOC boundary. Power reports use default activity;
no SAIF-based or board power claim is made.

The first route exposed a URAM-to-conversion-to-lane-BRAM setup failure;
registered gated replay fixed that path. CDC review then identified 16
external-reset connections into the lane XPM reset sequencers.
[AMD's XPM FIFO contract](https://docs.amd.com/r/2023.1-English/ug1344-versal-architecture-libraries/XPM_FIFO_ASYNC)
requires reset synchronous to the write clock. Registering the ADC-domain
reset before each FIFO eliminated those crossings in the final route.

## Reproduce

Use a Linux environment with NumPy, `g++`, GMP development files, Bender, and Vivado/Vitis HLS 2023.2. The supplied NPZ remains an external verification input. A clean source checkout needs no Bender.local; if staging exact dependencies on another host, record their resolved source hashes and preserve their revisions separately from path overrides.

```bash
bender checkout
python3 scripts/build_native_reference.py \
  --core-root "$(bender path cnn-core)" \
  --npz /path/to/verification_data_2cv_k5s3_f12_es0.npz \
  --hls-include /tools/Xilinx/Vitis_HLS/2023.2/include \
  --output build/native_reference

python3 scripts/run_native_qualification.py \
  --reference build/native_reference \
  --output build/native_qualification \
  --vivado /tools/Xilinx/Vivado/2023.2/bin/vivado

python3 scripts/run_ghdl_tests.py tb_cnn_input_conversion \
  --generic "REFERENCE_FILE=$PWD/build/native_reference/adc_conversion.txt"
python3 scripts/run_ghdl_tests.py
python3 -m unittest discover -s tests

python3 scripts/run_vivado_build.py \
  --vivado /tools/Xilinx/Vivado/2023.2/bin/vivado \
  --impl --out-dir build/native_ooc --min-setup-slack 0.2 \
  --keep-tcl > build/native_ooc.log 2>&1

python3 scripts/package_delivery.py --version native-two-lane-timing
```

Use empty directories for reference generation and the qualification suite. Full vendor logs stay in each output directory; a nonzero return code or incomplete final marker fails the run. OOC fails for unresolved black boxes, missing clocks, DRC errors, critical CDC crossings or negative setup/hold/pulse-width slack.

Downstream gateware/software integration, physical ADC calibration, activity-based power qualification and board validation are outside this delivery. Future one-lane full-rate operation needs a separate admission/overlap design and throughput qualification.
