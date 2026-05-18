# =============================================================================
# scripts/run_sim.tcl
# Run the AI_TRIGGER_TOP behavioral simulation.
#
# Usage (Vivado Tcl Console):
#   source scripts/run_sim.tcl
#
# What this script does:
#   1. Clears any bad xsim.more_options that would cause "-testplusarg" to
#      appear as an invalid Tcl command in the generated batch file.
#   2. Creates a symlink from the xsim working directory to the testhex_stream
#      data (auto-located from the Bender checkout).
#   3. Launches behavioral simulation.
#
# The testbench reads testhex_stream/ relative to the xsim working directory.
# Results are written to ai_trigger_results.csv in the same directory.
# =============================================================================

# ---------------------------------------------------------------------------
# 1. Clear problematic simulation properties
# ---------------------------------------------------------------------------
set_property xsim.simulate.xsim.more_options "" [get_filesets sim_1]
set_property xsim.simulate.runtime          all [get_filesets sim_1]
set_property xsim.simulate.log_all_signals  false [get_filesets sim_1]

# ---------------------------------------------------------------------------
# 2. Locate testhex_stream from the bender checkout
# ---------------------------------------------------------------------------
set repo_root [file normalize [file dirname [info script]]/..]

set testhex_candidates [glob -nocomplain \
    $repo_root/.bender/git/checkouts/cnn-core-wrapper-*/cnn_core_wrapper/\
cnn_core_wrapper.sim/sim_1/behav/xsim/testhex_stream]

if {[llength $testhex_candidates] == 0} {
    puts "WARNING: testhex_stream not found under .bender/. Trying bender update..."
    puts "         If bender is not run yet, run: bender update"
    puts "         Falling back to relative path 'testhex_stream'."
    set testhex_dir "testhex_stream"
} else {
    set testhex_dir [lindex $testhex_candidates 0]
    puts "INFO: Found testhex_stream: $testhex_dir"
}

# ---------------------------------------------------------------------------
# 3. Create symlink in the xsim working directory
# ---------------------------------------------------------------------------
set xsim_dir [file normalize \
    [get_property DIRECTORY [current_project]]/\
[current_project].sim/sim_1/behav/xsim]

file mkdir $xsim_dir

set link_target [file join $xsim_dir testhex_stream]
if {[file exists $link_target]} {
    file delete -force $link_target
}

# Tcl doesn't have a native symlink on all platforms; use exec ln -sfn
if {[catch {exec ln -sfn $testhex_dir $link_target} err]} {
    puts "WARNING: Could not create symlink ($err). Copying testhex_stream..."
    file copy -force $testhex_dir $link_target
}
puts "INFO: testhex_stream linked at $link_target"

# ---------------------------------------------------------------------------
# 4. Launch behavioral simulation
# ---------------------------------------------------------------------------
puts "INFO: Launching simulation..."
launch_simulation -simset sim_1 -mode behavioral

puts ""
puts "INFO: Simulation complete."
puts "INFO: Results written to: [file join $xsim_dir ai_trigger_results.csv]"
