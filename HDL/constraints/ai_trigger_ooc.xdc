# Out-of-context constraints for AI_TRIGGER_TOP.
#
# This block is intended to be synthesized and implemented as a DAQ subsystem
# block, not as the FPGA package top.  Do not add package pins or IO standards
# here.

create_clock -name ADC_SRC_CLK -period 16.000 [get_ports ADC_SRC_CLK]
create_clock -name CLK_ADC -period 14.286 [get_ports CLK_ADC]
create_clock -name CLK_CNN -period 5.000 [get_ports CLK_CNN]

set_clock_groups -asynchronous \
    -group [get_clocks ADC_SRC_CLK] \
    -group [get_clocks CLK_ADC] \
    -group [get_clocks CLK_CNN]

# Model the AI trigger as an internal DAQ block rather than a package-level
# interface.  Zero-delay boundary constraints keep port paths visible without
# forcing board IO timing assumptions into this OOC run.  Keep this file to
# plain XDC commands; Vivado ignores Tcl control flow such as foreach/if when
# constraints are processed during implementation.
set_input_delay 0.000 -clock [get_clocks ADC_SRC_CLK] [get_ports -quiet {ADC_SRC_VALID ADC_SRC_DATA4*}]
set_input_delay 0.000 -clock [get_clocks CLK_ADC] [get_ports -quiet {EVENT_READY}]
set_input_delay 0.000 -clock [get_clocks CLK_CNN] [get_ports -quiet {CNN_THRESH*}]
set_false_path -hold -from [get_ports -quiet {ADC_SRC_VALID ADC_SRC_DATA4*}]
set_false_path -hold -from [get_ports -quiet {EVENT_READY}]
set_false_path -hold -from [get_ports -quiet {CNN_THRESH*}]

set_output_delay 0.000 -clock [get_clocks ADC_SRC_CLK] [get_ports -quiet {ADC_SRC_READY ADC_INPUT_OVERFLOW_COUNT*}]
set_output_delay 0.000 -clock [get_clocks CLK_CNN] [get_ports -quiet {CNN_TRIG CNN_OUT_DATA* CNN_OUT_CHUNK_ID* CNN_OUT_VALID DROPPED_TRIGGER_COUNT*}]
set_output_delay 0.000 -clock [get_clocks CLK_ADC] [get_ports -quiet {EVENT_VALID EVENT_DATA* EVENT_LAST EVENT_CHUNK_ID* EVENT_TIMESTAMP* EVENT_SCORE* RING_MISS_COUNT* CHUNK_OVERFLOW}]

# RST is a reset/control input, not a sampled OOC data interface.  Timing it
# with zero input delay creates artificial hold checks into reset pins.
set_false_path -from [get_ports RST]
