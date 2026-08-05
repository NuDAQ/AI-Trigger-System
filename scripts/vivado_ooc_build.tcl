# Out-of-context synthesis / implementation flow for AI_TRIGGER_TOP.
#
# This script is intended to be launched by scripts/run_vivado_build.py.  It
# treats AI_TRIGGER_TOP as an internal DAQ subsystem block, not as the package
# top of the FPGA.

if {![info exists ::RUN_BUILD_REPO_ROOT]} {
    set ::RUN_BUILD_REPO_ROOT [file normalize [file join [file dirname [info script]] ..]]
}
if {![info exists ::RUN_BUILD_OUT_DIR]} {
    set ::RUN_BUILD_OUT_DIR [file join $::RUN_BUILD_REPO_ROOT build vivado_ooc_ai_trigger]
}
if {![info exists ::RUN_BUILD_PART]} {
    set ::RUN_BUILD_PART xcku5p-ffvb676-2-e
}
if {![info exists ::RUN_BUILD_TOP]} {
    set ::RUN_BUILD_TOP AI_TRIGGER_TOP
}
if {![info exists ::RUN_BUILD_IMPL]} {
    set ::RUN_BUILD_IMPL 1
}
if {![info exists ::RUN_BUILD_THREADS]} {
    set ::RUN_BUILD_THREADS 8
}

set repo_root [file normalize $::RUN_BUILD_REPO_ROOT]
set out_dir   [file normalize $::RUN_BUILD_OUT_DIR]
set rpt_dir   [file join $out_dir reports]
set dcp_dir   [file join $out_dir checkpoints]
set gen_dir   [file join $out_dir generated]

source [file join $repo_root scripts vivado_timing_gate.tcl]

file delete -force $rpt_dir $dcp_dir $gen_dir
file mkdir $out_dir
file mkdir $rpt_dir
file mkdir $dcp_dir
file mkdir $gen_dir

proc assert_file_contains {path pattern} {
    set fp [open $path r]
    set text [read $fp]
    close $fp
    if {[string first $pattern $text] < 0} {
        error "Expected $path to contain '$pattern'. Check that Bender ran on the current checkout."
    }
}

proc assert_daq_top_boundary {} {
    if {[llength [get_ports -quiet ADC_SRC_CLK]] > 0} {
        error "DAQ-facing OOC top must not expose ADC_SRC_CLK"
    }
    if {[llength [get_clocks -quiet ADC_SRC_CLK]] > 0} {
        error "DAQ-facing OOC constraints must not create ADC_SRC_CLK"
    }
    if {[llength [get_cells -quiet -hierarchical *u_ADC_INPUT*]] > 0} {
        error "DAQ-facing OOC top must not instantiate the source-clock input CDC"
    }
}

proc write_cdc_reports {summary_path details_path} {
    report_cdc -file $summary_path
    if {[catch {report_cdc -details -file $details_path} err]} {
        puts "WARNING: detailed CDC report failed: $err"
    }
}

proc write_text_file {path text} {
    set fp [open $path w]
    puts -nonewline $fp $text
    close $fp
}

set_param general.maxThreads $::RUN_BUILD_THREADS

puts "INFO: repo_root = $repo_root"
puts "INFO: out_dir   = $out_dir"
puts "INFO: part      = $::RUN_BUILD_PART"
puts "INFO: top       = $::RUN_BUILD_TOP"
puts "INFO: impl      = $::RUN_BUILD_IMPL"

cd $repo_root

if {![file exists [file join $repo_root Bender.yml]]} {
    error "Bender.yml not found at $repo_root"
}

set bender_script [file join $gen_dir add_files_bender.tcl]
puts "INFO: generating Vivado source list with Bender..."
if {[catch {exec bender script vivado -t vivado > $bender_script} err]} {
    error "bender script failed: $err"
}
if {![file exists $bender_script] || [file size $bender_script] == 0} {
    error "bender generated an empty Vivado script. Run 'bender update' and check dependency paths before launching Vivado."
}
assert_file_contains $bender_script {AI_TRIGGER_CORE.vhd}
assert_file_contains $bender_script {HILO_TRIGGER_CTRL.vhd}
assert_file_contains $bender_script {Pre_trigger.vhd}

create_project -in_memory -part $::RUN_BUILD_PART
set_property target_language VHDL [current_project]
set_property simulator_language Mixed [current_project]

puts "INFO: sourcing Bender-generated RTL file list..."
source $bender_script

# Bender imports wrapper-level board constraints from the dependency.  Those
# constraints describe a standalone wrapper project and are not valid for this
# DAQ subsystem OOC run.
set dep_xdcs [get_files -quiet -filter {FILE_TYPE == XDC}]
if {[llength $dep_xdcs] > 0} {
    puts "INFO: removing dependency XDC files from OOC run:"
    foreach xdc $dep_xdcs {
        puts "      $xdc"
    }
    remove_files $dep_xdcs
}

set ooc_xdc [file join $repo_root HDL constraints ai_trigger_ooc.xdc]
if {![file exists $ooc_xdc]} {
    error "OOC constraint file not found: $ooc_xdc"
}
add_files -fileset constrs_1 $ooc_xdc

set_property top $::RUN_BUILD_TOP [current_fileset]
update_compile_order -fileset sources_1

puts "INFO: running out-of-context synthesis..."
synth_design \
    -top $::RUN_BUILD_TOP \
    -part $::RUN_BUILD_PART \
    -mode out_of_context \
    -flatten_hierarchy none
assert_daq_top_boundary

# Keep the OOC implementation from trimming CNN internals across the block
# boundary.  Do not lock lane FIFOs here: their BRAM-heavy read-side paths are
# route-dominated at 200 MHz, so placement/physical optimization needs freedom.
set preserve_cells [get_cells -quiet -hierarchical -filter {
    NAME =~ *u_WRAPPER ||
    NAME =~ *cnn_core_inst
}]
if {[llength $preserve_cells] > 0} {
    puts "INFO: preserving [llength $preserve_cells] CNN hierarchy cells through implementation"
    set_property DONT_TOUCH true $preserve_cells
}

write_checkpoint -force [file join $dcp_dir post_synth.dcp]
report_utilization -file [file join $rpt_dir post_synth_utilization.rpt]
report_utilization -hierarchical -hierarchical_depth 6 -file [file join $rpt_dir post_synth_utilization_hier.rpt]
catch {report_methodology -file [file join $rpt_dir post_synth_methodology.rpt]}
report_timing_summary -file [file join $rpt_dir post_synth_timing_summary.rpt]
report_clock_interaction -file [file join $rpt_dir post_synth_clock_interaction.rpt]
write_cdc_reports \
    [file join $rpt_dir post_synth_cdc.rpt] \
    [file join $rpt_dir post_synth_cdc_details.rpt]

if {$::RUN_BUILD_IMPL} {
    puts "INFO: running OOC implementation..."
    opt_design
    write_checkpoint -force [file join $dcp_dir post_opt.dcp]
    report_utilization -hierarchical -hierarchical_depth 6 -file [file join $rpt_dir post_opt_utilization_hier.rpt]

    place_design
    write_checkpoint -force [file join $dcp_dir post_place.dcp]
    report_utilization -file [file join $rpt_dir post_place_utilization.rpt]
    report_utilization -hierarchical -hierarchical_depth 6 -file [file join $rpt_dir post_place_utilization_hier.rpt]
    report_timing_summary -file [file join $rpt_dir post_place_timing_summary.rpt]

    catch {phys_opt_design}
    route_design
    write_checkpoint -force [file join $dcp_dir post_route.dcp]
    assert_daq_top_boundary

    report_utilization -file [file join $rpt_dir post_route_utilization.rpt]
    report_utilization -hierarchical -hierarchical_depth 6 -file [file join $rpt_dir post_route_utilization_hier.rpt]
    catch {report_methodology -file [file join $rpt_dir post_route_methodology.rpt]}
    set post_route_timing_summary [report_timing_summary -return_string]
    write_text_file \
        [file join $rpt_dir post_route_timing_summary.rpt] \
        $post_route_timing_summary
    report_clock_interaction -file [file join $rpt_dir post_route_clock_interaction.rpt]
    write_cdc_reports \
        [file join $rpt_dir post_route_cdc.rpt] \
        [file join $rpt_dir post_route_cdc_details.rpt]
    report_route_status -file [file join $rpt_dir post_route_status.rpt]
    report_power -file [file join $rpt_dir post_route_power.rpt]
    ai_trigger_require_timing $post_route_timing_summary
}

puts "INFO: build complete"
puts "INFO: reports     = $rpt_dir"
puts "INFO: checkpoints = $dcp_dir"
