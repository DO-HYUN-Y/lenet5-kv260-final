source [file join [file dirname [info script]] shared_compute_sources.tcl]
set part xck26-sfvc784-2LV-c
set design_top alexnet_m4n8_shared_compute_top
set_param general.maxThreads 8
set out_dir [file join $alexnet_root build m8n8_shared_compute_top_ooc 200mhz]
set report_dir [file join $alexnet_root reports m8n8_shared_compute_top 200mhz]
file mkdir $out_dir
file mkdir $report_dir
cd $out_dir
foreach rtl_source $rtl_sources { read_verilog -sv $rtl_source }
set xdc_source [file join $alexnet_root constraints alexnet_m4n8_shared_compute_top.xdc]
read_xdc $xdc_source
synth_design -top $design_top -part $part -mode out_of_context \
    -generic PHYS_ROWS=4

set sa_cells [get_cells -hierarchical -filter \
    {ORIG_REF_NAME == alexnet_sa_m4n8 || REF_NAME == alexnet_sa_m4n8}]
if {[llength $sa_cells] != 1} {
  error "expected ONE shared M8 SA, found: $sa_cells"
}
set dsp_cells [get_cells -hierarchical -filter {REF_NAME == DSP48E2}]
if {[llength $dsp_cells] != 40} {
  error "expected 32 packed MAC + 8 requant DSPs, got [llength $dsp_cells]"
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
report_route_status -file [file join $report_dir route_status.rpt]
report_drc -file [file join $report_dir drc.rpt]

set bram36_cells [get_cells -hierarchical -filter {REF_NAME == RAMB36E2}]
set f [open [file join $report_dir run_metadata.txt] w]
puts $f "design=$design_top"
puts $f "logical_shape=M8xN8"
puts $f "physical_shape=4x8"
puts $f "frequency_mhz=200"
puts $f "clock_period_ns=5.000"
puts $f "part=$part"
puts $f "vivado=[version -short]"
puts $f "sa_instances=[llength $sa_cells]"
puts $f "synth_dsp48e2=[llength $dsp_cells]"
puts $f "impl_ramb36e2=[llength $bram36_cells]"
puts $f "arithmetic_peak_tops=0.0256"
puts $f "wns_ns=$setup_wns"
puts $f "whs_ns=$hold_whs"
puts $f "partial_sum_depth_words=4096"
puts $f "conv_parallel_ring_read_copies=8"
foreach rtl_source $rtl_sources {
  puts $f "rtl_sha256.[file tail $rtl_source]=[lindex [exec sha256sum $rtl_source] 0]"
}
puts $f "xdc_sha256=[lindex [exec sha256sum $xdc_source] 0]"
close $f
if {$setup_wns < 0.0 || $hold_whs < 0.0} {
  error "M8 shared compute failed 200 MHz timing: WNS=$setup_wns WHS=$hold_whs"
}
puts "ALEXNET_M8N8_SHARED_COMPUTE_TOP_OOC_PASS dsp=[llength $dsp_cells] BRAM36=[llength $bram36_cells] WNS=$setup_wns WHS=$hold_whs"
