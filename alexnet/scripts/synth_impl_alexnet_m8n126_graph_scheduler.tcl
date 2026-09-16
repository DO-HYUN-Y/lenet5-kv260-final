set part xck26-sfvc784-2LV-c
set frequency_mhz 200
set_param general.maxThreads 8

set alexnet_root [file normalize [file join [file dirname [info script]] ..]]
set rtl_source [file join $alexnet_root rtl control alexnet_m8n126_graph_scheduler.sv]
set xdc_source [file join $alexnet_root constraints alexnet_graph_controller.xdc]
set out_dir [file join $alexnet_root build m8n126_graph_scheduler_ooc 200mhz]
set report_dir [file join $alexnet_root reports m8n126_graph_scheduler 200mhz]
file mkdir $out_dir
file mkdir $report_dir
cd $out_dir

read_verilog -sv $rtl_source
read_xdc $xdc_source
synth_design -top alexnet_m8n126_graph_scheduler -part $part -mode out_of_context
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
puts $f "design=alexnet_m8n126_graph_scheduler"
puts $f "boundary=batch1_conv1_through_fc8_dynamic_work_descriptors"
puts $f "frequency_mhz=$frequency_mhz"
puts $f "clock_period_ns=5.000"
puts $f "part=$part"
puts $f "vivado=[version -short]"
puts $f "logical_array=M8xN126"
puts $f "physical_array=M8xN128"
puts $f "expected_commands=1635"
puts $f "expected_macs=714188480"
puts $f "expected_logical_weight_bytes=61090496"
puts $f "expected_weight_transfer_bytes=61123264"
puts $f "rtl_sha256=[lindex [exec sha256sum $rtl_source] 0]"
puts $f "xdc_sha256=[lindex [exec sha256sum $xdc_source] 0]"
close $f
puts "ALEXNET_M8N126_GRAPH_SCHEDULER_OOC_DONE frequency_mhz=$frequency_mhz"
