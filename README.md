# AI-Trigger-System

[![MIT license](https://img.shields.io/badge/license-MIT-green)](LICENSE)

## Introduction

A direct CNN trigger for ARIANNA, a neutrino experiment. This is a 4-channel trigger module
that feeds continuous 1 Gsps ADC data through a cluster of 6 parallel CNN inference cores,
producing real-time trigger decisions at the full sample rate with no pre-trigger requirement.
Here are the newest releases for the
[CNN core generator](https://github.com/NuDAQ/CNN-Core-Generator/releases) and
[CNN core wrapper](https://github.com/NuDAQ/CNN-Core-Wrapper/releases).

### The Structure

#### Module Hierarchy

```
AI_TRIGGER_TOP              HDL/rtl/AI_TRIGGER_TOP.vhd        (top-level, structural)
├── AI_TRIGGER_PKG          HDL/rtl/AI_TRIGGER_PKG.vhd        (shared type definitions)
├── ADC_CHUNK_DISTRIBUTOR   HDL/rtl/ADC_CHUNK_DISTRIBUTOR.vhd (CLK_ADC: batch accumulator + round-robin)
└── CNN_CORE_LANE × 6       HDL/rtl/CNN_CORE_LANE.vhd
    └── WRAPPER_TOP         [dep: cnn-core-wrapper v3.0.1]
        └── cnn_core        [dep: cnn-core v3.0.2]
```

#### Data Flow

```
ADC_DATA4  (4 ch × 16 samples × 12-bit, CLK_ADC domain)
    │
    ▼
ADC_CHUNK_DISTRIBUTOR
    │  Counts DATA_STR pulses; after 16 pulses a 256-sample chunk is complete.
    │  Round-robin: chunk N → lane (N mod 6).
    │  Each lane: True Dual-Port BRAM (256 × 64-bit, 1 BRAM_18K).
    │             4-phase CDC handshake (CLK_ADC write → CLK_CNN read).
    │
    ├──► CNN_CORE_LANE [0] ──► WRAPPER_TOP ──► cnn_core
    ├──► CNN_CORE_LANE [1] ──► WRAPPER_TOP ──► cnn_core
    ├──► CNN_CORE_LANE [2] ──► WRAPPER_TOP ──► cnn_core
    ├──► CNN_CORE_LANE [3] ──► WRAPPER_TOP ──► cnn_core
    ├──► CNN_CORE_LANE [4] ──► WRAPPER_TOP ──► cnn_core
    └──► CNN_CORE_LANE [5] ──► WRAPPER_TOP ──► cnn_core
                                    │
                             score[0..5] (16-bit signed, ap_fixed<16,6>)
                                    │
                             comparator (CNN_THRESH), per lane
                                    │
                                    ▼
                       CNN_TRIG ← OR of all lane triggers
                       (CLK_CNN, 1-cycle pulse)
```

#### Clock Domains

| Clock     | Typical frequency | Responsibilities                                        |
|-----------|-------------------|---------------------------------------------------------|
| `CLK_ADC` | 62.5 MHz          | ADC ingestion (16 samples/cycle = 1 Gsps), chunk accumulation, BRAM write |
| `CLK_CNN` | 200 MHz           | CNN inference (all 6 cores), BRAM read, AXI-S streaming, trigger comparison |

`RST` is shared (active-high, synchronous to `CLK_ADC`).
Each `CNN_CORE_LANE` re-times it into the `CLK_CNN` domain via a 2-FF synchronizer and drives
the active-low `rst_n` that `WRAPPER_TOP` requires.

#### Chunk Timing and Throughput

| Quantity                     | Value                           | Notes                                             |
|------------------------------|---------------------------------|---------------------------------------------------|
| ADC sample rate              | 1 Gsps                          | 16 samples per `CLK_ADC` cycle at 62.5 MHz        |
| Batch period                 | 16 ns                           | One `CLK_ADC` cycle                               |
| Chunk size                   | 256 samples × 4 channels        | 256 × 64-bit words; fills in 16 batches           |
| Chunk arrival period         | 256 ns                          | 16 batches × 16 ns                                |
| CNN interval (single core)   | ~260 cycles @ 200 MHz ≈ 1300 ns | HLS cosim confirmed; interval dominates latency   |
| Minimum cores required       | ⌈1300 / 256⌉ = 6               | To sustain 1 chunk per 256 ns average             |
| Per-lane chunk cadence       | 6 × 256 ns = 1536 ns            | Each lane finishes (1300 ns) before its next chunk |

64-bit word format (one sample across 4 channels):
```
[63:48]  ch3  (4-bit zero pad | 12-bit ADC)
[47:32]  ch2
[31:16]  ch1
[15: 0]  ch0
```

#### Top-Level Port Interface (`AI_TRIGGER_TOP`)

**Ports**

| Port            | Dir | Width      | Clock     | Description                                                                                           |
|-----------------|-----|------------|-----------|-------------------------------------------------------------------------------------------------------|
| `CLK_ADC`       | in  | 1          | —         | ADC batch clock (~62.5 MHz)                                                                           |
| `CLK_CNN`       | in  | 1          | —         | CNN inference clock (~200 MHz)                                                                        |
| `RST`           | in  | 1          | CLK_ADC   | Active-high synchronous reset                                                                         |
| `DATA_STR`      | in  | 1          | CLK_ADC   | One pulse per 16-sample batch                                                                         |
| `ADC_DATA4`     | in  | 4×16×12    | CLK_ADC   | ADC samples, `adc_data4_type` (defined in `AI_TRIGGER_PKG`)                                          |
| `CNN_THRESH`    | in  | 16         | static    | Signed trigger threshold in ap_fixed\<16,6\> raw units (score = raw / 1024). See table below.        |
| `CNN_TRIG`      | out | 1          | CLK_CNN   | 1-cycle pulse when any lane score > `CNN_THRESH`                                                      |
| `CNN_OUT_DATA`  | out | 16         | CLK_CNN   | Most recent CNN score, ap_fixed\<16,6\> raw                                                           |
| `CNN_OUT_VALID` | out | 1          | CLK_CNN   | Score valid strobe (one cycle, from whichever lane completed last)                                    |
| `CHUNK_OVERFLOW`| out | 1          | CLK_ADC   | Sticky: a chunk arrived while its assigned lane BRAM was not yet drained                              |

`CNN_TRIG` is in the **CLK_CNN domain**. CDC to `CLK_ADC` is the responsibility of the
instantiating level.

#### L1 CNN Trigger (`CNN_THRESH` / `CNN_TRIG`)

After each CNN inference completes, a registered comparator produces a hard binary decision:

```
score  =  signed(lane_score[15:0]) / 1024.0   (ap_fixed<16,6>)
CNN_TRIG  ←  '1'  if  signed(lane_score) > signed(CNN_THRESH),  else '0'
```

`CNN_THRESH` uses the same 16-bit ap_fixed\<16,6\> raw encoding as `CNN_OUT_DATA`:

| Desired threshold | `CNN_THRESH` value |
|-------------------|--------------------|
| 0.5               | `16'sd512`         |
| 0.0               | `16'sd0`           |
| 1.0               | `16'sd1024`        |
| −0.5              | `16'sd-512`        |

#### ADC_CHUNK_DISTRIBUTOR Internal State Machine

`ADC_CHUNK_DISTRIBUTOR` runs entirely in the `CLK_ADC` domain.

| State    | Action                                                                                                     |
|----------|------------------------------------------------------------------------------------------------------------|
| `FILL`   | On each `DATA_STR` pulse, pack the 16 incoming samples into a 64-bit word and write to `bram[wr_lane]` at address `batch_cnt`. Increment `batch_cnt`. |
| `COMMIT` | After 16 batches (`batch_cnt` wraps): set `chunk_ready[wr_lane]`. Advance `wr_lane` mod 6. Check next lane; if its `chunk_ready` is already set, assert `CHUNK_OVERFLOW`. Return to `FILL`. |

#### CNN_CORE_LANE Internal State Machine

Each `CNN_CORE_LANE` contains a True Dual-Port BRAM (256 × 64-bit), a CDC handshake pair, and
a streaming FSM in the `CLK_CNN` domain.

**CDC Handshake Protocol** (4-phase set/clear, identical to HiLoGatedCNNTrigger):

1. ADC side sets `chunk_ready` (CLK_ADC) after BRAM write completes.
2. `chunk_ready_cnn` is the 2-FF synchronized copy visible in CLK_CNN domain.
3. CNN side sets `chunk_ack` (CLK_CNN) after streaming + inference completes.
4. `chunk_ack_adc` (synchronized back to CLK_ADC) clears `chunk_ready`.

**CNN Stream FSM (CLK_CNN)**

| State          | Action                                                                                                  |
|----------------|---------------------------------------------------------------------------------------------------------|
| `CC_IDLE`      | Wait for `chunk_ready_cnn = '1'`. Assert `ap_start`. Move to `CC_STREAM`.                              |
| `CC_STREAM`    | Read BRAM sequentially, one word per cycle. Drive `input_data` + `input_valid` to WRAPPER_TOP. Hold `ap_start` until `ap_ready` rises. After 256 words, clear `input_valid`. Move to `CC_WAIT_DONE`. |
| `CC_WAIT_DONE` | Wait for `ap_done`. Latch `output_data` when `output_valid` rises. Move to `CC_ACK`.                   |
| `CC_ACK`       | Assert `lane_valid` + `lane_score` to top level. Set `chunk_ack`. Return to `CC_IDLE`.                 |

**ap_ctrl_hs protocol note**: `ap_start` must be held high until `ap_ready` rises. The first
word of input must be presented simultaneously with `ap_start`. Any bubble in the input stream
stalls the HLS datapath and will produce incorrect inference results.

**RST synchronizer**: `rst_s1` and `rst_cnn` are initialized to `'1'` so that `rst_n = '0'`
is driven to `cnn_core` before any `CLK_CNN` edge, matching the HLS reset expectation.

#### Async FIFO IP (`fifo_async_1024_to_64`)

Each `CNN_CORE_LANE` instantiates one Xilinx FIFO Generator IP.
Required configuration (Vivado IP Catalog → FIFO Generator 13.2):

| Tab          | Setting                   | Value                              |
|--------------|---------------------------|------------------------------------|
| Basic        | Fifo Implementation       | Independent Clocks Block RAM       |
| Basic        | Synchronization Stages    | 2                                  |
| Native Ports | Read Mode                 | **First Word Fall Through**        |
| Native Ports | Asymmetric Port Width     | Enabled                            |
| Native Ports | Write Width               | 1024                               |
| Native Ports | Write Depth               | 32  (Actual Write Depth ≈ 31)      |
| Native Ports | Read Width                | 128 (Actual Read Depth ≈ 248)      |
| Native Ports | Output Registers          | Off (FWFT uses embedded BRAM reg)  |
| Native Ports | Enable Safety Circuit     | **On** (prevents BRAM corruption)  |
| Status Flags | All flags                 | Off                                |
| Data Counts  | All counts                | Off                                |

The FSM streams all 256 CNN input words with **no bubbles** at 1 word/CLK\_CNN cycle.
Read latency is 0 in FWFT mode; `rd_en` asserted when consuming the lower half of each
128-bit entry causes the upper half to be valid in the same dout (unchanged), and the
next entry appears at dout exactly one CLK\_CNN cycle later.

#### BRAM Resource Budget

Per-lane FIFO (1024-bit write / 128-bit read, depth 32):

| Resource       | Per lane | Total (6 lanes) |
|----------------|----------|-----------------|
| BRAM_18K       | 1        | 6               |
| BRAM_36K       | 14       | 84              |

CNN core resources (from HLS synthesis, per lane):

| Resource  | Per core |
|-----------|----------|
| BRAM_18K  | 0        |
| DSP       | 11       |
| FF        | ~3000    |
| LUT       | ~26500   |

Total BRAM utilisation (6 FIFOs only): 84 BRAM\_36K / 240 available ≈ 35 %.

## Simulation

TBD — the simulation testbench (`HDL/sim/tb_ai_trigger_top.sv`) will:

1. Drive continuous ADC data (pre-recorded events from the `cnn-core` test dataset).
2. Verify round-robin lane assignment across all 6 cores.
3. Check that `CNN_TRIG` fires for signal events and not for thermal noise.
4. Verify `CHUNK_OVERFLOW` behavior when a lane is artificially held busy.
5. Confirm chunk-to-trigger latency budget (≤ 256 ns chunk period + ~1300 ns CNN inference).

## Known Limitations / Design Notes

1. **CHUNK_OVERFLOW**: If the ADC dispatcher reaches a lane whose BRAM is not yet drained,
   it asserts `CHUNK_OVERFLOW` (sticky). The current design drops the overflowing chunk.
   Under normal conditions this should not occur: each lane drains in ~1300 ns and receives
   a new chunk only every 1536 ns. Overflows indicate either a timing violation or that
   fewer than 6 lanes are functional.

2. **Data normalization**: The CNN was trained on data normalized to approximately
   `ADC_count / noise_σ` in ap_fixed\<12,6\> range. A pre-processing stage that divides raw
   ADC values by the per-channel noise σ and clamps to the fixed-point range must be inserted
   upstream of `ADC_DATA4`. This normalization is outside the scope of this module.

3. **No rate blanking**: Unlike a Hi-Lo gated design, the CNN runs on every chunk
   unconditionally. Downstream DAQ logic is responsible for handling the resulting trigger
   rate during noise bursts.

4. **CNN_TRIG pulse width**: 1 cycle at `CLK_CNN` = 5 ns at 200 MHz. Downstream logic
   must be able to capture a 5 ns pulse, or a pulse-stretcher should be added.

5. **Output ordering**: `CNN_OUT_DATA` reflects the most recently completed lane, not
   necessarily the oldest chunk. Chunks are processed in round-robin order but lane completion
   may vary slightly. For the binary trigger decision (`CNN_TRIG`), ordering is irrelevant.

## Bender

```bash
cargo install bender   # if not already installed
bender update          # fetch cnn-core-wrapper, cnn-core, gateware
```

Regenerate Vivado source scripts whenever dependencies change:

```bash
bender script vivado -t vivado > add_files.tcl
bender script vivado-sim -t sim > add_sim_files.tcl
```

The committed `add_files.tcl` hardcodes `ROOT` to the build machine path. Update the
`set ROOT` line to your local path before sourcing in Vivado, or regenerate with `bender script`.
