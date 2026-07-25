set part xck26-sfvc784-2LV-c
set_param general.maxThreads 8

set root [file normalize [file join [file dirname [info script]] ..]]
set out_dir [file join $root build lenet_dma_addr_gen_impl]
file mkdir $out_dir

read_verilog -sv [file join $root rtl lenet_dma_addr_gen.sv]
read_xdc [file join $root constraints lenet_dma_addr_gen.xdc]
synth_design -top lenet_dma_addr_gen -part $part -mode out_of_context
report_utilization -file [file join $out_dir synth_utilization.rpt]
report_timing_summary -delay_type min_max \
    -file [file join $out_dir synth_timing_summary.rpt]
write_checkpoint -force [file join $out_dir post_synth.dcp]

opt_design
place_design
phys_opt_design
route_design
phys_opt_design

report_timing_summary -delay_type min_max \
    -file [file join $out_dir impl_timing_summary.rpt]
report_utilization -file [file join $out_dir impl_utilization.rpt]
report_drc -file [file join $out_dir impl_drc.rpt]
report_methodology -file [file join $out_dir impl_methodology.rpt]
report_route_status -file [file join $out_dir impl_route_status.rpt]
check_timing -verbose -file [file join $out_dir impl_check_timing.rpt]
write_checkpoint -force [file join $out_dir post_route.dcp]

set timing_paths [get_timing_paths -delay_type max -max_paths 1]
set hold_paths [get_timing_paths -delay_type min -max_paths 1]
set wns [get_property SLACK $timing_paths]
set whs [get_property SLACK $hold_paths]
puts "LENET_DMA_ADDR_GEN_WNS_NS=$wns"
puts "LENET_DMA_ADDR_GEN_WHS_NS=$whs"
if {$wns < 0.0 || $whs < 0.0} {
  error "lenet_dma_addr_gen implementation timing failed"
}
puts "LENET_DMA_ADDR_GEN_IMPL_PASS"
