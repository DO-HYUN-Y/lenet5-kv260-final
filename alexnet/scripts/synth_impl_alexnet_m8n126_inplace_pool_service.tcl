set part xck26-sfvc784-2LV-c
set frequency_mhz 200
set_param general.maxThreads 8

set alexnet_root [file normalize [file join [file dirname [info script]] ..]]
set repo_root [file normalize [file join $alexnet_root ..]]
set out_dir [file join $alexnet_root build \
    m8n126_inplace_pool_service_ooc 200mhz]
set report_dir [file join $alexnet_root reports \
    m8n126_inplace_pool_service 200mhz]
file mkdir $out_dir
file mkdir $report_dir
cd $out_dir

set rtl_sources [list \
    [file join $alexnet_root rtl dma alexnet_axis128_to_n8_unpacker.sv] \
    [file join $alexnet_root rtl dma alexnet_n8_to_axis128_packer.sv] \
    [file join $alexnet_root rtl pool alexnet_n8_maxpool3x3.sv] \
    [file join $alexnet_root rtl integration \
        alexnet_conv_result_pool_service.sv] \
    [file join $alexnet_root rtl integration \
        alexnet_m8n126_inplace_pool_service.sv]]
read_verilog -sv $rtl_sources
set xdc_source [file join $alexnet_root constraints \
    alexnet_m8n126_inplace_pool_service.xdc]
read_xdc $xdc_source
synth_design -top alexnet_m8n126_inplace_pool_service -part $part \
    -mode out_of_context

set synth_dsp [llength [get_cells -hierarchical -filter {REF_NAME == DSP48E2}]]
set synth_bram36 \
    [llength [get_cells -hierarchical -filter {REF_NAME == RAMB36E2}]]
set synth_bram18 \
    [llength [get_cells -hierarchical -filter {REF_NAME == RAMB18E2}]]
if {$synth_dsp != 0} {
  error "in-place pool service must consume zero DSP48E2, got $synth_dsp"
}

write_checkpoint -force [file join $out_dir post_synth.dcp]
report_utilization -file [file join $report_dir synth_utilization.rpt]
report_utilization -hierarchical \
    -file [file join $report_dir synth_utilization_hierarchical.rpt]
report_timing_summary -delay_type min_max -check_timing_verbose \
    -file [file join $report_dir synth_timing_summary.rpt]
opt_design
place_design
phys_opt_design
route_design

set setup_path [get_timing_paths -delay_type max -max_paths 1]
set hold_path [get_timing_paths -delay_type min -max_paths 1]
set setup_wns [get_property SLACK $setup_path]
set hold_whs [get_property SLACK $hold_path]
set route_failures [get_nets -hierarchical -filter {
    ROUTE_STATUS == "FAILED" || ROUTE_STATUS == "UNROUTED" ||
    ROUTE_STATUS == "PARTIALLY_ROUTED"
}]

write_checkpoint -force [file join $out_dir post_route.dcp]
report_utilization -file [file join $report_dir impl_utilization.rpt]
report_utilization -hierarchical \
    -file [file join $report_dir impl_utilization_hierarchical.rpt]
report_timing_summary -delay_type min_max -check_timing_verbose -max_paths 20 \
    -file [file join $report_dir impl_timing_summary.rpt]
report_route_status -file [file join $report_dir route_status.rpt]
report_drc -file [file join $report_dir drc.rpt]

set metadata_file [open [file join $report_dir run_metadata.txt] w]
puts $metadata_file "design=alexnet_m8n126_inplace_pool_service"
puts $metadata_file "boundary=one_n8_raw_tile_buffered_sequential_mm2s_pool_s2mm"
puts $metadata_file "frequency_mhz=$frequency_mhz"
puts $metadata_file "clock_period_ns=5.000000"
puts $metadata_file "part=$part"
puts $metadata_file "vivado=[version -short]"
puts $metadata_file "dsp48e2=$synth_dsp"
puts $metadata_file "ramb36e2=$synth_bram36"
puts $metadata_file "ramb18e2=$synth_bram18"
puts $metadata_file "max_raw_tile_bytes=24200"
puts $metadata_file "setup_wns_ns=$setup_wns"
puts $metadata_file "hold_whs_ns=$hold_whs"
puts $metadata_file "failed_route_nets=[llength $route_failures]"
foreach rtl_source $rtl_sources {
  puts $metadata_file \
      "rtl_sha256.[file tail $rtl_source]=[lindex [exec sha256sum $rtl_source] 0]"
}
puts $metadata_file \
    "xdc_sha256=[lindex [exec sha256sum $xdc_source] 0]"
close $metadata_file

if {$setup_wns < 0.0 || $hold_whs < 0.0 ||
    [llength $route_failures] != 0} {
  error "in-place pool service failed implementation: WNS=$setup_wns WHS=$hold_whs route_failures=[llength $route_failures]"
}
puts "ALEXNET_M8N126_INPLACE_POOL_SERVICE_OOC_PASS frequency_mhz=$frequency_mhz BRAM36=$synth_bram36 BRAM18=$synth_bram18 WNS=$setup_wns WHS=$hold_whs"
