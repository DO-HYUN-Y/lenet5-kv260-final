source [file join [file dirname [info script]] shared_compute_sources.tcl]
set part xck26-sfvc784-2LV-c
set design_top alexnet_conv_fc_data_service
set_param general.maxThreads 8
set out_dir [file join $alexnet_root build conv_fc_data_service_ooc 200mhz]
set report_dir [file join $alexnet_root reports conv_fc_data_service 200mhz]
file mkdir $out_dir
file mkdir $report_dir
cd $out_dir
foreach rtl_source $rtl_sources { read_verilog -sv $rtl_source }
set xdc_source [file join $alexnet_root constraints $design_top.xdc]
read_xdc $xdc_source
synth_design -top $design_top -part $part -mode out_of_context
set pool_cells [get_cells -hierarchical -filter {ORIG_REF_NAME == alexnet_n8_maxpool3x3 || REF_NAME == alexnet_n8_maxpool3x3}]
if {[llength $pool_cells] != 1} { error "expected ONE reused max-pool engine" }
set store_cells [get_cells -hierarchical -filter {ORIG_REF_NAME == alexnet_pool5_n8_store || REF_NAME == alexnet_pool5_n8_store}]
if {[llength $store_cells] != 1} { error "expected ONE Pool5 cache" }
set flatten_cells [get_cells -hierarchical -filter {ORIG_REF_NAME == alexnet_pool5_fc6_flatten_reader || REF_NAME == alexnet_pool5_fc6_flatten_reader}]
if {[llength $flatten_cells] != 1} { error "expected ONE Pool5 flatten reader" }
set dsp_cells [get_cells -hierarchical -filter {REF_NAME == DSP48E2}]
if {[llength $dsp_cells] != 0} { error "data service must consume zero DSP48E2" }
set bram_cells [get_cells -hierarchical -filter {REF_NAME == RAMB36E2}]
if {[llength $bram_cells] != 3} {
  error "expected two Pool5 cache RAMB36E2 plus one max-pool RAMB36E2"
}
write_checkpoint -force [file join $out_dir post_synth.dcp]
report_utilization -file [file join $report_dir synth_utilization.rpt]
report_utilization -hierarchical -file [file join $report_dir synth_utilization_hierarchical.rpt]
report_timing_summary -delay_type min_max -check_timing_verbose -file [file join $report_dir synth_timing_summary.rpt]
opt_design
place_design
phys_opt_design
route_design
write_checkpoint -force [file join $out_dir post_route.dcp]
report_utilization -file [file join $report_dir impl_utilization.rpt]
report_utilization -hierarchical -file [file join $report_dir impl_utilization_hierarchical.rpt]
report_timing_summary -delay_type min_max -check_timing_verbose -max_paths 20 -file [file join $report_dir impl_timing_summary.rpt]
report_route_status -file [file join $report_dir route_status.rpt]
report_drc -file [file join $report_dir drc.rpt]
set f [open [file join $report_dir run_metadata.txt] w]
puts $f "design=$design_top"
puts $f "boundary=conv_pool_ddr_stream_pool5_cache_fc6_flatten_injection"
puts $f "frequency_mhz=200"
puts $f "clock_period_ns=5.000"
puts $f "part=$part"
puts $f "vivado=[version -short]"
puts $f "maxpool_instances=[llength $pool_cells]"
puts $f "pool5_cache_instances=[llength $store_cells]"
puts $f "flatten_reader_instances=[llength $flatten_cells]"
puts $f "synth_bram36e2=[llength $bram_cells]"
puts $f "synth_dsp48e2=[llength $dsp_cells]"
puts $f "pool5_cache_words=1152"
puts $f "pool5_cache_physical_rows=512"
puts $f "pool5_cache_row_bits=144"
puts $f "fc6_flatten_scalars=9216"
puts $f "axi_mm_ps_camera_connected=false"
foreach rtl_source $rtl_sources {
  puts $f "rtl_sha256.[file tail $rtl_source]=[lindex [exec sha256sum $rtl_source] 0]"
}
puts $f "xdc_sha256=[lindex [exec sha256sum $xdc_source] 0]"
close $f
puts "ALEXNET_CONV_FC_DATA_SERVICE_OOC_DONE frequency_mhz=200"
