# Parse Vivado's Design Timing Summary table instead of relying on run
# properties, which do not consistently expose pulse-width slack.

proc ai_trigger_timing_summary_metrics {timing_summary} {
    set found_summary 0
    set found_columns 0

    foreach line [split $timing_summary "\n"] {
        if {[string first "Design Timing Summary" $line] >= 0} {
            set found_summary 1
            continue
        }
        if {!$found_summary} {
            continue
        }
        if {[string first "WNS(ns)" $line] >= 0 &&
            [string first "WHS(ns)" $line] >= 0 &&
            [string first "WPWS(ns)" $line] >= 0} {
            set found_columns 1
            continue
        }
        if {!$found_columns} {
            continue
        }

        set values [regexp -all -inline {[-+]?[0-9]+[.]?[0-9]*} $line]
        if {[llength $values] == 12} {
            return [dict create \
                WNS [lindex $values 0] \
                WHS [lindex $values 4] \
                WPWS [lindex $values 8]]
        }
    }

    error "Design Timing Summary metrics are unavailable"
}

proc ai_trigger_require_timing {timing_summary} {
    set violations {}
    set metrics [ai_trigger_timing_summary_metrics $timing_summary]

    foreach metric {WNS WHS WPWS} {
        set value [dict get $metrics $metric]
        if {![string is double -strict $value]} {
            error "Timing metric $metric is unavailable: \"$value\""
        }
        if {$value < 0.0} {
            lappend violations "$metric=$value"
        }
    }

    if {[llength $violations] != 0} {
        error "Timing constraints are not met: [join $violations {, }]"
    }
}
