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
    set ::RUN_SAIF_NUM_SAMPLES 16
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
if {![info exists ::RUN_SAIF_START_US]} {
    set ::RUN_SAIF_START_US 2.0
}
if {![info exists ::RUN_SAIF_SCOPE]} {
    set ::RUN_SAIF_SCOPE all
}
if {![info exists ::RUN_SAIF_MIN_OBJECTS]} {
    set ::RUN_SAIF_MIN_OBJECTS 1000
}

proc run_external {args} {
    puts "INFO: running: [join $args { }]"
    if {[catch {exec {*}$args >@ stdout 2>@ stderr} err]} {
        error "Command failed: [join $args { }]\n$err"
    }
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
puts "INFO: saif_start  = $::RUN_SAIF_START_US us"
puts "INFO: saif_scope  = $::RUN_SAIF_SCOPE"
puts "INFO: min_objects = $::RUN_SAIF_MIN_OBJECTS"

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
if {$::RUN_SAIF_START_US > 0.0} {
    puts $fp "run $::RUN_SAIF_START_US us"
}
puts $fp "open_saif {$saif}"
puts $fp "set saif_total_objects 0"
puts $fp {
# SAIF coverage is controlled by the simulation object scopes below, not by
# Vivado timing constraints.  Each get_objects pattern selects xsim objects
# to record; the post-run read_saif step maps those activities back to the
# routed checkpoint for report_power.
proc saif_stamp {} {
    return [clock format [clock seconds] -format {%H:%M:%S}]
}

proc saif_log_scope {scope recursive} {
    global saif_total_objects
    puts "[saif_stamp] SAIF get_objects begin: $scope recursive=$recursive"
    flush stdout
    set t0 [clock seconds]
    if {$recursive} {
        set objs [get_objects -r $scope]
    } else {
        set objs [get_objects $scope]
    }
    set n [llength $objs]
    incr saif_total_objects $n
    set t1 [clock seconds]
    puts "[saif_stamp] SAIF get_objects done: $scope count=$n elapsed=[expr {$t1 - $t0}]s"
    flush stdout
    if {$n > 0} {
        puts "[saif_stamp] SAIF log_saif begin: $scope"
        flush stdout
        set t2 [clock seconds]
        log_saif $objs
        set t3 [clock seconds]
        puts "[saif_stamp] SAIF log_saif done: $scope elapsed=[expr {$t3 - $t2}]s"
        flush stdout
    }
}
}
if {$::RUN_SAIF_SCOPE eq "top"} {
    puts $fp {saif_log_scope {/tb_AI_TRIGGER_TOP/dut/*} 0}
} elseif {$::RUN_SAIF_SCOPE eq "lane0"} {
    puts $fp {saif_log_scope {/tb_AI_TRIGGER_TOP/dut/gen_lanes\[0\].u_LANE/*} 1}
} elseif {$::RUN_SAIF_SCOPE eq "lanes2"} {
    puts $fp {saif_log_scope {/tb_AI_TRIGGER_TOP/dut/*} 0}
    puts $fp {saif_log_scope {/tb_AI_TRIGGER_TOP/dut/u_DIST/*} 1}
    puts $fp {saif_log_scope {/tb_AI_TRIGGER_TOP/dut/gen_lanes\[0\].u_LANE/*} 1}
    puts $fp {saif_log_scope {/tb_AI_TRIGGER_TOP/dut/gen_lanes\[1\].u_LANE/*} 1}
} elseif {$::RUN_SAIF_SCOPE eq "lanes4"} {
    puts $fp {saif_log_scope {/tb_AI_TRIGGER_TOP/dut/*} 0}
    puts $fp {saif_log_scope {/tb_AI_TRIGGER_TOP/dut/u_DIST/*} 1}
    puts $fp {saif_log_scope {/tb_AI_TRIGGER_TOP/dut/gen_lanes\[0\].u_LANE/*} 1}
    puts $fp {saif_log_scope {/tb_AI_TRIGGER_TOP/dut/gen_lanes\[1\].u_LANE/*} 1}
    puts $fp {saif_log_scope {/tb_AI_TRIGGER_TOP/dut/gen_lanes\[2\].u_LANE/*} 1}
    puts $fp {saif_log_scope {/tb_AI_TRIGGER_TOP/dut/gen_lanes\[3\].u_LANE/*} 1}
} elseif {$::RUN_SAIF_SCOPE eq "all"} {
    puts $fp {saif_log_scope {/tb_AI_TRIGGER_TOP/dut/*} 0}
    puts $fp {saif_log_scope {/tb_AI_TRIGGER_TOP/dut/u_DIST/*} 1}
    puts $fp {saif_log_scope {/tb_AI_TRIGGER_TOP/dut/gen_lanes\[0\].u_LANE/*} 1}
    puts $fp {saif_log_scope {/tb_AI_TRIGGER_TOP/dut/gen_lanes\[1\].u_LANE/*} 1}
    puts $fp {saif_log_scope {/tb_AI_TRIGGER_TOP/dut/gen_lanes\[2\].u_LANE/*} 1}
    puts $fp {saif_log_scope {/tb_AI_TRIGGER_TOP/dut/gen_lanes\[3\].u_LANE/*} 1}
    puts $fp {saif_log_scope {/tb_AI_TRIGGER_TOP/dut/gen_lanes\[4\].u_LANE/*} 1}
    puts $fp {saif_log_scope {/tb_AI_TRIGGER_TOP/dut/gen_lanes\[5\].u_LANE/*} 1}
    puts $fp {saif_log_scope {/tb_AI_TRIGGER_TOP/dut/gen_lanes\[6\].u_LANE/*} 1}
} else {
    error "Unsupported SAIF scope '$::RUN_SAIF_SCOPE'. Use top, lane0, lanes2, lanes4, or all."
}
puts $fp {puts "[saif_stamp] SAIF run all begin"}
puts $fp "puts \"\[saif_stamp\] SAIF total logged object count=\$saif_total_objects\""
puts $fp "if {\$saif_total_objects < $::RUN_SAIF_MIN_OBJECTS} {"
puts $fp "    error \"SAIF object count \$saif_total_objects is below required minimum $::RUN_SAIF_MIN_OBJECTS; scope patterns likely matched too little hierarchy\""
puts $fp "}"
puts $fp {flush stdout}
puts $fp "run all"
puts $fp {puts "[saif_stamp] SAIF run all done"}
puts $fp {flush stdout}
puts $fp "close_saif"
puts $fp "quit"
close $fp

cd $sim_dir
set tb_sv [file join $repo_root HDL sim tb_ai_trigger_top.sv]
set glbl ""
if {[info exists ::env(XILINX_VIVADO)]} {
    set glbl [file join $::env(XILINX_VIVADO) data verilog src glbl.v]
}

run_external xvlog -sv $tb_sv
run_external xvlog $netlist
if {[file exists $glbl]} {
    run_external xvlog $glbl
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

run_external xelab -relax -debug typical -timescale 1ns/10ps \
    -L unisims_ver -L unimacro_ver -L secureip \
    {*}$sdf_args \
    {*}$xelab_tops \
    -s ai_trigger_post_impl_saif

run_external xsim ai_trigger_post_impl_saif \
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
set saif_loaded 0
set read_attempts [list \
    [list read_saif -strip_path tb_AI_TRIGGER_TOP/dut $saif] \
    [list read_saif -strip_path /tb_AI_TRIGGER_TOP/dut $saif] \
    [list read_saif $saif] \
]
foreach read_cmd $read_attempts {
    puts "INFO: trying SAIF import: [join $read_cmd { }]"
    if {[catch {uplevel #0 $read_cmd} err]} {
        puts "WARNING: SAIF import failed: $err"
    } else {
        set saif_loaded 1
        break
    }
}
if {!$saif_loaded} {
    error "Failed to import SAIF. Run 'read_saif -help' in Vivado for this installation's syntax."
}

report_power -file [file join $rpt_dir post_route_power_saif.rpt]
report_utilization -file [file join $rpt_dir post_route_utilization_for_saif.rpt]
report_timing_summary -file [file join $rpt_dir post_route_timing_summary_for_saif.rpt]

puts "INFO: SAIF complete"
puts "INFO: saif        = $saif"
puts "INFO: csv         = $csv"
puts "INFO: power rpt   = [file join $rpt_dir post_route_power_saif.rpt]"
