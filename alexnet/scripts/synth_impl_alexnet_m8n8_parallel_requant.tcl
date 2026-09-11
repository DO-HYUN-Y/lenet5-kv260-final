set part xck26-sfvc784-2LV-c
set frequency_mhz 200
set_param general.maxThreads 8

set alexnet_root [file normalize [file join [file dirname [info script]] ..]]
set repo_root [file normalize [file join $alexnet_root ..]]
set scalar_rtl [file join $alexnet_root rtl postprocess alexnet_n8_requant.sv]
set parallel_rtl \
    [file join $alexnet_root rtl postprocess alexnet_m8n8_parallel_requant.sv]
set xdc_source [file join $alexnet_root constraints alexnet_n8_requant.xdc]
set out_dir [file join $alexnet_root build m8n8_parallel_requant_ooc 200mhz]
set report_dir [file join $alexnet_root reports m8n8_parallel_requant 200mhz]
file mkdir $out_dir
file mkdir $report_dir
cd $out_dir

read_verilog -sv $scalar_rtl $parallel_rtl
read_xdc $xdc_source
synth_design -top alexnet_m8n8_parallel_requant -part $part \
    -mode out_of_context

set dsp_cells [get_cells -hierarchical -filter {REF_NAME == DSP48E2}]
if {[llength $dsp_cells] != 64} {
  error "expected 64 parallel requant DSP48E2 cells, got [llength $dsp_cells]"
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
if {$setup_wns < 0.0 || $hold_whs < 0.0} {
  error "M8 parallel requant failed 200 MHz timing: WNS=$setup_wns WHS=$hold_whs"
}

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

set f [open [file join $report_dir run_metadata.txt] w]
puts $f "design=alexnet_m8n8_parallel_requant"
puts $f "logical_shape=M8xN8"
puts $f "parallel_requant_dsp48e2=[llength $dsp_cells]"
puts $f "pipeline_stages=5"
puts $f "frequency_mhz=$frequency_mhz"
puts $f "wns_ns=$setup_wns"
puts $f "whs_ns=$hold_whs"
puts $f "vivado=[version -short]"
puts $f "part=$part"
puts $f "git_commit=[exec git -C $repo_root rev-parse HEAD]"
puts $f "scalar_rtl_sha256=[lindex [exec sha256sum $scalar_rtl] 0]"
puts $f "parallel_rtl_sha256=[lindex [exec sha256sum $parallel_rtl] 0]"
close $f

puts "ALEXNET_M8N8_PARALLEL_REQUANT_OOC_PASS DSP=64 WNS=$setup_wns WHS=$hold_whs"
