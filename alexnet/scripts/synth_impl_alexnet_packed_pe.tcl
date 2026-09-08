set part xck26-sfvc784-2LV-c
set frequency_mhz 200
set_param general.maxThreads 8

set alexnet_root [file normalize [file join [file dirname [info script]] ..]]
set repo_root [file normalize [file join $alexnet_root ..]]
set run_tag "${frequency_mhz}mhz"
set out_dir [file join $alexnet_root build packed_pe_ooc $run_tag]
set report_dir [file join $alexnet_root reports packed_pe $run_tag]
file mkdir $out_dir
file mkdir $report_dir
cd $out_dir

set pe_source [file join $alexnet_root rtl packed_mac alexnet_packed_pe.sv]
set xdc_source [file join $alexnet_root constraints alexnet_packed_pe.xdc]
read_verilog -sv $pe_source
read_xdc $xdc_source
synth_design -top alexnet_packed_pe -part $part -mode out_of_context

write_checkpoint -force [file join $out_dir post_synth.dcp]
report_utilization -file [file join $report_dir synth_utilization.rpt]
report_utilization -hierarchical -file \
    [file join $report_dir synth_utilization_hierarchical.rpt]
report_timing_summary -delay_type min_max -check_timing_verbose \
    -file [file join $report_dir synth_timing_summary.rpt]
report_control_sets -verbose -file [file join $report_dir synth_control_sets.rpt]

opt_design
place_design
phys_opt_design
route_design

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
report_clock_utilization -file [file join $report_dir clock_utilization.rpt]
report_route_status -file [file join $report_dir route_status.rpt]
report_control_sets -verbose -file [file join $report_dir impl_control_sets.rpt]
report_drc -file [file join $report_dir drc.rpt]
report_power -file [file join $report_dir power.rpt]

set metadata_file [open [file join $report_dir run_metadata.txt] w]
puts $metadata_file "design=alexnet_packed_pe"
puts $metadata_file "git_commit=[exec git -C $repo_root rev-parse HEAD]"
puts $metadata_file "vivado=[version -short]"
puts $metadata_file "part=$part"
puts $metadata_file "frequency_mhz=$frequency_mhz"
puts $metadata_file "clock_period_ns=5.000000"
puts $metadata_file "rtl_sha256=[lindex [exec sha256sum $pe_source] 0]"
puts $metadata_file "xdc_sha256=[lindex [exec sha256sum $xdc_source] 0]"
close $metadata_file

puts "ALEXNET_PACKED_PE_OOC_DONE frequency_mhz=$frequency_mhz"
