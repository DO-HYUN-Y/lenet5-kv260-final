set part xck26-sfvc784-2LV-c
set frequency_mhz 200
if {![info exists fc_controller_only]} { set fc_controller_only 0 }
set variant m4n8_fc_layer_datapath
if {$fc_controller_only} { set variant fc_layer_controller }
set design_top alexnet_$variant
set_param general.maxThreads 8

set alexnet_root [file normalize [file join [file dirname [info script]] ..]]
set repo_root [file normalize [file join $alexnet_root ..]]
set rtl_sources [list \
    [file join $alexnet_root rtl packed_mac alexnet_packed_pe.sv] \
    [file join $alexnet_root rtl sa alexnet_sa_m4n8.sv] \
    [file join $alexnet_root rtl result alexnet_m4n8_result_scanner.sv] \
    [file join $alexnet_root rtl memory \
        alexnet_n8_int32_partial_sum_bank.sv] \
    [file join $alexnet_root rtl postprocess alexnet_n8_requant.sv] \
    [file join $alexnet_root rtl result alexnet_n8_output_router.sv] \
    [file join $alexnet_root rtl integration \
        alexnet_m4n8_n8_accum_output_slice.sv] \
    [file join $alexnet_root rtl integration \
        alexnet_m4n8_accum_base_datapath.sv] \
    [file join $alexnet_root rtl feeder alexnet_n8_fc_m4_issuer.sv] \
    [file join $alexnet_root rtl memory alexnet_n8_weight_tile_bank.sv] \
    [file join $alexnet_root rtl memory alexnet_n8_activation_bank.sv] \
    [file join $alexnet_root rtl integration alexnet_m4n8_fc_resident_weight_accum_datapath.sv] \
    [file join $alexnet_root rtl dma alexnet_n8_dma_ingress.sv] \
    [file join $alexnet_root rtl dma alexnet_n8_dma_result_egress.sv] \
    [file join $alexnet_root rtl integration alexnet_m4n8_fc_activation_resident_weight_accum_datapath.sv] \
    [file join $alexnet_root rtl integration \
        alexnet_m4n8_fc_dma_io_datapath.sv] \
    [file join $alexnet_root rtl control alexnet_fc_layer_controller.sv] \
    [file join $alexnet_root rtl integration alexnet_m4n8_fc_layer_datapath.sv]]
if {$fc_controller_only} {
  set rtl_sources [list [file join $alexnet_root rtl control alexnet_fc_layer_controller.sv]]
}
set xdc_source [file join $alexnet_root constraints \
    $design_top.xdc]
set out_dir [file join $alexnet_root build \
    ${variant}_ooc 200mhz]
set report_dir [file join $alexnet_root reports \
    $variant 200mhz]
file mkdir $out_dir
file mkdir $report_dir
cd $out_dir

foreach rtl_source $rtl_sources {
  read_verilog -sv $rtl_source
}
read_xdc $xdc_source
synth_design -top $design_top -part $part -mode out_of_context
write_checkpoint -force [file join $out_dir post_synth.dcp]
report_utilization -file [file join $report_dir synth_utilization.rpt]
report_utilization -hierarchical -file \
    [file join $report_dir synth_utilization_hierarchical.rpt]
report_timing_summary -delay_type min_max -check_timing_verbose \
    -file [file join $report_dir synth_timing_summary.rpt]
report_control_sets -verbose -file \
    [file join $report_dir synth_control_sets.rpt]

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
report_control_sets -verbose -file \
    [file join $report_dir impl_control_sets.rpt]
report_drc -file [file join $report_dir drc.rpt]

set metadata_file [open [file join $report_dir run_metadata.txt] w]
puts $metadata_file "design=$design_top"
puts $metadata_file "controller_only=$fc_controller_only"
puts $metadata_file "fc_layers=6,7,8"
puts $metadata_file "geometry=9216x4096,4096x4096,4096x1000"
puts $metadata_file "schedule=n8_major_k_chunk_minor_max968"
puts $metadata_file "external_services=parameters,packed_mm2s,result_completion"
puts $metadata_file "ddr_addresses_generated=false"
if {$fc_controller_only} {
  puts $metadata_file "target_logical_shape=m4xn8"
  puts $metadata_file "sa_instances=0"
  puts $metadata_file "payload_banks_instantiated=0"
} else {
  puts $metadata_file "runtime_slice_index=1"
  puts $metadata_file "logical_shape=m4xn8"
  puts $metadata_file "physical_shape=2x8_packed_pe"
  puts $metadata_file "sa_instances=1"
  puts $metadata_file "activation_depth_words=512"
  puts $metadata_file "weight_depth_words=968"
  puts $metadata_file "partial_sum_depth_words=512"
}
puts $metadata_file "pe_rtl_changed=false"
puts $metadata_file "sa_rtl_changed=false"
puts $metadata_file "issuer_rtl_changed=false"
puts $metadata_file "git_commit=[exec git -C $repo_root rev-parse HEAD]"
puts $metadata_file "vivado=[version -short]"
puts $metadata_file "part=$part"
puts $metadata_file "frequency_mhz=$frequency_mhz"
puts $metadata_file "clock_period_ns=5.000000"
foreach rtl_source $rtl_sources {
  puts $metadata_file \
      "rtl_sha256.[file tail $rtl_source]=[lindex [exec sha256sum $rtl_source] 0]"
}
puts $metadata_file \
    "xdc_sha256=[lindex [exec sha256sum $xdc_source] 0]"
close $metadata_file
puts \
    "ALEXNET_FC_LAYER_OOC_DONE design=$design_top frequency_mhz=$frequency_mhz"
