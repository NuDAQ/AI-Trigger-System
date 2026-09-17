# Native CNN two-lane qualification

Status: functional cases pass; final routed OOC qualification is in progress.
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

## Functional evidence

| Boundary | Result |
| --- | --- |
| Local GHDL suite | 39 passed; behavioral XPM models, not vendor timing models |
| Python / CLI suite | 69 passed, including rejection of partial simulation completion |
| ADC conversion | All 4096 signed raw codes agree between the generated native fixed-point type and VHDL conversion |
| ADC-aware corpus | 96 committed windows plus all 1000 supplied NPZ windows; additive coverage |
| Continuous actual-IP / actual-XPM simulation | 1096 exact scores; 475 exact complete eight-channel events; zero normal-operation loss |
| Gaps and phase | Same 1096 windows with nine-cycle ADC gaps and 1.3 ns CNN clock phase; exact scores and events |
| Native lane reset / stalls | Reset during partial input, after complete input, and with held output; restart scores, stable result metadata and threshold snapshots pass |
| Other trigger modes | Capture-All, External, Hi-Lo and Hi-Lo-gated AI pass; deterministic gated reference score raw -1495, window starting at beat 38, anchor beat 69 |
| Runtime switching | Hi-Lo-gated AI to Capture-All passes without resetting waveform history |
| Long sink stall | Controlled loss is reported; 36 returned scores and two retained complete events drain; reset followed by the full 1096-window run recovers exactly |

The reference first encodes floating-point model inputs into signed 12-bit ADC codes (`rint(X*64)` with ADC saturation), then runs those exact ADC-representable samples through the generated native HLS C++. It does not compare lossy ADC data against unmodified floating-point inputs. These are numerical and integration checks, not a new model-accuracy or physical-voltage calibration claim.

`run_native_qualification.py` runs every vendor scenario sequentially and stores compact case logs, source manifests and `summary.json`. The current final suite is still running; individual scenarios above were already exercised during development.

## OOC evidence

The first complete OOC route failed correctly: ADC WNS -0.195 ns / TNS -7.547 ns (160 endpoints), CNN WNS +0.210 ns, overall WHS +0.007 ns and WPWS +1.300 ns. Its critical path was waveform URAM through native conversion into a lane BRAM. It is diagnostic evidence, not a passing qualification.

A fresh run with the registered gated replay path and the mode-drain correction is in progress. Final timing, utilization, route status, CDC and constraint coverage will replace this status after review. Wide subsystem ports remain internal OOC boundaries; the flow does not implement package-level I/O or claim full-board timing.

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
  --impl --out-dir build/native_ooc --keep-tcl > build/native_ooc.log 2>&1

python3 scripts/package_delivery.py --version native-two-lane
```

Use empty directories for reference generation and the qualification suite. Full vendor logs stay in each output directory; a nonzero return code or incomplete final marker fails the run. OOC fails for unresolved black boxes, missing clocks, DRC errors or negative setup/hold/pulse-width slack.

Downstream gateware/software integration, physical ADC calibration, activity-based power qualification and board validation are outside this delivery. Future one-lane full-rate operation needs a separate admission/overlap design and throughput qualification.
