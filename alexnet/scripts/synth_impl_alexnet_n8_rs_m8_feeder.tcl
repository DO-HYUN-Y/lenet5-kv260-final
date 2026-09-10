set part xck26-sfvc784-2LV-c
set frequency_mhz 200
set_param general.maxThreads 8

set alexnet_root [file normalize [file join [file dirname [info script]] ..]]
set repo_root [file normalize [file join $alexnet_root ..]]
set base_source [file join $alexnet_root rtl feeder alexnet_n8_rs_m4_feeder.sv]
set rtl_source [file join $alexnet_root rtl feeder alexnet_n8_rs_m8_feeder.sv]
set xdc_source [file join $alexnet_root constraints alexnet_n8_rs_m4_feeder.xdc]
set out_dir [file join $alexnet_root build n8_rs_m8_feeder_ooc 200mhz]
set report_dir [file join $alexnet_root reports n8_rs_m8_feeder 200mhz]
file mkdir $out_dir
file mkdir $report_dir
cd $out_dir

read_verilog -sv $base_source $rtl_source
read_xdc $xdc_source
synth_design -top alexnet_n8_rs_m8_feeder -part $part -mode out_of_context
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
  error "M8 RS feeder failed 200 MHz timing: WNS=$setup_wns WHS=$hold_whs"
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

set bram36_count [llength [get_cells -hierarchical -filter {REF_NAME == RAMB36E2}]]
set metadata_file [open [file join $report_dir run_metadata.txt] w]
puts $metadata_file "design=alexnet_n8_rs_m8_feeder"
puts $metadata_file "input_lanes=8"
puts $metadata_file "output_m=8"
puts $metadata_file "parallel_ring_read_copies=8"
puts $metadata_file "max_kernel=11"
puts $metadata_file "max_input_width=224"
puts $metadata_file "supported_modes=k11_s4_p2,k5_s1_p2,k3_s1_p1"
puts $metadata_file "git_commit=[exec git -C $repo_root rev-parse HEAD]"
puts $metadata_file "vivado=[version -short]"
puts $metadata_file "part=$part"
puts $metadata_file "frequency_mhz=$frequency_mhz"
puts $metadata_file "clock_period_ns=5.000000"
puts $metadata_file "ramb36e2=$bram36_count"
puts $metadata_file "wns_ns=$setup_wns"
puts $metadata_file "whs_ns=$hold_whs"
puts $metadata_file "base_rtl_sha256=[lindex [exec sha256sum $base_source] 0]"
puts $metadata_file "rtl_sha256=[lindex [exec sha256sum $rtl_source] 0]"
puts $metadata_file "xdc_sha256=[lindex [exec sha256sum $xdc_source] 0]"
close $metadata_file

puts "ALEXNET_N8_RS_M8_FEEDER_OOC_PASS frequency_mhz=$frequency_mhz BRAM36=$bram36_count WNS=$setup_wns WHS=$hold_whs"
