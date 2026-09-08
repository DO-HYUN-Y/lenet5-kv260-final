set part xck26-sfvc784-2LV-c
set frequency_mhz 200
set_param general.maxThreads 8

set alexnet_root [file normalize [file join [file dirname [info script]] ..]]
set repo_root [file normalize [file join $alexnet_root ..]]
set pe_source [file join $alexnet_root rtl packed_mac alexnet_packed_pe.sv]
set sa_source [file join $alexnet_root rtl sa alexnet_sa_m4n8.sv]
set scanner_source [file join $alexnet_root rtl result alexnet_m4n8_result_scanner.sv]
set requant_source [file join $alexnet_root rtl postprocess alexnet_n8_requant.sv]
set router_source [file join $alexnet_root rtl result alexnet_n8_output_router.sv]
set output_slice_source [file join $alexnet_root rtl integration alexnet_m4n8_n8_output_slice.sv]
set top_source [file join $alexnet_root rtl integration alexnet_m4n8_base_datapath.sv]
set xdc_source [file join $alexnet_root constraints alexnet_m4n8_base_datapath.xdc]
set out_dir [file join $alexnet_root build m4n8_base_datapath_ooc 200mhz]
set report_dir [file join $alexnet_root reports m4n8_base_datapath 200mhz]
file mkdir $out_dir
file mkdir $report_dir
cd $out_dir

read_verilog -sv [list $pe_source $sa_source $scanner_source $requant_source \
    $router_source $output_slice_source $top_source]
read_xdc $xdc_source
synth_design -top alexnet_m4n8_base_datapath -part $part -mode out_of_context
write_checkpoint -force [file join $out_dir post_synth.dcp]
report_utilization -file [file join $report_dir synth_utilization.rpt]
report_utilization -hierarchical -file \
    [file join $report_dir synth_utilization_hierarchical.rpt]
report_timing_summary -delay_type min_max -check_timing_verbose \
    -file [file join $report_dir synth_timing_summary.rpt]
report_control_sets -verbose -file [file join $report_dir synth_control_sets.rpt]

opt_design
place_design
phys_opt_design
route_design
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
report_control_sets -verbose -file [file join $report_dir impl_control_sets.rpt]
report_drc -file [file join $report_dir drc.rpt]

set metadata_file [open [file join $report_dir run_metadata.txt] w]
puts $metadata_file "design=alexnet_m4n8_base_datapath"
puts $metadata_file "logical_shape=M4xN8"
puts $metadata_file "physical_shape=2x8_packed_pe"
puts $metadata_file "fifo_depth=64"
puts $metadata_file "integration=sa_scanner_requant_router"
puts $metadata_file "git_commit=[exec git -C $repo_root rev-parse HEAD]"
puts $metadata_file "vivado=[version -short]"
puts $metadata_file "part=$part"
puts $metadata_file "frequency_mhz=$frequency_mhz"
puts $metadata_file "clock_period_ns=5.000000"
puts $metadata_file "pe_rtl_sha256=[lindex [exec sha256sum $pe_source] 0]"
puts $metadata_file "sa_rtl_sha256=[lindex [exec sha256sum $sa_source] 0]"
puts $metadata_file "scanner_rtl_sha256=[lindex [exec sha256sum $scanner_source] 0]"
puts $metadata_file "requant_rtl_sha256=[lindex [exec sha256sum $requant_source] 0]"
puts $metadata_file "router_rtl_sha256=[lindex [exec sha256sum $router_source] 0]"
puts $metadata_file "output_slice_rtl_sha256=[lindex [exec sha256sum $output_slice_source] 0]"
puts $metadata_file "top_rtl_sha256=[lindex [exec sha256sum $top_source] 0]"
puts $metadata_file "xdc_sha256=[lindex [exec sha256sum $xdc_source] 0]"
close $metadata_file
puts "ALEXNET_M4N8_BASE_DATAPATH_OOC_DONE frequency_mhz=$frequency_mhz"
