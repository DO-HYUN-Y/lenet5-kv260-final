source [file join [file dirname [info script]] shared_compute_sources.tcl]
set part xck26-sfvc784-2LV-c
set design_top alexnet_m4n8_shared_compute_top
set_param general.maxThreads 8
set out_dir [file join $alexnet_root build m4n8_shared_compute_top_ooc 200mhz]
set report_dir [file join $alexnet_root reports m4n8_shared_compute_top 200mhz]
file mkdir $out_dir
file mkdir $report_dir
cd $out_dir
foreach rtl_source $rtl_sources { read_verilog -sv $rtl_source }
set xdc_source [file join $alexnet_root constraints $design_top.xdc]
read_xdc $xdc_source
synth_design -top $design_top -part $part -mode out_of_context
set sa_cells [get_cells -hierarchical -filter {ORIG_REF_NAME == alexnet_sa_m4n8 || REF_NAME == alexnet_sa_m4n8}]
if {[llength $sa_cells] != 1} { error "expected ONE shared SA, found: $sa_cells" }
set dsp_cells [get_cells -hierarchical -filter {REF_NAME == DSP48E2}]
if {[llength $dsp_cells] != 24} { error "expected 16 packed MAC + 8 requant DSPs" }
write_checkpoint -force [file join $out_dir post_synth.dcp]
report_utilization -file [file join $report_dir synth_utilization.rpt]
report_utilization -hierarchical -file [file join $report_dir synth_utilization_hierarchical.rpt]
report_timing_summary -delay_type min_max -check_timing_verbose -file [file join $report_dir synth_timing_summary.rpt]
opt_design
place_design
phys_opt_design
route_design
# The combined control cones are slightly larger than either prior wrapper.
# Run the same 200 MHz target through a post-route physical optimization pass.
phys_opt_design -directive AggressiveExplore
route_design
write_checkpoint -force [file join $out_dir post_route.dcp]
report_utilization -file [file join $report_dir impl_utilization.rpt]
report_utilization -hierarchical -file [file join $report_dir impl_utilization_hierarchical.rpt]
report_timing_summary -delay_type min_max -check_timing_verbose -max_paths 20 -file [file join $report_dir impl_timing_summary.rpt]
report_timing -delay_type max -max_paths 20 -sort_by group -file [file join $report_dir worst_setup.rpt]
report_timing -delay_type min -max_paths 20 -sort_by group -file [file join $report_dir worst_hold.rpt]
report_route_status -file [file join $report_dir route_status.rpt]
report_drc -file [file join $report_dir drc.rpt]
set f [open [file join $report_dir run_metadata.txt] w]
puts $f "design=$design_top"
puts $f "boundary=combined_conv_fc_logical_dma_services_not_board_top"
puts $f "frequency_mhz=200"
puts $f "clock_period_ns=5.000"
puts $f "part=$part"
puts $f "vivado=[version -short]"
puts $f "sa_instances=[llength $sa_cells]"
puts $f "synth_dsp48e2=[llength $dsp_cells]"
puts $f "partial_sum_depth_words=4096"
puts $f "conv1_direct_activation_stream_port=true"
puts $f "activation_and_weight_banks_shared=false"
puts $f "pe_rtl_changed=false"
puts $f "sa_rtl_changed=false"
puts $f "full_graph_sequencer=false"
puts $f "pool_and_flatten_connected=false"
puts $f "axi_mm_ps_camera_connected=false"
foreach rtl_source $rtl_sources {
  puts $f "rtl_sha256.[file tail $rtl_source]=[lindex [exec sha256sum $rtl_source] 0]"
}
puts $f "xdc_sha256=[lindex [exec sha256sum $xdc_source] 0]"
close $f
puts "ALEXNET_SHARED_COMPUTE_TOP_OOC_DONE frequency_mhz=200"
