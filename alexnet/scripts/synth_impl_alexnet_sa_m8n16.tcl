set part xck26-sfvc784-2LV-c
set frequency_mhz 200
set_param general.maxThreads 8

set alexnet_root [file normalize [file join [file dirname [info script]] ..]]
set repo_root [file normalize [file join $alexnet_root ..]]
set out_dir [file join $alexnet_root build sa_m8n16_ooc 200mhz]
set report_dir [file join $alexnet_root reports sa_m8n16 200mhz]
file mkdir $out_dir
file mkdir $report_dir
cd $out_dir

set pe_source [file join $alexnet_root rtl packed_mac alexnet_packed_pe.sv]
set base_source [file join $alexnet_root rtl sa alexnet_sa_m4n8.sv]
set tile_source [file join $alexnet_root rtl sa alexnet_sa_m8n16.sv]
set xdc_source [file join $alexnet_root constraints alexnet_sa_m4n8.xdc]
read_verilog -sv $pe_source $base_source $tile_source
read_xdc $xdc_source
synth_design -top alexnet_sa_m8n16 -part $part -mode out_of_context

set synth_dsp_count [llength [get_cells -hierarchical -filter {REF_NAME == DSP48E2}]]
if {$synth_dsp_count != 64} {
  error "M8xN16 SA expected 64 DSP48E2 after synthesis, got $synth_dsp_count"
}

write_checkpoint -force [file join $out_dir post_synth.dcp]
report_utilization -file [file join $report_dir synth_utilization.rpt]
report_utilization -hierarchical -file \
    [file join $report_dir synth_utilization_hierarchical.rpt]
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
if {$setup_wns < 0.0 || $hold_whs < 0.0} {
  error "M8xN16 SA failed 200 MHz timing: WNS=$setup_wns WHS=$hold_whs"
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

set metadata_file [open [file join $report_dir run_metadata.txt] w]
puts $metadata_file "design=alexnet_sa_m8n16"
puts $metadata_file "logical_shape=M8xN16"
puts $metadata_file "physical_shape=4x16"
puts $metadata_file "git_commit=[exec git -C $repo_root rev-parse HEAD]"
puts $metadata_file "vivado=[version -short]"
puts $metadata_file "part=$part"
puts $metadata_file "frequency_mhz=$frequency_mhz"
puts $metadata_file "clock_period_ns=5.000000"
puts $metadata_file "dsp48e2=$synth_dsp_count"
puts $metadata_file "wns_ns=$setup_wns"
puts $metadata_file "whs_ns=$hold_whs"
puts $metadata_file "pe_rtl_sha256=[lindex [exec sha256sum $pe_source] 0]"
puts $metadata_file "base_rtl_sha256=[lindex [exec sha256sum $base_source] 0]"
puts $metadata_file "tile_rtl_sha256=[lindex [exec sha256sum $tile_source] 0]"
puts $metadata_file "xdc_sha256=[lindex [exec sha256sum $xdc_source] 0]"
close $metadata_file

puts "ALEXNET_SA_M8N16_OOC_PASS frequency_mhz=$frequency_mhz dsp=$synth_dsp_count WNS=$setup_wns WHS=$hold_whs"
