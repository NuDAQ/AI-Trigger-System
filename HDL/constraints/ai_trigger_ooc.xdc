# Out-of-context constraints for AI_TRIGGER_TOP.
#
# This block is intended to be synthesized and implemented as a DAQ subsystem
# block, not as the FPGA package top.  Do not add package pins or IO standards
# here.

create_clock -name CLK_ADC -period 16.000 [get_ports CLK_ADC]
create_clock -name CLK_CNN -period 5.714 [get_ports CLK_CNN]

set_clock_groups -asynchronous \
    -group [get_clocks CLK_ADC] \
    -group [get_clocks CLK_CNN]

# The CNN threshold is a static or slow-control value in the enclosing DAQ
# system.  It is excluded from this block-level timing run.
set cnn_thresh_ports [get_ports -quiet CNN_THRESH*]
if {[llength $cnn_thresh_ports] > 0} {
    set_false_path -from $cnn_thresh_ports
}

# Model the AI trigger as an internal DAQ block rather than a package-level
# interface.  Zero-delay boundary constraints keep port paths visible without
# forcing board IO timing assumptions into this OOC run.
set adc_input_ports [get_ports -quiet {DATA_STR RST ADC_DATA4*}]
if {[llength $adc_input_ports] > 0} {
    set_input_delay 0.000 -clock [get_clocks CLK_ADC] $adc_input_ports
}

set cnn_output_ports [get_ports -quiet {CNN_TRIG CNN_OUT_DATA* CNN_OUT_VALID}]
if {[llength $cnn_output_ports] > 0} {
    set_output_delay 0.000 -clock [get_clocks CLK_CNN] $cnn_output_ports
}

set adc_output_ports [get_ports -quiet CHUNK_OVERFLOW]
if {[llength $adc_output_ports] > 0} {
    set_output_delay 0.000 -clock [get_clocks CLK_ADC] $adc_output_ports
}
