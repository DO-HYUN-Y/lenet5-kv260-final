source [file join [file dirname [info script]] shared_compute_sources.tcl]
set repo_root [file normalize [file join $alexnet_root ..]]
set part xck26-sfvc784-2LV-c
set design_top alexnet_m4n8_accelerator_top
set_param general.maxThreads 8
set out_dir [file join $alexnet_root build m4n8_accelerator_top_ooc 200mhz]
set report_dir [file join $alexnet_root reports m4n8_accelerator_top 200mhz]
file mkdir $out_dir
file mkdir $report_dir
cd $out_dir
foreach rtl_source $rtl_sources { read_verilog -sv $rtl_source }
set dma_master_source [file join $repo_root rtl axi_dma_simple_master.sv]
read_verilog -sv $dma_master_source
set xdc_source [file join $alexnet_root constraints $design_top.xdc]
read_xdc $xdc_source
synth_design -top $design_top -part $part -mode out_of_context

set control_cells [get_cells -hierarchical -filter \
    {ORIG_REF_NAME == alexnet_axi_lite_regs || \
     REF_NAME == alexnet_axi_lite_regs}]
set graph_dma_cells [get_cells -hierarchical -filter \
    {ORIG_REF_NAME == alexnet_m4n8_graph_dma_top || \
     REF_NAME == alexnet_m4n8_graph_dma_top}]
set sa_cells [get_cells -hierarchical -filter \
    {ORIG_REF_NAME == alexnet_sa_m4n8 || REF_NAME == alexnet_sa_m4n8}]
set dma_cells [get_cells -hierarchical -filter \
    {ORIG_REF_NAME == axi_dma_simple_master || REF_NAME == axi_dma_simple_master}]
set camera_cache_cells [get_cells -hierarchical -filter \
    {ORIG_REF_NAME == alexnet_camera_frame_replay || \
     REF_NAME == alexnet_camera_frame_replay}]
if {[llength $control_cells] != 1 || [llength $graph_dma_cells] != 1 ||
    [llength $sa_cells] != 1 || [llength $dma_cells] != 1 ||
    [llength $camera_cache_cells] != 1} {
  error "accelerator top hierarchy duplication or omission"
}
set dsp_cells [get_cells -hierarchical -filter {REF_NAME == DSP48E2}]
set bram_cells [get_cells -hierarchical -filter {REF_NAME == RAMB36E2}]
set uram_cells [get_cells -hierarchical -filter {REF_NAME == URAM288}]
if {[llength $dsp_cells] != 40} { error "expected exactly 40 DSP48E2" }
if {[llength $bram_cells] != 80} { error "expected exactly 80 RAMB36E2" }
if {[llength $uram_cells] != 13} { error "expected exactly 13 URAM288" }

write_checkpoint -force [file join $out_dir post_synth.dcp]
report_utilization -file [file join $report_dir synth_utilization.rpt]
report_utilization -hierarchical \
    -file [file join $report_dir synth_utilization_hierarchical.rpt]
report_timing_summary -delay_type min_max -check_timing_verbose \
    -file [file join $report_dir synth_timing_summary.rpt]
opt_design -directive ExploreWithRemap
place_design -directive ExtraTimingOpt
phys_opt_design -directive AggressiveExplore
route_design -directive AggressiveExplore
phys_opt_design -directive AggressiveExplore
route_design
set setup_path [get_timing_paths -delay_type max -max_paths 1 -nworst 1]
set hold_path [get_timing_paths -delay_type min -max_paths 1 -nworst 1]
set setup_wns [get_property SLACK $setup_path]
set hold_whs [get_property SLACK $hold_path]
set failed_route_nets [get_nets -hierarchical -filter {
    ROUTE_STATUS == "FAILED" ||
    ROUTE_STATUS == "UNROUTED" ||
    ROUTE_STATUS == "PARTIALLY_ROUTED"
}]
write_checkpoint -force [file join $out_dir post_route.dcp]
report_utilization -file [file join $report_dir impl_utilization.rpt]
report_utilization -hierarchical \
    -file [file join $report_dir impl_utilization_hierarchical.rpt]
report_timing_summary -delay_type min_max -check_timing_verbose -max_paths 20 \
    -file [file join $report_dir impl_timing_summary.rpt]
report_timing -delay_type max -max_paths 20 -sort_by group \
    -file [file join $report_dir worst_setup.rpt]
report_timing -delay_type min -max_paths 20 -sort_by group \
    -file [file join $report_dir worst_hold.rpt]
report_route_status -file [file join $report_dir route_status.rpt]
report_drc -file [file join $report_dir drc.rpt]

set f [open [file join $report_dir run_metadata.txt] w]
puts $f "design=$design_top"
puts $f "boundary=software_controlled_accelerator_ip_before_kv260_block_design"
puts $f "frequency_mhz=200"
puts $f "clock_period_ns=5.000"
puts $f "logical_shape=M8xN8"
puts $f "physical_shape=4x8"
puts $f "arithmetic_peak_tops=0.0256"
puts $f "part=$part"
puts $f "vivado=[version -short]"
puts $f "control_register_instances=[llength $control_cells]"
puts $f "graph_dma_top_instances=[llength $graph_dma_cells]"
puts $f "sa_m8n8_instances=[llength $sa_cells]"
puts $f "axi_dma_simple_master_instances=[llength $dma_cells]"
puts $f "camera_frame_replay_instances=[llength $camera_cache_cells]"
puts $f "synth_dsp48e2=[llength $dsp_cells]"
puts $f "synth_bram36e2=[llength $bram_cells]"
puts $f "synth_uram288=[llength $uram_cells]"
puts $f "wns_ns=$setup_wns"
puts $f "whs_ns=$hold_whs"
puts $f "failed_route_nets=[llength $failed_route_nets]"
puts $f "camera_frame_words=50176"
puts $f "camera_frame_replays=8"
puts $f "control_axi_data_width=32"
puts $f "control_axi_address_width=8"
puts $f "payload_axis_width=128"
puts $f "camera_axis_width=64"
puts $f "dma_alignment_bytes=8"
puts $f "board_block_design_connected=false"
puts $f "camera_preprocessing_connected=false"
foreach rtl_source $rtl_sources {
  puts $f "rtl_sha256.[file tail $rtl_source]=[lindex [exec sha256sum $rtl_source] 0]"
}
puts $f "rtl_sha256.axi_dma_simple_master=[lindex [exec sha256sum $dma_master_source] 0]"
puts $f "xdc_sha256=[lindex [exec sha256sum $xdc_source] 0]"
close $f
if {$setup_wns < 0.0 || $hold_whs < 0.0} {
  error "M8 accelerator top failed 200 MHz timing: WNS=$setup_wns WHS=$hold_whs"
}
if {[llength $failed_route_nets] != 0} {
  error "M8 accelerator top has [llength $failed_route_nets] failed route nets"
}
puts "ALEXNET_M8N8_ACCELERATOR_TOP_OOC_PASS frequency_mhz=200 DSP=[llength $dsp_cells] BRAM36=[llength $bram_cells] URAM=[llength $uram_cells] WNS=$setup_wns WHS=$hold_whs"
