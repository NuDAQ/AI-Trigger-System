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

# Model the AI trigger as an internal DAQ block rather than a package-level
# interface.  Zero-delay boundary constraints keep port paths visible without
# forcing board IO timing assumptions into this OOC run.
set adc_input_ports {}
set cnn_thresh_ports {}
foreach port [get_ports -quiet -filter {DIRECTION == IN}] {
    set name [get_property NAME $port]
    if {$name eq "CLK_ADC" || $name eq "CLK_CNN"} {
        continue
    } elseif {[string match "CNN_THRESH*" $name]} {
        lappend cnn_thresh_ports $port
    } else {
        lappend adc_input_ports $port
    }
}

if {[llength $adc_input_ports] > 0} {
    set_input_delay 0.000 -clock [get_clocks CLK_ADC] $adc_input_ports
}

if {[llength $cnn_thresh_ports] > 0} {
    set_input_delay 0.000 -clock [get_clocks CLK_CNN] $cnn_thresh_ports
}

set cnn_output_ports {}
set adc_output_ports {}
foreach port [get_ports -quiet -filter {DIRECTION == OUT}] {
    set name [get_property NAME $port]
    if {$name eq "CHUNK_OVERFLOW"} {
        lappend adc_output_ports $port
    } else {
        lappend cnn_output_ports $port
    }
}

if {[llength $cnn_output_ports] > 0} {
    set_output_delay 0.000 -clock [get_clocks CLK_CNN] $cnn_output_ports
}

if {[llength $adc_output_ports] > 0} {
    set_output_delay 0.000 -clock [get_clocks CLK_ADC] $adc_output_ports
}
