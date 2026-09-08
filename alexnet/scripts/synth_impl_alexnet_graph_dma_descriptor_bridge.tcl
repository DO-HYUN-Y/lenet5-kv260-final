source [file join [file dirname [info script]] shared_compute_sources.tcl]
set part xck26-sfvc784-2LV-c
set design_top alexnet_graph_dma_descriptor_bridge
set_param general.maxThreads 8
set out_dir [file join $alexnet_root build graph_dma_descriptor_bridge_ooc 200mhz]
set report_dir [file join $alexnet_root reports graph_dma_descriptor_bridge 200mhz]
file mkdir $out_dir
file mkdir $report_dir
cd $out_dir
foreach rtl_source $rtl_sources { read_verilog -sv $rtl_source }
set xdc_source [file join $alexnet_root constraints $design_top.xdc]
read_xdc $xdc_source
synth_design -top $design_top -part $part -mode out_of_context
set planner_cells [get_cells -hierarchical -filter \
    {ORIG_REF_NAME == alexnet_ddr_address_planner || \
     REF_NAME == alexnet_ddr_address_planner}]
if {[llength $planner_cells] != 1} { error "expected one DDR address planner" }
set dsp_cells [get_cells -hierarchical -filter {REF_NAME == DSP48E2}]
set bram_cells [get_cells -hierarchical -filter {REF_NAME == RAMB36E2}]
if {[llength $dsp_cells] != 0 || [llength $bram_cells] != 0} {
  error "DMA descriptor bridge must consume zero DSP and BRAM"
}
write_checkpoint -force [file join $out_dir post_synth.dcp]
report_utilization -file [file join $report_dir synth_utilization.rpt]
report_timing_summary -delay_type min_max -check_timing_verbose \
    -file [file join $report_dir synth_timing_summary.rpt]
opt_design
place_design
phys_opt_design
route_design
write_checkpoint -force [file join $out_dir post_route.dcp]
report_utilization -file [file join $report_dir impl_utilization.rpt]
report_timing_summary -delay_type min_max -check_timing_verbose -max_paths 20 \
    -file [file join $report_dir impl_timing_summary.rpt]
report_route_status -file [file join $report_dir route_status.rpt]
report_drc -file [file join $report_dir drc.rpt]
set f [open [file join $report_dir run_metadata.txt] w]
puts $f "design=$design_top"
puts $f "boundary=logical_graph_requests_to_axi_dma_simple_commands"
puts $f "frequency_mhz=200"
puts $f "clock_period_ns=5.000"
puts $f "part=$part"
puts $f "vivado=[version -short]"
puts $f "planner_instances=[llength $planner_cells]"
puts $f "synth_dsp48e2=[llength $dsp_cells]"
puts $f "synth_bram36e2=[llength $bram_cells]"
puts $f "physical_address_width=32"
puts $f "required_dma_dre_alignment_bytes=8"
puts $f "rtl_sha256.bridge=[lindex [exec sha256sum [file join $alexnet_root rtl integration alexnet_graph_dma_descriptor_bridge.sv]] 0]"
puts $f "rtl_sha256.planner=[lindex [exec sha256sum [file join $alexnet_root rtl control alexnet_ddr_address_planner.sv]] 0]"
puts $f "xdc_sha256=[lindex [exec sha256sum $xdc_source] 0]"
close $f
puts "ALEXNET_GRAPH_DMA_DESCRIPTOR_BRIDGE_OOC_DONE frequency_mhz=200"
