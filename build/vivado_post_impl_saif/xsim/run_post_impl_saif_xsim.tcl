run 2.0 us
open_saif {/home/work1/Works/AI-Trigger-System/build/vivado_post_impl_saif/activity/ai_trigger_post_impl.saif}
set saif_total_objects 0

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
        puts "[saif_stamp] SAIF first objects for $scope:"
        set preview_count 0
        foreach obj $objs {
            puts "    $obj"
            incr preview_count
            if {$preview_count >= 20} {
                break
            }
        }
        flush stdout
        puts "[saif_stamp] SAIF log_saif begin: $scope"
        flush stdout
        set t2 [clock seconds]
        log_saif $objs
        set t3 [clock seconds]
        puts "[saif_stamp] SAIF log_saif done: $scope elapsed=[expr {$t3 - $t2}]s"
        flush stdout
    }
}

proc saif_log_raw_all {} {
    global saif_total_objects
    set scope {/tb_AI_TRIGGER_TOP/dut/*}
    puts "[saif_stamp] SAIF fallback raw-all get_objects begin: $scope recursive=1"
    puts "[saif_stamp] This can be slow on a post-route netlist; waiting here means xsim is enumerating the full DUT."
    flush stdout
    set t0 [clock seconds]
    set objs [get_objects -r $scope]
    set n [llength $objs]
    incr saif_total_objects $n
    set t1 [clock seconds]
    puts "[saif_stamp] SAIF fallback raw-all get_objects done: count=$n elapsed=[expr {$t1 - $t0}]s"
    flush stdout
    if {$n > 0} {
        puts "[saif_stamp] SAIF fallback raw-all log_saif begin"
        flush stdout
        set t2 [clock seconds]
        log_saif $objs
        set t3 [clock seconds]
        puts "[saif_stamp] SAIF fallback raw-all log_saif done elapsed=[expr {$t3 - $t2}]s"
        flush stdout
    }
}

saif_log_scope {/tb_AI_TRIGGER_TOP/dut/*} 0
saif_log_scope {/tb_AI_TRIGGER_TOP/dut/u_DIST/*} 1
saif_log_scope {/tb_AI_TRIGGER_TOP/dut/gen_lanes\[0\].u_LANE/*} 1
saif_log_scope {/tb_AI_TRIGGER_TOP/dut/gen_lanes\[1\].u_LANE/*} 1
saif_log_scope {/tb_AI_TRIGGER_TOP/dut/gen_lanes\[2\].u_LANE/*} 1
saif_log_scope {/tb_AI_TRIGGER_TOP/dut/gen_lanes\[3\].u_LANE/*} 1
saif_log_scope {/tb_AI_TRIGGER_TOP/dut/gen_lanes\[4\].u_LANE/*} 1
saif_log_scope {/tb_AI_TRIGGER_TOP/dut/gen_lanes\[5\].u_LANE/*} 1
saif_log_scope {/tb_AI_TRIGGER_TOP/dut/gen_lanes\[6\].u_LANE/*} 1
puts "[saif_stamp] SAIF run all begin"
puts "[saif_stamp] SAIF total logged object count=$saif_total_objects"
if {$saif_total_objects < 1000 && 1} {
    puts "[saif_stamp] SAIF object count $saif_total_objects is below 1000; falling back to raw full-DUT recursion"
    flush stdout
    saif_log_raw_all
    puts "[saif_stamp] SAIF total logged object count after fallback=$saif_total_objects"
}
if {$saif_total_objects < 1000} {
    error "SAIF object count $saif_total_objects is below required minimum 1000; scope patterns likely matched too little hierarchy"
}
flush stdout
run all
puts "[saif_stamp] SAIF run all done"
flush stdout
close_saif
quit
