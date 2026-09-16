set part xck26-sfvc784-2LV-c
set frequency_mhz 200
set expected_total_dsps 576
set expected_sa_dsps 512
set_param general.maxThreads 8

set alexnet_root [file normalize [file join [file dirname [info script]] ..]]
set repo_root [file normalize [file join $alexnet_root ..]]
set out_dir [file join $alexnet_root build m8n128_tile_payload_ooc 200mhz]
set report_dir [file join $alexnet_root reports m8n128_tile_payload 200mhz]
file mkdir $out_dir
file mkdir $report_dir
cd $out_dir

set pe_source [file join $alexnet_root rtl packed_mac alexnet_packed_pe.sv]
set base_source [file join $alexnet_root rtl sa alexnet_sa_m4n8.sv]
set dynamic_source [file join $alexnet_root rtl sa alexnet_sa_m8n128_dynamic.sv]
set requant_source [file join $alexnet_root rtl postprocess alexnet_n8_requant.sv]
set parallel_source \
    [file join $alexnet_root rtl postprocess alexnet_m8n8_parallel_requant.sv]
set payload_source \
    [file join $alexnet_root rtl integration alexnet_m8n128_tile_payload.sv]
set xdc_source [file join $alexnet_root constraints alexnet_sa_m4n8.xdc]

read_verilog -sv $pe_source $base_source $dynamic_source $requant_source \
    $parallel_source $payload_source
read_xdc $xdc_source
synth_design -top alexnet_m8n128_tile_payload -part $part \
    -mode out_of_context -directive PerformanceOptimized

set dsp_cells [get_cells -hierarchical -filter {REF_NAME == DSP48E2}]
set sa_dsp_cells [get_cells -hierarchical -filter {
    REF_NAME == DSP48E2 && NAME =~ *u_dynamic_sa*
}]
if {[llength $dsp_cells] != $expected_total_dsps ||
    [llength $sa_dsp_cells] != $expected_sa_dsps} {
  error "M8N128 payload DSP contract failed: total=[llength $dsp_cells] SA=[llength $sa_dsp_cells]"
}

write_checkpoint -force [file join $out_dir post_synth.dcp]
report_utilization -file [file join $report_dir synth_utilization.rpt]
report_utilization -hierarchical -file \
    [file join $report_dir synth_utilization_hierarchical.rpt]
report_timing_summary -delay_type min_max -check_timing_verbose \
    -file [file join $report_dir synth_timing_summary.rpt]

opt_design -directive ExploreWithRemap
place_design -directive ExtraTimingOpt
phys_opt_design -directive AggressiveExplore
route_design -directive AggressiveExplore
phys_opt_design -directive AggressiveExplore
route_design

set setup_path [get_timing_paths -delay_type max -max_paths 1]
set hold_path [get_timing_paths -delay_type min -max_paths 1]
set setup_wns [get_property SLACK $setup_path]
set hold_whs [get_property SLACK $hold_path]

write_checkpoint -force [file join $out_dir post_route.dcp]
report_utilization -file [file join $report_dir impl_utilization.rpt]
report_utilization -hierarchical -file \
    [file join $report_dir impl_utilization_hierarchical.rpt]
report_timing_summary -delay_type min_max -check_timing_verbose -max_paths 20 \
    -file [file join $report_dir impl_timing_summary.rpt]
report_timing -delay_type max -max_paths 20 -sort_by group \
    -file [file join $report_dir worst_setup.rpt]
report_timing -delay_type min -max_paths 20 -sort_by group \
    -file [file join $report_dir worst_hold.rpt]
report_high_fanout_nets -fanout_greater_than 16 -max_nets 100 \
    -file [file join $report_dir high_fanout.rpt]
report_route_status -file [file join $report_dir route_status.rpt]
report_drc -file [file join $report_dir drc.rpt]

set failed_nets [llength [get_nets -hierarchical -filter {ROUTE_STATUS == CONFLICTS}]]
set unrouted_nets [llength [get_nets -hierarchical -filter {ROUTE_STATUS == UNROUTED}]]
set drc_errors [llength [get_drc_violations -filter {SEVERITY == Error}]]

set metadata_file [open [file join $report_dir run_metadata.txt] w]
puts $metadata_file "design=alexnet_m8n128_tile_payload"
puts $metadata_file "boundary=descriptor_to_int8_results"
puts $metadata_file "physical_banks=8xM8xN16"
puts $metadata_file "total_dsp48e2=[llength $dsp_cells]"
puts $metadata_file "sa_dsp48e2=[llength $sa_dsp_cells]"
puts $metadata_file "requant_dsp48e2=[expr {[llength $dsp_cells] - [llength $sa_dsp_cells]}]"
puts $metadata_file "frequency_mhz=$frequency_mhz"
puts $metadata_file "clock_period_ns=5.000000"
puts $metadata_file "wns_ns=$setup_wns"
puts $metadata_file "whs_ns=$hold_whs"
puts $metadata_file "failed_route_nets=$failed_nets"
puts $metadata_file "unrouted_nets=$unrouted_nets"
puts $metadata_file "drc_errors=$drc_errors"
puts $metadata_file "vivado=[version -short]"
puts $metadata_file "part=$part"
puts $metadata_file "git_commit=[exec git -C $repo_root rev-parse HEAD]"
puts $metadata_file "payload_rtl_sha256=[lindex [exec sha256sum $payload_source] 0]"
close $metadata_file

if {$setup_wns < 0.0 || $hold_whs < 0.0 || $failed_nets != 0 ||
    $unrouted_nets != 0 || $drc_errors != 0} {
  error "M8N128 payload implementation failed: WNS=$setup_wns WHS=$hold_whs failed=$failed_nets unrouted=$unrouted_nets DRC=$drc_errors"
}

puts "ALEXNET_M8N128_TILE_PAYLOAD_OOC_PASS DSP=[llength $dsp_cells] WNS=$setup_wns WHS=$hold_whs"
