# Single-channel template simulation and scans, fixed CNN gain x6

Branch: `v3.6`. Sliding simulation source export: `3eca61e`; continuous-stream
scan driver: `f40d77e`. Native CNN, Wrapper and Hi-Lo pins remain `eca9b12`,
`a82a717` and `047d14a`. Server: `100.71.11.92`, Vivado/Vitis HLS 2023.2.

## Input and reference boundary

The input is the four examples in `data/noise_2mV_for_x480_Sep_30`: 2, 3, 4 and
10 sigma, each a distinct selected 3 m event with a distinct noise realization.
Each CSV has 1000 points at 1 ns, from -100 to 899 ns. The pulse peaks at index
500, or 400 ns. Only ADC/CNN channel zero is populated; all other channels are
zero. `channel_used` identifies the original simulated antenna, not the FPGA
input assignment. These are four selected examples of a 59-event set.

Physical voltages are converted with the existing 0.8 Vpp 12-bit ADC mapping.
Hi-Lo and the raw event path receive those codes directly. Gain six is applied
only at CNN ingress, followed by native symmetric saturation. CNN Core
Generator's already normalized test corpus and model weights are unchanged.
No samples in these four noisy examples clip at either boundary.

`input_audit.json` records amplitudes, full-record residual noise RMS and
input hashes. The `noise` stream variant is `noisy - noiseless` in volts,
followed by ADC quantization; it is not the subtraction of two quantized
records. The four residual records contain only 4 microseconds of noise.

## Completed sliding scan

Four fresh isolated Vivado projects compile the Bender-locked native CNN and
actual XPM models. Each waveform is scanned with all 745 stride-one,
256-sample windows. Every one of the 2980 native score words matches the
supplied x480 `_scores.csv` bit for bit. Scores use signed low 21 bits with
unit 1/512. External threshold words use signed 32 bits with unit 1/16.
Word 45 is 2.8125, the nearest representable value to the supplied 2.807.
The comparison is strictly `score > threshold`.

| Example | Maximum native score | Windows over 2.8125 | Complete output events |
| --- | ---: | ---: | ---: |
| 2 sigma | 1.365234375 | 0 / 745 | 0 |
| 3 sigma | 6.697265625 | 163 / 745 | 163 |
| 4 sigma | 10.53125 | 191 / 745 | 191 |
| 10 sigma | 47.525390625 | 233 / 745 | 233 |

All 587 event frames contain exactly 64 beats. All 37,568 raw event beats
match the original ADC samples in their respective window, including zeros
on unused channels. Score, chunk, timestamp, framing and threshold acceptance
also match. All four runs report zero input/chunk overflows, dropped triggers,
ring misses and event loss. `sliding/raw_event_validation.json` records these
checks; compressed event CSVs retain the full evidence.

`sliding/threshold_scan.csv` sweeps 801 representable words, 0..800, or 0..50,
over the saved exact scores. `sliding/scan_summary.csv`, per-example annotated
scores and plots retain both values and window positions. The 587 repeated
windows are not 587 independent neutrino events. Adjacent windows share
255 of 256 samples; their over-threshold fraction is an observed window
fraction, not a population efficiency, independent-event probability or Hz.

## Continuous-stream scan design

`scripts/run_template_stream_scan.py` uses the existing bench without changing
RTL or testbench. It clones the compiled XSim snapshot into private workers,
starts a new simulator process and reset per scenario, and checks compiled
system source hashes against its source export. The independent qualified HLS
engine and weights are copied into new scratch storage, leaving its original
reference artifacts intact.

Inputs contain the complete waveform once, with at least 256 leading and
256 trailing zero samples, rounded to whole chunks. Adding `phase` leading
samples changes arrival alignment without scaling or reordering the waveform.
Continuous AI expects one score per chunk. Hi-Lo-only expects no CNN work.
Gated AI checks each accepted centered event against its raw window and HLS
score. Centered start is `256 * timestamp + 4 * trigger_offset - 124` in the
normalized stream. Original waveform coordinates are also retained.

The 1536-scenario plan covers noisy/noiseless/residual baseline streams;
256 continuous-AI arrival phases; 16 Hi-Lo aggregate phases; and raw thresholds
20, 25, 30, 35, 40 crossed with Hi-Lo windows 2, 4, 5, 8, 16. `BIN_THR=1` and
`COINC_WINDOW=3` are fixed. Gated AI runs at word 45 and at the minimum external
threshold word to retain every admitted CNN window. A zero-event result must
be separated into no Hi-Lo admission, CNN rejection, and busy-path loss.

Hi-Lo dropped requests and the sticky event-loss bit are reported rather than
treated as a numerical mismatch. Input/chunk overflows and ring misses fail
the scan. The 1 us records do not exercise long-run rate blanking or establish
sustained hardware throughput.

The score CSV gives a gated start chunk but no beat offset for rejected work.
Rejected scores are compared with every feasible four-sample-aligned window
in that chunk; equal quantized scores can leave the input position ambiguous.
Those ambiguities are explicitly counted. Accepted raw-event windows and
continuous chunks have exact positions and independent HLS comparisons.

Full parameter-scan results will be retained in this directory after completion.

## Provenance and reproduction

Use the commands under the repository README's scan section. The source
archive checksums are in `sliding_source_snapshot.json` and
`stream_source_snapshot.json`; `sliding_source_export.json` records the actual
archive root commit and dependency pins. The archives omit `.git`; the original
sliding runtime's unavailable Git fields are not used as provenance. Four
compiled file lists match, as recorded in `sliding/source_parity.json`.

Server sliding artifacts:
`/home/work1/Works/_codex_template_scan_x6_20261004_3eca61e/build/template_scan_x6_20261004/sliding`.
Server stream artifacts:
`/home/work1/Works/_codex_template_stream_x6_20261004_f40d77e/build/full_scan`.
Heavy projects, generated input hex, reference binaries and full runtime outputs
remain in ignored local/server `build/` directories.

The 103-test local Python suite passes using the existing Homebrew Python
environment with NumPy and Matplotlib. Production HDL is unchanged by the
scan commits, so routed OOC timing remains the source-matched result in
`../fixed_cnn_gain_x6_20261004/README.md`; this scan is not a new routed run or
board qualification.
