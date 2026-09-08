source [file join [file dirname [info script]] shared_compute_sources.tcl]
set repo_root [file normalize [file join $alexnet_root ..]]
set part xck26-sfvc784-2LV-c
set design_top alexnet_m4n8_graph_dma_top
set_param general.maxThreads 8
set out_dir [file join $alexnet_root build m4n8_graph_dma_top_ooc 200mhz]
set report_dir [file join $alexnet_root reports m4n8_graph_dma_top 200mhz]
file mkdir $out_dir
file mkdir $report_dir
cd $out_dir
foreach rtl_source $rtl_sources { read_verilog -sv $rtl_source }
set dma_master_source [file join $repo_root rtl axi_dma_simple_master.sv]
read_verilog -sv $dma_master_source
set xdc_source [file join $alexnet_root constraints $design_top.xdc]
read_xdc $xdc_source
synth_design -top $design_top -part $part -mode out_of_context

set shared_cells [get_cells -hierarchical -filter \
    {ORIG_REF_NAME == alexnet_m4n8_shared_compute_top || \
     REF_NAME == alexnet_m4n8_shared_compute_top}]
set sa_cells [get_cells -hierarchical -filter \
    {ORIG_REF_NAME == alexnet_sa_m4n8 || REF_NAME == alexnet_sa_m4n8}]
set planner_cells [get_cells -hierarchical -filter \
    {ORIG_REF_NAME == alexnet_ddr_address_planner || \
     REF_NAME == alexnet_ddr_address_planner}]
set loader_cells [get_cells -hierarchical -filter \
    {ORIG_REF_NAME == alexnet_parameter_record_loader || \
     REF_NAME == alexnet_parameter_record_loader}]
set storage_cells [get_cells -hierarchical -filter \
    {ORIG_REF_NAME == alexnet_conv_storage_dma_scheduler || \
     REF_NAME == alexnet_conv_storage_dma_scheduler}]
set dma_cells [get_cells -hierarchical -filter \
    {ORIG_REF_NAME == axi_dma_simple_master || REF_NAME == axi_dma_simple_master}]
set camera_cache_cells [get_cells -hierarchical -filter \
    {ORIG_REF_NAME == alexnet_camera_frame_replay || \
     REF_NAME == alexnet_camera_frame_replay}]
if {[llength $shared_cells] != 1 || [llength $sa_cells] != 1 ||
    [llength $planner_cells] != 1 || [llength $loader_cells] != 1 ||
    [llength $storage_cells] != 1 || [llength $dma_cells] != 1 ||
    [llength $camera_cache_cells] != 1} {
  error "graph DMA top hierarchy duplication or omission"
}
set dsp_cells [get_cells -hierarchical -filter {REF_NAME == DSP48E2}]
set bram_cells [get_cells -hierarchical -filter {REF_NAME == RAMB36E2}]
set uram_cells [get_cells -hierarchical -filter {REF_NAME == URAM288}]
if {[llength $dsp_cells] != 24} { error "expected exactly 24 DSP48E2" }
if {[llength $bram_cells] != 45} { error "expected exactly 45 RAMB36E2" }
if {[llength $uram_cells] != 13} { error "expected exactly 13 URAM288" }

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
write_checkpoint -force [file join $out_dir post_route.dcp]
report_utilization -file [file join $report_dir impl_utilization.rpt]
report_utilization -hierarchical \
    -file [file join $report_dir impl_utilization_hierarchical.rpt]
report_timing_summary -delay_type min_max -check_timing_verbose -max_paths 20 \
    -file [file join $report_dir impl_timing_summary.rpt]
report_route_status -file [file join $report_dir route_status.rpt]
report_drc -file [file join $report_dir drc.rpt]

set f [open [file join $report_dir run_metadata.txt] w]
puts $f "design=$design_top"
puts $f "boundary=full_graph_post_pool_storage_to_axi_dma_csr_and_axis"
puts $f "frequency_mhz=200"
puts $f "clock_period_ns=5.000"
puts $f "part=$part"
puts $f "vivado=[version -short]"
puts $f "shared_compute_instances=[llength $shared_cells]"
puts $f "sa_m4n8_instances=[llength $sa_cells]"
puts $f "planner_instances=[llength $planner_cells]"
puts $f "parameter_loader_instances=[llength $loader_cells]"
puts $f "conv_storage_scheduler_instances=[llength $storage_cells]"
puts $f "axi_dma_simple_master_instances=[llength $dma_cells]"
puts $f "camera_frame_replay_instances=[llength $camera_cache_cells]"
puts $f "synth_dsp48e2=[llength $dsp_cells]"
puts $f "synth_bram36e2=[llength $bram_cells]"
puts $f "synth_uram288=[llength $uram_cells]"
puts $f "camera_frame_words=50176"
puts $f "camera_frame_replays=8"
puts $f "dma_alignment_bytes=8"
puts $f "axi_dma_mm2s_dre_required=true"
puts $f "axi_dma_s2mm_dre_required=true"
puts $f "camera_preprocessing_connected=false"
foreach rtl_source $rtl_sources {
  puts $f "rtl_sha256.[file tail $rtl_source]=[lindex [exec sha256sum $rtl_source] 0]"
}
puts $f "rtl_sha256.axi_dma_simple_master=[lindex [exec sha256sum $dma_master_source] 0]"
puts $f "xdc_sha256=[lindex [exec sha256sum $xdc_source] 0]"
close $f
puts "ALEXNET_M4N8_GRAPH_DMA_TOP_OOC_DONE frequency_mhz=200"
