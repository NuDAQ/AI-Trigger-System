# =============================================================================
# run_sim.tcl
#
# Server/batch usage from the repository root:
#   vivado -mode batch -source run_sim.tcl
#
# Optional overrides:
#   vivado -mode batch -source run_sim.tcl -tclargs \
#       -num_samples 64 \
#       -cnn_thresh_raw 0 \
#       -mirror_raw_channels 1 \
#       -out_csv ai_trigger_results.csv \
#       -event_csv ai_trigger_events.csv
#
# The script opens the committed Vivado project, refreshes simulation sources
# from Bender, links testhex_stream, and runs tb_AI_TRIGGER_TOP.
# =============================================================================

proc sim_arg_value {args name default} {
    set idx [lsearch -exact $args $name]
    if {$idx >= 0 && $idx + 1 < [llength $args]} {
        return [lindex $args [expr {$idx + 1}]]
    }
    return $default
}

proc sim_has_arg {args name} {
    expr {[lsearch -exact $args $name] >= 0}
}

proc assert_file_contains {path pattern} {
    set fp [open $path r]
    set text [read $fp]
    close $fp
    if {[string first $pattern $text] < 0} {
        error "Expected $path to contain '$pattern'. Check the current Bender graph."
    }
}

set repo_root [file normalize [pwd]]
set project_path [sim_arg_value $argv "-project" [file join $repo_root AI_Trigger_System AI_Trigger_System.xpr]]
set testhex_arg [sim_arg_value $argv "-testhex_dir" ""]
set out_csv_arg [sim_arg_value $argv "-out_csv" "ai_trigger_results.csv"]
set event_csv_arg [sim_arg_value $argv "-event_csv" "ai_trigger_events.csv"]
set num_samples_arg [sim_arg_value $argv "-num_samples" ""]
set score_threshold_arg [sim_arg_value $argv "-score_threshold" ""]
set cnn_thresh_raw_arg [sim_arg_value $argv "-cnn_thresh_raw" ""]
set mirror_raw_channels_arg [sim_arg_value $argv "-mirror_raw_channels" ""]

if {[info exists ::RUN_SIM_REPO_ROOT] && $::RUN_SIM_REPO_ROOT ne ""} {
    set repo_root [file normalize $::RUN_SIM_REPO_ROOT]
}
if {[info exists ::RUN_SIM_PROJECT] && $::RUN_SIM_PROJECT ne ""} {
    set project_path [file normalize $::RUN_SIM_PROJECT]
}

cd $repo_root
puts "INFO: repo_root = $repo_root"
puts "INFO: project_path = $project_path"

if {![file exists $project_path]} {
    error "Vivado project not found: $project_path"
}

# Ensure Bender checkouts exist on a fresh server checkout.
set wrapper_candidates [glob -nocomplain [file join $repo_root .bender git checkouts cnn-core-wrapper-*]]
set hilo_candidates [glob -nocomplain [file join $repo_root .bender git checkouts hilo-trigger-*]]
if {![file exists [file join $repo_root .bender]] ||
    [llength $wrapper_candidates] == 0 || [llength $hilo_candidates] == 0} {
    puts "INFO: Bender checkouts not found; running bender update..."
    if {[catch {exec bender update} err]} {
        error "bender update failed: $err"
    }
}

if {[catch {current_project} current_proj] || $current_proj eq ""} {
    puts "INFO: opening project..."
    open_project $project_path
}

set_param general.maxThreads 8

# Configure xsim plusargs. Tcl globals are kept for compatibility with
# scripts/run_vivado_sim.py.
set plusarg_values [dict create]
dict set plusarg_values TESTHEX_DIR $testhex_arg
dict set plusarg_values OUT_CSV $out_csv_arg
dict set plusarg_values EVENT_CSV $event_csv_arg
dict set plusarg_values NUM_SAMPLES $num_samples_arg
dict set plusarg_values SCORE_THRESHOLD $score_threshold_arg
dict set plusarg_values CNN_THRESH_RAW $cnn_thresh_raw_arg
dict set plusarg_values MIRROR_RAW_CHANNELS $mirror_raw_channels_arg

foreach {var plusarg} {
    RUN_SIM_TESTHEX_DIR       TESTHEX_DIR
    RUN_SIM_OUT_CSV           OUT_CSV
    RUN_SIM_EVENT_CSV         EVENT_CSV
    RUN_SIM_NUM_SAMPLES       NUM_SAMPLES
    RUN_SIM_SCORE_THRESHOLD   SCORE_THRESHOLD
    RUN_SIM_CNN_THRESH_RAW    CNN_THRESH_RAW
    RUN_SIM_MIRROR_RAW_CHANNELS MIRROR_RAW_CHANNELS
} {
    if {[info exists ::$var] && [set ::$var] ne ""} {
        dict set plusarg_values $plusarg [set ::$var]
    }
}

set xsim_more_options ""
dict for {plusarg value} $plusarg_values {
    if {$value ne ""} {
        append xsim_more_options " -testplusarg $plusarg=$value"
    }
}

set_property xsim.simulate.xsim.more_options $xsim_more_options [get_filesets sim_1]
set_property xsim.simulate.runtime all [get_filesets sim_1]
puts "INFO: xsim more_options = $xsim_more_options"

# The committed Vivado project may contain stale CNN-core source paths from an
# earlier local setup.  Keep generated IP files, but refresh Bender-managed
# sources from scratch to avoid duplicate and obsolete compile inputs.
puts "INFO: removing stale Bender-managed sources from project filesets..."
set stale_patterns [list \
    "$repo_root/HDL/rtl/*" \
    "$repo_root/HDL/sim/*" \
    "$repo_root/.bender/git/checkouts/cnn-core-wrapper-*/*" \
    "$repo_root/.bender/git/checkouts/hilo-trigger-*/*" \
    "/home/work1/Works/CNN-Core-Generator/*" \
]
foreach fs_name {sources_1 sim_1} {
    if {[catch {get_filesets $fs_name} fs_obj]} {
        continue
    }
    foreach file_obj [get_files -quiet -of_objects [get_filesets $fs_name]] {
        set file_path [file normalize [get_property NAME $file_obj]]
        foreach pattern $stale_patterns {
            if {[string match $pattern $file_path]} {
                catch {remove_files -fileset [get_filesets $fs_name] $file_obj}
                break
            }
        }
    }
}

# Refresh Vivado simulation sources from the current Bender lockfile.
set sim_gen_dir [file join $repo_root build vivado_sim generated]
file mkdir $sim_gen_dir
set bender_sim_script [file join $sim_gen_dir add_files_bender_sim.tcl]
puts "INFO: generating Vivado simulation source list with Bender..."
if {[catch {exec bender script vivado-sim -t simulation > $bender_sim_script} err]} {
    error "bender script vivado-sim failed: $err"
}
if {![file exists $bender_sim_script] || [file size $bender_sim_script] == 0} {
    error "Bender generated an empty Vivado simulation script."
}
assert_file_contains $bender_sim_script {HILO_TRIGGER_CTRL.vhd}
assert_file_contains $bender_sim_script {Pre_trigger.vhd}
puts "INFO: sourcing Bender simulation source list: $bender_sim_script"
source $bender_sim_script

foreach vhdl_file [get_files -quiet *.vhd] {
    catch {set_property file_type {VHDL 2008} $vhdl_file}
}

update_compile_order -fileset sources_1
update_compile_order -fileset sim_1

# Find testhex_stream. Explicit plusarg wins; otherwise use cnn-core-wrapper.
if {$testhex_arg ne ""} {
    set testhex_src [file normalize $testhex_arg]
} elseif {[info exists ::RUN_SIM_TESTHEX_DIR] && $::RUN_SIM_TESTHEX_DIR ne ""} {
    set testhex_src [file normalize $::RUN_SIM_TESTHEX_DIR]
} else {
    set bender_glob "$repo_root/.bender/git/checkouts/cnn-core-wrapper-*/cnn_core_wrapper/cnn_core_wrapper.sim/sim_1/behav/xsim/testhex_stream"
    set testhex_candidates [glob -nocomplain $bender_glob]
    if {[llength $testhex_candidates] > 0} {
        set testhex_src [lindex $testhex_candidates 0]
    } else {
        set testhex_src ""
    }
}

set proj_dir [get_property DIRECTORY [current_project]]
set proj_name [current_project]
set xsim_dir [file normalize "$proj_dir/${proj_name}.sim/sim_1/behav/xsim"]
file mkdir $xsim_dir
puts "INFO: xsim_dir = $xsim_dir"

if {$testhex_src ne "" && [file exists $testhex_src]} {
    puts "INFO: testhex_stream = $testhex_src"
    set link_path [file join $xsim_dir testhex_stream]
    catch {file delete -force $link_path}
    if {[catch {exec ln -sfn $testhex_src $link_path} err]} {
        puts "WARNING: symlink failed ($err); copying testhex_stream instead"
        file copy -force $testhex_src $link_path
    }
} else {
    puts "WARNING: testhex_stream not found. Pass -testhex_dir or run bender update."
}

catch {close_sim}
puts "INFO: launching behavioral simulation..."
launch_simulation -simset sim_1 -mode behavioral

puts ""
puts "INFO: Done."
puts "INFO: Score CSV: [file join $xsim_dir $out_csv_arg]"
puts "INFO: Event CSV: [file join $xsim_dir $event_csv_arg]"
