# Production-top post-implementation simulation and SAIF power flow.

if {![info exists ::RUN_SAIF_REPO_ROOT]} {
    set ::RUN_SAIF_REPO_ROOT [file normalize [file join [file dirname [info script]] ..]]
}
if {![info exists ::RUN_SAIF_DCP]} {
    set ::RUN_SAIF_DCP [file join $::RUN_SAIF_REPO_ROOT build vivado_ooc_ai_trigger checkpoints post_route.dcp]
}
if {![info exists ::RUN_SAIF_OUT_DIR]} {
    set ::RUN_SAIF_OUT_DIR [file join $::RUN_SAIF_REPO_ROOT build vivado_post_impl_saif_30chunks]
}
if {![info exists ::RUN_SAIF_REFERENCE]} {
    set ::RUN_SAIF_REFERENCE [file join $::RUN_SAIF_REPO_ROOT build native_validation reference]
}
if {![info exists ::RUN_SAIF_CHUNKS]} {
    set ::RUN_SAIF_CHUNKS 30
}
if {![info exists ::RUN_SAIF_START_WINDOW]} {
    set ::RUN_SAIF_START_WINDOW 96
}
if {![info exists ::RUN_SAIF_CNN_THRESH_RAW]} {
    set ::RUN_SAIF_CNN_THRESH_RAW 0
}
if {![info exists ::RUN_SAIF_SDF_MODE]} {
    set ::RUN_SAIF_SDF_MODE none
}
if {![info exists ::RUN_SAIF_START_US]} {
    set ::RUN_SAIF_START_US 0.5
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

proc require_file {path description} {
    if {![file exists $path] || [file size $path] == 0} {
        error "$description not found or empty: $path"
    }
}

set repo_root [file normalize $::RUN_SAIF_REPO_ROOT]
set dcp       [file normalize $::RUN_SAIF_DCP]
set out_dir   [file normalize $::RUN_SAIF_OUT_DIR]
set reference [file normalize $::RUN_SAIF_REFERENCE]
set net_dir   [file join $out_dir netlist]
set sim_dir   [file join $out_dir xsim]
set act_dir   [file join $out_dir activity]
set rpt_dir   [file join $out_dir reports]

require_file $dcp "Routed checkpoint"
require_file [file join $reference adc.hex] "ADC reference"
require_file [file join $reference all_expected.hex] "Expected-score reference"

# Remove old products so a failed run cannot be mistaken for a fresh report.
file delete -force $net_dir $sim_dir $act_dir $rpt_dir
file mkdir $net_dir
file mkdir $sim_dir
file mkdir $act_dir
file mkdir $rpt_dir

puts "INFO: repo_root    = $repo_root"
puts "INFO: dcp          = $dcp"
puts "INFO: out_dir      = $out_dir"
puts "INFO: reference    = $reference"
puts "INFO: chunks       = $::RUN_SAIF_CHUNKS"
puts "INFO: start_window = $::RUN_SAIF_START_WINDOW"
puts "INFO: sdf_mode     = $::RUN_SAIF_SDF_MODE"
puts "INFO: saif_start   = $::RUN_SAIF_START_US us"

set netlist [file join $net_dir AI_TRIGGER_TOP_post_route.v]
set sdf     [file join $net_dir AI_TRIGGER_TOP_post_route.sdf]
set saif    [file join $act_dir ai_trigger_post_impl.saif]
set run_tcl [file join $sim_dir run_post_impl_saif_xsim.tcl]
set sim_log [file join $sim_dir xsim.log]

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
proc saif_log_scope {scope recursive} {
    global saif_total_objects
    if {$recursive} {
        set objects [get_objects -r $scope]
    } else {
        set objects [get_objects $scope]
    }
    set count [llength $objects]
    incr saif_total_objects $count
    puts "INFO: SAIF scope=$scope recursive=$recursive objects=$count"
    flush stdout
    if {$count > 0} {
        log_saif $objects
    }
}
}

# Cover every current production block without recursively enumerating the
# complete DUT in one very slow get_objects call.
puts $fp {saif_log_scope {/tb_ai_trigger_power/dut/*} 0}
puts $fp {saif_log_scope {/tb_ai_trigger_power/dut/u_CORE/*} 0}
puts $fp {saif_log_scope {/tb_ai_trigger_power/dut/u_CORE/u_RST_ADC/*} 1}
puts $fp {saif_log_scope {/tb_ai_trigger_power/dut/u_CORE/u_RST_CNN/*} 1}
puts $fp {saif_log_scope {/tb_ai_trigger_power/dut/u_CORE/u_LIVE_DISTRIBUTOR/*} 1}
puts $fp {saif_log_scope {/tb_ai_trigger_power/dut/u_CORE/gen_lanes\[0\].u_LANE/*} 1}
puts $fp {saif_log_scope {/tb_ai_trigger_power/dut/u_CORE/gen_lanes\[1\].u_LANE/*} 1}
puts $fp {saif_log_scope {/tb_ai_trigger_power/dut/u_CORE/u_RESULT_ARBITER/*} 1}
puts $fp {saif_log_scope {/tb_ai_trigger_power/dut/u_CORE/u_MULTIMODE_PATH/*} 1}
puts $fp "puts \"INFO: SAIF total objects=\$saif_total_objects\""
puts $fp "if {\$saif_total_objects < $::RUN_SAIF_MIN_OBJECTS} {"
puts $fp "    error \"SAIF object count \$saif_total_objects is below required minimum $::RUN_SAIF_MIN_OBJECTS\""
puts $fp "}"
puts $fp "run all"
puts $fp "close_saif"
puts $fp "quit"
close $fp

cd $sim_dir
set tb_sv [file join $repo_root HDL sim tb_ai_trigger_power.sv]
set glbl ""
if {[info exists ::env(XILINX_VIVADO)]} {
    set glbl [file join $::env(XILINX_VIVADO) data verilog src glbl.v]
}

run_external xvlog $netlist
run_external xvlog -sv $tb_sv
if {[file exists $glbl]} {
    run_external xvlog $glbl
}

set sdf_args {}
if {$::RUN_SAIF_SDF_MODE eq "min"} {
    lappend sdf_args -sdfmin "/tb_ai_trigger_power/dut=$sdf"
} elseif {$::RUN_SAIF_SDF_MODE eq "typ"} {
    lappend sdf_args -sdftyp "/tb_ai_trigger_power/dut=$sdf"
} elseif {$::RUN_SAIF_SDF_MODE eq "max"} {
    lappend sdf_args -sdfmax "/tb_ai_trigger_power/dut=$sdf"
} elseif {$::RUN_SAIF_SDF_MODE ne "none"} {
    error "Unsupported SDF mode '$::RUN_SAIF_SDF_MODE'"
}

set xelab_tops [list tb_ai_trigger_power]
if {[file exists $glbl]} {
    lappend xelab_tops glbl
}
run_external xelab -relax -debug typical -timescale 1ns/1ps \
    -L unisims_ver -L unimacro_ver -L secureip \
    {*}$sdf_args {*}$xelab_tops -s ai_trigger_post_impl_saif

set threshold_hex [format %08x [expr {$::RUN_SAIF_CNN_THRESH_RAW & 0xffffffff}]]
run_external xsim ai_trigger_post_impl_saif \
    -log $sim_log \
    -tclbatch $run_tcl \
    -testplusarg "REFERENCE=$reference" \
    -testplusarg "CHUNKS=$::RUN_SAIF_CHUNKS" \
    -testplusarg "START_WINDOW=$::RUN_SAIF_START_WINDOW" \
    -testplusarg "THRESHOLD=$threshold_hex"

require_file $sim_log "XSim log"
set log_fp [open $sim_log r]
set sim_transcript [read $log_fp]
close $log_fp
if {[string first "PASS production SAIF chunks=" $sim_transcript] < 0} {
    error "Production SAIF simulation did not print its completion marker"
}
require_file $saif "SAIF activity"

open_checkpoint $dcp
set saif_loaded 0
set read_attempts [list \
    [list read_saif -strip_path tb_ai_trigger_power/dut $saif] \
    [list read_saif -strip_path /tb_ai_trigger_power/dut $saif] \
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
    error "Failed to import production-top SAIF"
}

set power_report [file join $rpt_dir post_route_power_saif.rpt]
report_power -file $power_report
report_utilization -file [file join $rpt_dir post_route_utilization_for_saif.rpt]
report_timing_summary -file [file join $rpt_dir post_route_timing_summary_for_saif.rpt]
require_file $power_report "SAIF power report"

puts "INFO: SAIF complete"
puts "INFO: activity   = $saif"
puts "INFO: xsim log   = $sim_log"
puts "INFO: power rpt  = $power_report"
