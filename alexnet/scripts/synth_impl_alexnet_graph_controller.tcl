set part xck26-sfvc784-2LV-c
set frequency_mhz 200
set_param general.maxThreads 8

set alexnet_root [file normalize [file join [file dirname [info script]] ..]]
set rtl_source [file join $alexnet_root rtl control alexnet_graph_controller.sv]
set xdc_source [file join $alexnet_root constraints alexnet_graph_controller.xdc]
set out_dir [file join $alexnet_root build graph_controller_ooc 200mhz]
set report_dir [file join $alexnet_root reports graph_controller 200mhz]
file mkdir $out_dir
file mkdir $report_dir
cd $out_dir

read_verilog -sv $rtl_source
read_xdc $xdc_source
synth_design -top alexnet_graph_controller -part $part -mode out_of_context
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
puts $f "design=alexnet_graph_controller"
puts $f "boundary=logical_conv1_through_fc8_root_sequencer"
puts $f "frequency_mhz=$frequency_mhz"
puts $f "clock_period_ns=5.000"
puts $f "part=$part"
puts $f "vivado=[version -short]"
puts $f "layer_order=conv1,conv2,conv3,conv4,conv5,fc6,fc7,fc8"
puts $f "shared_owner_acquisitions=2"
puts $f "full_data_services_connected=false"
puts $f "rtl_sha256=[lindex [exec sha256sum $rtl_source] 0]"
puts $f "xdc_sha256=[lindex [exec sha256sum $xdc_source] 0]"
close $f
puts "ALEXNET_GRAPH_CONTROLLER_OOC_DONE frequency_mhz=$frequency_mhz"
