set part xck26-sfvc784-2LV-c
set frequency_mhz 200
set expected_uram 32
set replay_bits 1024
set replay_gbps [expr {$replay_bits * $frequency_mhz / 8000.0}]
set_param general.maxThreads 8

set alexnet_root [file normalize [file join [file dirname [info script]] ..]]
set repo_root [file normalize [file join $alexnet_root ..]]
set rtl_source \
    [file join $alexnet_root rtl memory alexnet_n128_weight_pingpong.sv]
set harness_source \
    [file join $alexnet_root rtl memory alexnet_n128_weight_pingpong_ooc.sv]
set xdc_source \
    [file join $alexnet_root constraints alexnet_n8_weight_tile_bank.xdc]
set out_dir [file join $alexnet_root build n128_weight_pingpong_ooc 200mhz]
set report_dir [file join $alexnet_root reports n128_weight_pingpong 200mhz]
file mkdir $out_dir
file mkdir $report_dir
cd $out_dir

read_verilog -sv $rtl_source $harness_source
read_xdc $xdc_source
synth_design -top alexnet_n128_weight_pingpong_ooc -part $part \
    -mode out_of_context

set synth_uram \
    [llength [get_cells -hierarchical -filter {REF_NAME == URAM288}]]
if {$synth_uram != $expected_uram} {
  error "N128 weight ping-pong expected $expected_uram URAM288, got $synth_uram"
}

write_checkpoint -force [file join $out_dir post_synth.dcp]
report_utilization -file [file join $report_dir synth_utilization.rpt]
report_utilization -hierarchical -file \
    [file join $report_dir synth_utilization_hierarchical.rpt]
report_timing_summary -delay_type min_max -check_timing_verbose \
    -file [file join $report_dir synth_timing_summary.rpt]
report_control_sets -verbose \
    -file [file join $report_dir synth_control_sets.rpt]

opt_design
place_design
phys_opt_design
route_design

set setup_path [get_timing_paths -delay_type max -max_paths 1]
set hold_path [get_timing_paths -delay_type min -max_paths 1]
set setup_wns [get_property SLACK $setup_path]
set hold_whs [get_property SLACK $hold_path]
if {$setup_wns < 0.0 || $hold_whs < 0.0} {
  error "N128 weight ping-pong failed 200 MHz timing: WNS=$setup_wns WHS=$hold_whs"
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
report_high_fanout_nets -fanout_greater_than 16 -max_nets 100 \
    -file [file join $report_dir high_fanout.rpt]
report_route_status -file [file join $report_dir route_status.rpt]
report_control_sets -verbose \
    -file [file join $report_dir impl_control_sets.rpt]
report_drc -file [file join $report_dir drc.rpt]

set metadata_file [open [file join $report_dir run_metadata.txt] w]
puts $metadata_file "design=alexnet_n128_weight_pingpong"
puts $metadata_file "sets=2"
puts $metadata_file "banks_per_set=8"
puts $metadata_file "bank_word_bits=128"
puts $metadata_file "depth_k=4096"
puts $metadata_file "external_fill_bits_per_cycle=128"
puts $metadata_file "internal_replay_bits_per_cycle=$replay_bits"
puts $metadata_file "internal_replay_peak_gbytes_per_second=$replay_gbps"
puts $metadata_file "git_commit=[exec git -C $repo_root rev-parse HEAD]"
puts $metadata_file "vivado=[version -short]"
puts $metadata_file "part=$part"
puts $metadata_file "frequency_mhz=$frequency_mhz"
puts $metadata_file "clock_period_ns=5.000000"
puts $metadata_file "uram288=$synth_uram"
puts $metadata_file "wns_ns=$setup_wns"
puts $metadata_file "whs_ns=$hold_whs"
puts $metadata_file "rtl_sha256=[lindex [exec sha256sum $rtl_source] 0]"
puts $metadata_file \
    "harness_sha256=[lindex [exec sha256sum $harness_source] 0]"
puts $metadata_file "xdc_sha256=[lindex [exec sha256sum $xdc_source] 0]"
close $metadata_file

puts "ALEXNET_N128_WEIGHT_PINGPONG_OOC_PASS frequency_mhz=$frequency_mhz URAM=$synth_uram replay_GBps=$replay_gbps WNS=$setup_wns WHS=$hold_whs"
