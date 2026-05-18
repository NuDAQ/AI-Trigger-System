# =============================================================================
# run_sim.tcl  —  place in the repo root, source from Vivado Tcl Console:
#   cd /home/work1/Works/AI-Trigger-System
#   source run_sim.tcl
# =============================================================================

# 1. Configure xsim plusargs.
# Defaults match the interactive flow.  A batch wrapper may set any of these
# globals before sourcing this file:
#   RUN_SIM_TESTHEX_DIR, RUN_SIM_OUT_CSV, RUN_SIM_NUM_SAMPLES,
#   RUN_SIM_SCORE_THRESHOLD, RUN_SIM_CNN_THRESH_RAW
set xsim_more_options ""
foreach {var plusarg} {
    RUN_SIM_TESTHEX_DIR       TESTHEX_DIR
    RUN_SIM_OUT_CSV           OUT_CSV
    RUN_SIM_NUM_SAMPLES       NUM_SAMPLES
    RUN_SIM_SCORE_THRESHOLD   SCORE_THRESHOLD
    RUN_SIM_CNN_THRESH_RAW    CNN_THRESH_RAW
} {
    if {[info exists ::$var] && [set ::$var] ne ""} {
        append xsim_more_options " -testplusarg $plusarg=[set ::$var]"
    }
}

set_property xsim.simulate.xsim.more_options $xsim_more_options [get_filesets sim_1]
set_property xsim.simulate.runtime all [get_filesets sim_1]

# 2. Determine repo root from pwd (works when Vivado is opened from repo root)
if {[info exists ::RUN_SIM_REPO_ROOT] && $::RUN_SIM_REPO_ROOT ne ""} {
    set repo_root [file normalize $::RUN_SIM_REPO_ROOT]
    cd $repo_root
} else {
    set repo_root [pwd]
}
puts "INFO: repo_root = $repo_root"
puts "INFO: xsim more_options = $xsim_more_options"

# 3. Find testhex_stream — look in bender checkout first, then fall back
set bender_glob "$repo_root/.bender/git/checkouts/cnn-core-wrapper-*/cnn_core_wrapper/cnn_core_wrapper.sim/sim_1/behav/xsim/testhex_stream"
set testhex_candidates [glob -nocomplain $bender_glob]

if {[llength $testhex_candidates] > 0} {
    set testhex_src [lindex $testhex_candidates 0]
    puts "INFO: testhex_stream found at $testhex_src"
} else {
    # If bender hasn't been run yet the checkout won't exist.
    # Fall back: the testbench uses relative path "testhex_stream" from the
    # xsim working directory — create a symlink there manually after running:
    #   bender update
    puts "WARNING: testhex_stream not found. Run 'bender update' first."
    puts "         Continuing without symlink; simulation may fail to load hex files."
    set testhex_src ""
}

# 4. Build the xsim working-directory path (no backslash continuation)
set proj_dir [get_property DIRECTORY [current_project]]
set proj_name [current_project]
set xsim_dir [file normalize "$proj_dir/${proj_name}.sim/sim_1/behav/xsim"]
puts "INFO: xsim_dir = $xsim_dir"
file mkdir $xsim_dir

# 5. Create symlink testhex_stream -> source
if {$testhex_src ne ""} {
    set link_path [file join $xsim_dir testhex_stream]
    catch {file delete -force $link_path}
    if {[catch {exec ln -sfn $testhex_src $link_path} err]} {
        puts "WARNING: symlink failed ($err) — copying instead (slow)"
        file copy -force $testhex_src $link_path
    } else {
        puts "INFO: symlink created: $link_path -> $testhex_src"
    }
}

# 6. Launch simulation
puts "INFO: Launching behavioral simulation..."
launch_simulation -simset sim_1 -mode behavioral

puts ""
puts "INFO: Done. CSV results at: [file join $xsim_dir ai_trigger_results.csv]"
