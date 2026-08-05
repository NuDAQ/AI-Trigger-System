# AI Trigger System

## Introduction

This version receives 8 channels of 1 Gsa/s data and records one 256-sample,
eight-channel waveform for each accepted trigger. Channels 0-3 feed the
configured trigger algorithm; channels 0-7 are preserved in event output.
`TRIGGER_MODE[3:0]` selects Capture-All, External, AI, Hi-Lo, or Hi-Lo-gated AI
at runtime without changing the bitstream.

The delivered top-level interface has three groups:

- Upstream ADC input, synchronous to `CLK_ADC = 250 MHz`
- Downstream event output, synchronous to `CLK_ADC = 250 MHz`
- Clock/reset/configuration inputs: `CLK_CNN = 200 MHz`, `RST`, trigger mode,
  CNN threshold, and Hi-Lo configuration

## Upstream ADC Input Format

The upstream ADC-side logic is driven directly with a 250 MHz `CLK_ADC`. So, no additional source-clock CDC is required at the delivered top-level ADC input.

Each accepted input beat contains:

```text
8 channels x 4 samples/channel x 12 bits/sample = 384 bits
```

At 250 MHz, four samples per channel per beat sustains:

```text
250 MHz x 4 samples/beat = 1 Gsa/s/channel
```

The top-level packing convention is (more details below):

```text
ADC_DATA[(ch * 4 + sample) * 12 + 11 : (ch * 4 + sample) * 12]
  = raw 12-bit signed ADC sample for channel ch, sample index sample
```

The external interface uses clean 12-bit signed samples. It does not use a 16-bit sample container or low-bit zero padding.

### Upstream Interface

| Signal | Direction | Function |
| --- | --- | --- |
| `CLK_ADC` | in | 250 MHz frontend clock used for input and event output. Strictly synchronize with the upstream and downstream clocks. |
| `DATA_STR` | in | Input beat valid. When `1`, the trigger system accepts `ADC_DATA`. Continuous input may hold this high every `CLK_ADC` cycle. |
| `ADC_DATA[383:0]` | in | One ADC beat: 8 channels x 4 samples/channel x 12 bits/sample. |

There is no upstream `ADC_READY` backpressure signal. When `DATA_STR=1`, the trigger system must accept the beat synchronously. When `DATA_STR=0`, the system will wait for the next `1`, then continue assembling the portion used for inference.

For `ADC_DATA[383:0]`, specifically: 
```
> Bit ranges are written as [MSB:LSB]:

ADC_DATA[ 11:  0] = ch0 sample0
ADC_DATA[ 23: 12] = ch0 sample1
ADC_DATA[ 35: 24] = ch0 sample2
ADC_DATA[ 47: 36] = ch0 sample3

ADC_DATA[ 59: 48] = ch1 sample0
ADC_DATA[ 71: 60] = ch1 sample1
ADC_DATA[ 83: 72] = ch1 sample2
ADC_DATA[ 95: 84] = ch1 sample3

ADC_DATA[107: 96] = ch2 sample0
ADC_DATA[119:108] = ch2 sample1
ADC_DATA[131:120] = ch2 sample2
ADC_DATA[143:132] = ch2 sample3

ADC_DATA[155:144] = ch3 sample0
ADC_DATA[167:156] = ch3 sample1
ADC_DATA[179:168] = ch3 sample2
ADC_DATA[191:180] = ch3 sample3

ADC_DATA[203:192] = ch4 sample0
ADC_DATA[215:204] = ch4 sample1
ADC_DATA[227:216] = ch4 sample2
ADC_DATA[239:228] = ch4 sample3

ADC_DATA[251:240] = ch5 sample0
ADC_DATA[263:252] = ch5 sample1
ADC_DATA[275:264] = ch5 sample2
ADC_DATA[287:276] = ch5 sample3

ADC_DATA[299:288] = ch6 sample0
ADC_DATA[311:300] = ch6 sample1
ADC_DATA[323:312] = ch6 sample2
ADC_DATA[335:324] = ch6 sample3

ADC_DATA[347:336] = ch7 sample0
ADC_DATA[359:348] = ch7 sample1
ADC_DATA[371:360] = ch7 sample2
ADC_DATA[383:372] = ch7 sample3
```

## Trigger Function

The selected trigger mode is:

| `TRIGGER_MODE` | Function |
| --- | --- |
| `0000` | Capture every complete 256-sample chunk. |
| `0001` | Capture only on a rearmed `FORCE_TRIGGER` rising edge. |
| `0010` | Run continuous AI and capture when `score > CNN_THRESH`. |
| `0011` | Capture on a Hi-Lo decision. |
| `0100` | Use Hi-Lo to select a window, then use the shared CNN to accept or reject it. |

Reserved values fail closed. Mode changes are deferred until the current work
and downstream event FIFO drain; only the latest requested value is applied.
Event output always preserves all 8 raw ADC channels in the same 384-bit beat
format as the input.

After reset, the active mode is fail-closed (`1111`) until the first complete
ADC chunk boundary. That first arming chunk advances the ring and timestamp but
is not offered to a trigger engine.

Each event contains one 256-sample chunk, output over 64 beats. When samples from the same chunk are output to downstream systems at a rate of 4 samples per beat at 250 MHz, the timestamp remains unchanged to represent the relative time of that chunk. The time resolution is 256 ns/timestamp.

`EVENT_TIMESTAMP` and `EVENT_TRIGGER_OFFSET` identify the trigger-anchor beat.

## System and Control Interface

| Signal | Direction | Function |
| --- | --- | --- |
| `CLK_CNN` | in | CNN inference clock, target 200 MHz. It can vary slightly, but no less than 180 MHz. |
| `RST` | in | Active-high reset for the trigger system. |
| `TRIGGER_MODE[3:0]` | in | Coherent runtime mode request, synchronous to `CLK_ADC`. |
| `FORCE_TRIGGER` | in | Synchronous External-mode request; one low-to-high transition requests one event. |
| `CNN_THRESH[31:0]` | in | Trigger threshold configuration. Only bits `[21:0]` are interpreted as signed `ap_fixed<22,11>` raw threshold data. `CNN_THRESH[31:22]` is ignored. Also `[MSB:LSB]`. |
| `HL_THRESH[11:0]` | in | Non-negative Hi-Lo amplitude threshold, latched at safe Hi-Lo-mode entry. |
| `HILO_WINDOW[4:0]` | in | Hi-Lo bipolar window configuration. |
| `COINC_WINDOW[5:0]` | in | Hi-Lo coincidence window configuration. |
| `BIN_THR[3:0]` | in | Hi-Lo multiplicity threshold, valid from 1 through 4. |

For the AI bring-up described below, configure `TRIGGER_MODE=0010` and
`CNN_THRESH=2.0`. Specifically, give constant inputs:

```
use ieee.numeric_std.all;

CNN_THRESH <= std_logic_vector(to_signed(4096, 32));  -- 32'h00001000
TRIGGER_MODE <= "0010";
```

See below for more details. 

## Downstream Event Output Format

The event stream is a `CLK_ADC` ready/valid interface. It uses the same beat shape and packing as `ADC_DATA` above:

```text
ADC_DATA[ 11:  0] = ch0 sample0
ADC_DATA[ 23: 12] = ch0 sample1
...
ADC_DATA[371:360] = ch7 sample2
ADC_DATA[383:372] = ch7 sample3
```

Each event emits 64 `EVENT_VALID` beats. `EVENT_TIMESTAMP` is a chunk-index
timestamp, `EVENT_TRIGGER_OFFSET` is the trigger-anchor beat index within that
chunk, and both remain constant across the event. `EVENT_LAST` is asserted on
the final beat.

### Downstream Interface

| Signal | Direction | Function |
| --- | --- | --- |
| `EVENT_VALID` | out | Current event beat is valid. `0` is the normal idle state when no event data is available. |
| `EVENT_READY` | in | DAQ can accept the current event beat. This describes peak sink capability, not the normal average event rate. I think it should always be `1`. |
| `EVENT_DATA[383:0]` | out | Original waveform beat, in the same format as `ADC_DATA`. |
| `EVENT_LAST` | out | Last beat of the current event. |
| `EVENT_TIMESTAMP[23:0]` | out | Chunk-index timestamp, constant for all beats of one 256-sample event chunk. Wraps around every about 4.3 seconds. |
| `EVENT_TRIGGER_OFFSET[5:0]` | out | Trigger-anchor beat index `0..63` inside `EVENT_TIMESTAMP`. |
| `ACTIVE_TRIGGER_MODE[3:0]` | out | Mode currently admitting and interpreting work. |
| `MODE_SWITCH_PENDING` | out | Requested mode has not yet reached a safe application boundary. |
| `INVALID_TRIGGER_MODE` | out | Requested mode is reserved. |
| `HILO_BLANKING` | out | Hi-Lo rate protection is intentionally suppressing decisions. |
| `HILO_CONFIG_ERROR` | out | Latched Hi-Lo configuration is unsafe; Hi-Lo decisions fail closed. |
| `EVENT_LOSS` | out | Sticky indication that an otherwise relevant trigger/event was dropped. |

The delivered interface does not expose CNN score, internal chunk ID, or debug
counters.

DAQ-side sampling contract:

```text
if EVENT_VALID && EVENT_READY:
    read EVENT_DATA
    read EVENT_TIMESTAMP
    read EVENT_TRIGGER_OFFSET
    if EVENT_LAST:
        event finished
```

## How to test?

These are the scores for some typical inputs. By adjusting the threshold, you can allow certain waveforms to trigger. A trigger rate that is too high may cause overflow, so we use bipolar square pulses for testing.

| Purpose                               | CNN_THRESH[31:0] | Raw threshold | Float threshold | Notes                                                        |
| ------------------------------------- | ---------------- | ------------: | --------------: | ------------------------------------------------------------ |
| Guarantee all possible scores trigger | 32'hFFE00000     |      -2097152 |         -1024.0 | Lowest representable signed `ap_fixed<22,11> `threshold.     |
| Score for all-zero input              | 32'hFFFFEE53     |         -4525 |       -2.209473 | All-zero input measured score is raw -4524, float -2.208984. |

For testing purposes, please use bipolar square waves with intervals (the period) that are not integer multiples of 256 ns as the input waveform, and only use ch0. The pulse shape is: `5 ns +50 mV, 5 ns -50 mV`. In the simulation, the actual bits input I entered was
```
0000000000000100  x5   # ch0 = +0x100 = +256; ch1..ch3 = 0
0000000000000f00  x5   # ch0 = 0xf00 = signed -256; ch1..ch3 = 0
0000000000000000       # remaining samples are zero; full input ch1..ch7 are held at 0
```

However, I converted the values to mV based on the [ADC chip's datasheet](https://www.ti.com/lit/ds/symlink/adc12dj1600.pdf), page 58. If I'm wrong, it would be best to calculate the voltage corresponding to that 12-bit input, although the actual voltage may not make much difference, since this trigger is primarily based on the waveform shape.

Simply put, the input is: 

1. Connect the waveform generator only to `ch0`. 
2. Set the input of the other 7 channels to 0
3. Input a bipolar waveform shaped `5 ns +50 mV, 5 ns -50 mV` to ch0. Ensure that the interval between any two pulses is greater than 2 μs and is not an integer multiple of 256 ns. Therefore, we recommend using `3pps`. Approximately 14.2%, or a similar proportion, of the waveforms will be triggered and sent to the backend for recording.

*Note: Due to the limitations of the model we are currently using, when we set the CNN threshold to 2, only bipolar pulses with start times roughly between 54 ns and 88 ns within a 256 ns time window will be triggered. Therefore, it is expected that most of the recorded waveforms will be pulses whose start times fall within this time window:*

![score_vs_offset](/Users/albert/Library/Mobile Documents/com~apple~CloudDocs/Works/UC_Irvine_Group/AI-Trigger-System/docs/score_vs_offset.png)

*Since this trigger is not yet a mature version, bipolar pulses starting at different positions (The trigger processes each 256 ns as a chunk) will receive different scores. This is why you should use a period that isn't a multiple of 256; otherwise, there's a chance you'll never see the trigger.*
