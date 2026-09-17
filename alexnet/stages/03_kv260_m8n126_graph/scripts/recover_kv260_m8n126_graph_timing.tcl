set_param general.maxThreads 8

set stage_dir [file normalize [file join [file dirname [info script]] ..]]
set build_dir [file join $stage_dir build]
set project_dir [file join $build_dir vivado]
set report_dir [file join $build_dir reports]
set output_dir [file join $build_dir output]
set recovery_dir [file join $build_dir recovery]
set routed_checkpoint [file join $project_dir alexnet_m4n8_kv260.runs \
    impl_1 system_wrapper_postroute_physopt.dcp]

if {![file exists $routed_checkpoint]} {
    error "No post-route checkpoint to recover: $routed_checkpoint"
}

file mkdir $report_dir
file mkdir $output_dir
file mkdir $recovery_dir
open_project [file join $project_dir alexnet_m4n8_kv260.xpr]
open_checkpoint $routed_checkpoint

set initial_path [get_timing_paths -delay_type max -max_paths 1 -nworst 1]
set initial_wns [get_property SLACK $initial_path]
puts "M8N126 graph timing recovery starts at WNS=$initial_wns ns"

phys_opt_design -directive AggressiveExplore
set post_phys_path [get_timing_paths -delay_type max -max_paths 1 -nworst 1]
set post_phys_wns [get_property SLACK $post_phys_path]
puts "M8N126 graph aggressive phys-opt WNS=$post_phys_wns ns"

if {$post_phys_wns < 0.0} {
    route_design -directive AggressiveExplore -tns_cleanup
    phys_opt_design -directive Explore
}

set setup_path [get_timing_paths -delay_type max -max_paths 1 -nworst 1]
set hold_path [get_timing_paths -delay_type min -max_paths 1 -nworst 1]
set setup_slack [get_property SLACK $setup_path]
set hold_slack [get_property SLACK $hold_path]
set failed_route_nets [get_nets -hierarchical -filter {
    ROUTE_STATUS == "FAILED" ||
    ROUTE_STATUS == "UNROUTED" ||
    ROUTE_STATUS == "PARTIALLY_ROUTED"
}]

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

set drc_errors [get_drc_violations -filter {SEVERITY == "Error"}]
set drc_critical [get_drc_violations \
    -filter {SEVERITY == "Critical Warning"}]
set dsp_cells [get_cells -hierarchical -filter {REF_NAME == DSP48E2}]
set sa_dsp_cells [get_cells -hierarchical -filter {
    REF_NAME == DSP48E2 && NAME =~ *u_dynamic_sa*
}]
set bram_cells [get_cells -hierarchical -filter {REF_NAME == RAMB36E2}]
set bram18_cells [get_cells -hierarchical -filter {REF_NAME == RAMB18E2}]
set uram_cells [get_cells -hierarchical -filter {REF_NAME == URAM288}]
set part_name [get_property PART [current_design]]

set summary_file [open [file join $report_dir build_summary.txt] w]
puts $summary_file "TOP=system_wrapper"
puts $summary_file "PART=$part_name"
puts $summary_file "SYNTH_STATUS=inherited from implemented checkpoint"
puts $summary_file "IMPL_STATUS=post-route timing recovery"
puts $summary_file "CLOCK_MHZ=200"
puts $summary_file "LOGICAL_ARRAY=M8xN126"
puts $summary_file "PHYSICAL_ARRAY=M8xN128"
puts $summary_file "INITIAL_WNS=$initial_wns"
puts $summary_file "POST_AGGRESSIVE_PHYSOPT_WNS=$post_phys_wns"
puts $summary_file "WNS=$setup_slack"
puts $summary_file "WHS=$hold_slack"
puts $summary_file "FAILED_ROUTE_NETS=[llength $failed_route_nets]"
puts $summary_file "DRC_ERRORS=[llength $drc_errors]"
puts $summary_file \
    "DRC_CRITICAL_WARNINGS=[llength $drc_critical]"
puts $summary_file "SA_DSP48E2=[llength $sa_dsp_cells]"
puts $summary_file "TOTAL_DSP48E2=[llength $dsp_cells]"
puts $summary_file "RAMB36E2=[llength $bram_cells]"
puts $summary_file "RAMB18E2=[llength $bram18_cells]"
puts $summary_file "URAM288=[llength $uram_cells]"
puts $summary_file "HP_PORTS_ENABLED=4"
puts $summary_file "HP_PORTS_ACTIVE=4"
puts $summary_file "HP3_WEIGHT_MM2S=1"
puts $summary_file "GRAPH_SCHEDULER_COMMANDS=1635"
puts $summary_file "GRAPH_USEFUL_MACS=714188480"
puts $summary_file \
    "BITSTREAM=[file join $output_dir alexnet_m8n126_graph_kv260.bit]"
puts $summary_file \
    "XSA=[file join $output_dir alexnet_m8n126_graph_kv260.xsa]"
close $summary_file

if {$setup_slack < 0.0 || $hold_slack < 0.0} {
    error "Recovered timing failed: WNS=$setup_slack WHS=$hold_slack"
}
if {[llength $failed_route_nets] != 0} {
    error "Recovered route has [llength $failed_route_nets] failed nets"
}
if {[llength $drc_errors] != 0 || [llength $drc_critical] != 0} {
    error "Recovered DRC failed: [llength $drc_errors] errors, [llength $drc_critical] critical warnings"
}
if {[llength $sa_dsp_cells] != 512 || [llength $dsp_cells] != 576 ||
    [llength $uram_cells] != 40} {
    error "Recovered resource contract failed"
}

write_checkpoint -force [file join $recovery_dir \
    alexnet_m8n126_graph_kv260_timing_clean.dcp]
write_bitstream -force \
    [file join $output_dir alexnet_m8n126_graph_kv260.bit]
write_hw_platform -fixed -include_bit -force \
    [file join $output_dir alexnet_m8n126_graph_kv260.xsa]

puts "ALEXNET_M8N126_GRAPH_KV260_TIMING_RECOVERY_DONE WNS=$setup_slack WHS=$hold_slack"
close_project
exit
