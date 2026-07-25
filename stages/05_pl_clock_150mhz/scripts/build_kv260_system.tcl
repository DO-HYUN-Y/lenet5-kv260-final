set_param general.maxThreads 16

if {[info exists ::lenet_stage_dir_override]} {
    set stage_dir [file normalize $::lenet_stage_dir_override]
} else {
    set stage_dir [file normalize [file join [file dirname [info script]] ..]]
}
set build_dir [file join $stage_dir build]
set project_dir [file join $build_dir vivado]
set report_dir [file join $build_dir reports]
set output_dir [file join $build_dir output]
file mkdir $report_dir
file mkdir $output_dir

open_project [file join $project_dir lenet5_kv260_system.xpr]

set_property strategy Flow_PerfOptimized_high [get_runs synth_1]
set_property strategy Performance_ExplorePostRoutePhysOpt [get_runs impl_1]

if {[get_property PROGRESS [get_runs synth_1]] ne "100%" ||
        [get_property NEEDS_REFRESH [get_runs synth_1]]} {
    reset_run synth_1
    launch_runs synth_1 -jobs 16
    wait_on_run synth_1
}
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {
    error "Synthesis did not complete: [get_property STATUS [get_runs synth_1]]"
}

open_run synth_1
report_utilization -hierarchical -file \
    [file join $report_dir post_synth_utilization.rpt]
report_timing_summary -delay_type min_max -check_timing_verbose \
    -report_unconstrained -file [file join $report_dir post_synth_timing.rpt]

if {[get_property PROGRESS [get_runs impl_1]] ne "100%" ||
        [get_property NEEDS_REFRESH [get_runs impl_1]]} {
    reset_run impl_1
    launch_runs impl_1 -to_step write_bitstream -jobs 16
    wait_on_run impl_1
}
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} {
    error "Implementation did not complete: [get_property STATUS [get_runs impl_1]]"
}

open_run impl_1
report_timing_summary -delay_type min_max -check_timing_verbose \
    -report_unconstrained -file [file join $report_dir timing_summary.rpt]
report_utilization -hierarchical -file \
    [file join $report_dir utilization_hierarchical.rpt]
report_utilization -file [file join $report_dir utilization.rpt]
report_route_status -file [file join $report_dir route_status.rpt]
report_drc -file [file join $report_dir drc.rpt]
report_methodology -file [file join $report_dir methodology.rpt]
report_cdc -details -file [file join $report_dir cdc.rpt]
check_timing -verbose -file [file join $report_dir check_timing.rpt]
report_power -file [file join $report_dir power.rpt]
report_clock_utilization -file \
    [file join $report_dir clock_utilization.rpt]

set setup_path [get_timing_paths -delay_type max -max_paths 1 -nworst 1]
set hold_path [get_timing_paths -delay_type min -max_paths 1 -nworst 1]
set setup_slack [get_property SLACK $setup_path]
set hold_slack [get_property SLACK $hold_path]
set wns [get_property STATS.WNS [get_runs impl_1]]
set tns [get_property STATS.TNS [get_runs impl_1]]
set whs [get_property STATS.WHS [get_runs impl_1]]
set ths [get_property STATS.THS [get_runs impl_1]]
set wpws [get_property STATS.WPWS [get_runs impl_1]]
set tpws [get_property STATS.TPWS [get_runs impl_1]]
if {$wpws eq ""} {
    set wpws REPORT_ONLY
}

set failed_route_nets [get_nets -hierarchical -filter {
    ROUTE_STATUS == "FAILED" ||
    ROUTE_STATUS == "UNROUTED" ||
    ROUTE_STATUS == "PARTIALLY_ROUTED"
}]
set drc_errors [get_drc_violations -filter {SEVERITY == "Error"}]
set drc_critical [get_drc_violations -filter {SEVERITY == "Critical Warning"}]

set bit_source [file join $project_dir \
    lenet5_kv260_system.runs impl_1 system_wrapper.bit]
if {![file exists $bit_source]} {
    error "Bitstream was not generated at $bit_source"
}
file copy -force $bit_source [file join $output_dir lenet5_kv260.bit]

write_hw_platform -fixed -include_bit -force \
    [file join $output_dir lenet5_kv260.xsa]

set summary_file [open [file join $report_dir build_summary.txt] w]
puts $summary_file "TOP=[get_property TOP [current_fileset]]"
puts $summary_file "PART=[get_property PART [current_project]]"
puts $summary_file "SYNTH_STATUS=[get_property STATUS [get_runs synth_1]]"
puts $summary_file "IMPL_STATUS=[get_property STATUS [get_runs impl_1]]"
puts $summary_file "WNS=$wns"
puts $summary_file "TNS=$tns"
puts $summary_file "WHS=$whs"
puts $summary_file "THS=$ths"
puts $summary_file "WPWS=$wpws"
puts $summary_file "TPWS=$tpws"
puts $summary_file "FAILED_ROUTE_NETS=[llength $failed_route_nets]"
puts $summary_file "DRC_ERRORS=[llength $drc_errors]"
puts $summary_file "DRC_CRITICAL_WARNINGS=[llength $drc_critical]"
puts $summary_file "BITSTREAM=[file join $output_dir lenet5_kv260.bit]"
puts $summary_file "XSA=[file join $output_dir lenet5_kv260.xsa]"
close $summary_file

if {$setup_slack < 0.0} {
    error "Setup timing failed with WNS=$setup_slack ns"
}
if {$hold_slack < 0.0} {
    error "Hold timing failed with WHS=$hold_slack ns"
}
foreach {metric value} [list \
        WNS $wns TNS $tns WHS $whs THS $ths TPWS $tpws] {
    if {$value eq "" || ![string is double -strict $value]} {
        error "Implementation timing metric $metric is missing: '$value'"
    }
    if {$value < 0.0} {
        error "Implementation timing failed with $metric=$value"
    }
}
if {[llength $failed_route_nets] != 0} {
    error "Routing failed for [llength $failed_route_nets] nets"
}
if {[llength $drc_errors] != 0 || [llength $drc_critical] != 0} {
    error "DRC failed: [llength $drc_errors] errors, \
[llength $drc_critical] critical warnings"
}

set timing_check [exec python3 \
    [file join $stage_dir scripts check_vivado_timing.py] \
    [file join $report_dir timing_summary.rpt]]
set timing_check_file [open \
    [file join $report_dir timing_check.txt] w]
puts $timing_check_file $timing_check
close $timing_check_file

set utilization_check [exec python3 \
    [file join $stage_dir scripts check_utilization.py] \
    [file join $report_dir utilization.rpt] \
    --lut-pct 70 --ff-pct 70 --bram-pct 80 \
    --uram-pct 80 --dsp-pct 80]
set utilization_check_file [open \
    [file join $report_dir utilization_check.txt] w]
puts $utilization_check_file $utilization_check
close $utilization_check_file

set report_check [exec python3 \
    [file join $stage_dir scripts check_vivado_reports.py] \
    --drc [file join $report_dir drc.rpt] \
    --methodology [file join $report_dir methodology.rpt] \
    --cdc [file join $report_dir cdc.rpt] \
    --route-status [file join $report_dir route_status.rpt]]
set report_check_file [open \
    [file join $report_dir report_check.txt] w]
puts $report_check_file $report_check
close $report_check_file

set check_timing_file [open \
    [file join $report_dir check_timing.rpt] r]
set check_timing_text [read $check_timing_file]
close $check_timing_file
foreach check_name {
    no_clock
    constant_clock
    unconstrained_internal_endpoints
    generated_clocks
    loops
    latch_loops
} {
    if {![string match "*checking $check_name (0)*" \
            $check_timing_text]} {
        error "check_timing failed for $check_name"
    }
}

close_project
exit
