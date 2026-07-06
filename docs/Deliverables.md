# AI Trigger System

## Introduction

This version of the system receives 8 channels of 1 Gsa/s data. After inference, it internally compares the CNN scores with the configured CNN threshold, retaining only events above the threshold and outputting them along with their timestamps in the same format. The goal is to significantly reduce data traffic. At the moment, you can take it as a black box.

There are three kinds of interfaces:  with upstream, with downstream, and with system (clk, monitoring...).

## Desired upstream data format

The system prefers upstream data with any configuration that `samples/clk = 1 Gsa/s` (for example, `16-sample * 16 bits * 8 channels / 3 beats` on average at `187.5 MHz clk` ), buffered in an `8-channel 16-bit-width Async FIFO`. 

**Therefore, I would like the upstream system to have an `8-channel, 16-bit-width Async FIFO` right before the AI Trigger System's interface, that pulls the `DATA_STR` signal high immediately when there are 16 or more samples in it.** Therefore, the AI Trigger System can read 16 samples per beat based on its clock.

**Therefore, I would like the upstream system to provide an async FIFO / gearbox right before the AI Trigger System interface.** On the AI Trigger read side, it should output packets of `8 channels * 16 consecutive samples per channel * 16 bits per sample`, and assert `DATA_STR`  immediately whenever a full packet is available. The AI Trigger System then consumes one 16-sample-per-channel packet per valid `CLK_ADC` beat.

For each sample point: 

```
[15:0] in ch0 = [15:0] in the AI Trigger = ch0 (in [15:4]) + 4'b0000 (in [3:0])
[15:0] in ch1 = [31:16] in the AI Trigger = ch1 + 4'b0000
[15:0] in ch2 = [47:32] in the AI Trigger = ch2 + 4'b0000
[15:0] in ch3 = [63:48] in the AI Trigger = ch3 + 4'b0000
...
[15:0] in ch7 = [127:112] in the AI Trigger = ch7 + 4'b0000
```

In other words, all that is needed is to place an **8-channel asynchronous FIFO** in front of this system. Each channel is **16 bits wide**, with the upper 12 bits representing the data and the lower 4 bits set to 0.

#### All interfaces with upstream systems: 

| Signal             | Direction | Function                                                     |
| ------------------ | --------- | ------------------------------------------------------------ |
| `CLK_ADC`          | in        | Around `70MHz`. No slower than `60 MHz`.                     |
| `DATA_STR`         | in        | The input batch is valid. When it's `1`, the Trigger System accepts the current `ADC_DATA`. |
| `ADC_DATA[1535:0]` | in        | One canonical ADC batch：8 channel x 16 sample/channel x 12 bit |

## Functions of the trigger system

Simply put, this involves reducing the data rate and retaining only the events of interest. The system takes **8 channels of 1 Gsa/s data as input**, processes it, and **outputs 8 channels of data at an extremely low rate.** This data is output in exactly the **same format**, along with a **timestamp**, and is **stored in an async FIFO** to await read by downstream systems.

#### All interfaces with the DAQ system for the purpose of control & configuration:

| Signal             | Direction | Function                                    |
| ------------------ | --------- | ------------------------------------------- |
| `CLK_CNN`          | in        | Around `200 MHz`. No slower than `184 MHz`. |
| `RST`              | in        | Reset for the whole Trigger System          |
| `CNN_THRESH[31:0]` | in        | Ttrigger threshold configuration.           |

For `CNN_THRESH[31:0]` , only `[21:0]` is useful. 

## Desired downstream data format

Simply put, this system aims to preserve the original data format while reducing the data volume and including a timestamp in the output.

In addition to maintaining the same format, each event will be chunked into 256 samples in length. Each chunk is assigned a timestamp. During a 16-beat period with a 256-chunk output, `EVENT_TIMESTAMP` remains unchanged.

At a clock speed of 70 MHz (`CLK_ADC`), 16 samples with 16-bit width are output per beat if data is allowed to pass through the trigger. The real data rate in the field will be very low-frequency, at about 1 Hz. 

Each event has a corresponding timestamp `EVENT_TIMESTAMP[23:0]`. 

All samples will be placed in an **8-channel asynchronous FIFO** with **16 bits wide**, waiting to be read by downstream processes.

#### All interfaces with downstream systems: 

| Signal                  | Direction | Function                                                     |
| ----------------------- | --------- | ------------------------------------------------------------ |
| `EVENT_VALID`           | out       | There is currently event data beat                           |
| `EVENT_READY`           | in        | DAQ tells the Trigger System that it can receive the current beat |
| `EVENT_DATA[1535:0]`    | out       | Original waveform batch, in the same format as `ADC_DATA`    |
| `EVENT_LAST`            | out       | This is the last beat of the current event                   |
| `EVENT_TIMESTAMP[23:0]` | out       | Event relative to timestamp                                  |

For DAQ: 
```
if EVENT_VALID && EVENT_READY:
    read EVENT_DATA
    read EVENT_TIMESTAMP
    if EVENT_LAST:
        event finished
```

During a 16-beat period with a 256-chunk output, `EVENT_TIMESTAMP` remains unchanged.





