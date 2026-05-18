# Post-implementation gate-level simulation and SAIF power report flow.
#
# This script is intended to be launched by scripts/run_post_impl_saif.py.  It
# uses a routed checkpoint whose top is AI_TRIGGER_TOP_TB_WRAP, runs the existing
# SystemVerilog testbench against the routed netlist, writes SAIF activity, and
# feeds that activity back into report_power.

if {![info exists ::RUN_SAIF_REPO_ROOT]} {
    set ::RUN_SAIF_REPO_ROOT [file normalize [file join [file dirname [info script]] ..]]
}
if {![info exists ::RUN_SAIF_DCP]} {
    set ::RUN_SAIF_DCP [file join $::RUN_SAIF_REPO_ROOT build vivado_ooc_ai_trigger_wrap checkpoints post_route.dcp]
}
if {![info exists ::RUN_SAIF_OUT_DIR]} {
    set ::RUN_SAIF_OUT_DIR [file join $::RUN_SAIF_REPO_ROOT build vivado_post_impl_saif]
}
if {![info exists ::RUN_SAIF_TESTHEX_DIR]} {
    set ::RUN_SAIF_TESTHEX_DIR ""
}
if {![info exists ::RUN_SAIF_NUM_SAMPLES]} {
    set ::RUN_SAIF_NUM_SAMPLES 64
}
if {![info exists ::RUN_SAIF_SCORE_THRESHOLD]} {
    set ::RUN_SAIF_SCORE_THRESHOLD -6.0
}
if {![info exists ::RUN_SAIF_CNN_THRESH_RAW]} {
    set ::RUN_SAIF_CNN_THRESH_RAW -96
}
if {![info exists ::RUN_SAIF_SDF_MODE]} {
    set ::RUN_SAIF_SDF_MODE none
}

set repo_root [file normalize $::RUN_SAIF_REPO_ROOT]
set dcp       [file normalize $::RUN_SAIF_DCP]
set out_dir   [file normalize $::RUN_SAIF_OUT_DIR]
set net_dir   [file join $out_dir netlist]
set sim_dir   [file join $out_dir xsim]
set act_dir   [file join $out_dir activity]
set rpt_dir   [file join $out_dir reports]

file mkdir $net_dir
file mkdir $sim_dir
file mkdir $act_dir
file mkdir $rpt_dir

if {![file exists $dcp]} {
    error "Routed checkpoint not found: $dcp"
}

if {$::RUN_SAIF_TESTHEX_DIR eq ""} {
    set testhex_dir ""
} else {
    set testhex_dir [file normalize $::RUN_SAIF_TESTHEX_DIR]
}
if {$testhex_dir eq "" || ![file exists $testhex_dir]} {
    set candidates [glob -nocomplain -types d [file join $repo_root .bender git checkouts cnn-core-wrapper-* cnn_core_wrapper cnn_core_wrapper.sim sim_1 behav xsim testhex_stream]]
    if {[llength $candidates] == 0} {
        error "testhex_stream not found. Pass --testhex-dir to scripts/run_post_impl_saif.py."
    }
    set testhex_dir [file normalize [lindex $candidates 0]]
}

puts "INFO: repo_root   = $repo_root"
puts "INFO: dcp         = $dcp"
puts "INFO: out_dir     = $out_dir"
puts "INFO: testhex_dir = $testhex_dir"
puts "INFO: samples     = $::RUN_SAIF_NUM_SAMPLES"
puts "INFO: sdf_mode    = $::RUN_SAIF_SDF_MODE"

set netlist [file join $net_dir AI_TRIGGER_TOP_TB_WRAP_post_route.v]
set sdf     [file join $net_dir AI_TRIGGER_TOP_TB_WRAP_post_route.sdf]
set saif    [file join $act_dir ai_trigger_post_impl.saif]
set csv     [file join $sim_dir ai_trigger_post_impl_results.csv]
set run_tcl [file join $sim_dir run_post_impl_saif_xsim.tcl]

open_checkpoint $dcp
if {$::RUN_SAIF_SDF_MODE eq "none"} {
    write_verilog -force -mode funcsim $netlist
} else {
    write_verilog -force -mode timesim -sdf_anno true $netlist
    write_sdf -force $sdf
}
close_design

set fp [open $run_tcl w]
puts $fp "open_saif {$saif}"
puts $fp "log_saif \[get_objects -r /tb_AI_TRIGGER_TOP/dut/*\]"
puts $fp "run all"
puts $fp "close_saif"
puts $fp "quit"
close $fp

cd $sim_dir
set tb_sv [file join $repo_root HDL sim tb_ai_trigger_top.sv]
set glbl ""
if {[info exists ::env(XILINX_VIVADO)]} {
    set glbl [file join $::env(XILINX_VIVADO) data verilog src glbl.v]
}

xvlog -sv $tb_sv
xvlog $netlist
if {[file exists $glbl]} {
    xvlog $glbl
}

set sdf_args {}
if {$::RUN_SAIF_SDF_MODE eq "min"} {
    lappend sdf_args -sdfmin "/tb_AI_TRIGGER_TOP/dut=$sdf"
} elseif {$::RUN_SAIF_SDF_MODE eq "typ"} {
    lappend sdf_args -sdftyp "/tb_AI_TRIGGER_TOP/dut=$sdf"
} elseif {$::RUN_SAIF_SDF_MODE eq "max"} {
    lappend sdf_args -sdfmax "/tb_AI_TRIGGER_TOP/dut=$sdf"
} elseif {$::RUN_SAIF_SDF_MODE ne "none"} {
    error "Unsupported SDF mode '$::RUN_SAIF_SDF_MODE'. Use none, min, typ, or max."
}

set xelab_tops [list tb_AI_TRIGGER_TOP]
if {[file exists $glbl]} {
    lappend xelab_tops glbl
}

xelab -relax -debug typical -timescale 1ns/10ps \
    -L unisims_ver -L unimacro_ver -L secureip \
    {*}$sdf_args \
    {*}$xelab_tops \
    -s ai_trigger_post_impl_saif

xsim ai_trigger_post_impl_saif \
    -tclbatch $run_tcl \
    -testplusarg "TESTHEX_DIR=$testhex_dir" \
    -testplusarg "OUT_CSV=$csv" \
    -testplusarg "NUM_SAMPLES=$::RUN_SAIF_NUM_SAMPLES" \
    -testplusarg "SCORE_THRESHOLD=$::RUN_SAIF_SCORE_THRESHOLD" \
    -testplusarg "CNN_THRESH_RAW=$::RUN_SAIF_CNN_THRESH_RAW"

if {![file exists $saif]} {
    error "SAIF was not generated: $saif"
}

open_checkpoint $dcp
if {[catch {read_saif -input $saif -instance_name tb_AI_TRIGGER_TOP/dut} err]} {
    puts "WARNING: read_saif with testbench instance failed: $err"
    puts "WARNING: retrying read_saif without instance_name"
    read_saif -input $saif
}

report_power -file [file join $rpt_dir post_route_power_saif.rpt]
report_utilization -file [file join $rpt_dir post_route_utilization_for_saif.rpt]
report_timing_summary -file [file join $rpt_dir post_route_timing_summary_for_saif.rpt]

puts "INFO: SAIF complete"
puts "INFO: saif        = $saif"
puts "INFO: csv         = $csv"
puts "INFO: power rpt   = [file join $rpt_dir post_route_power_saif.rpt]"
