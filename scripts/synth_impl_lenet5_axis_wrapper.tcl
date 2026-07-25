# AXI/AXIS wrapper OOC synthesis, implementation, timing/resource/DRC sign-off.
set part xck26-sfvc784-2LV-c
set_param general.maxThreads 8

set root [file normalize [file join [file dirname [info script]] ..]]
set report_dir [file join $root reports lenet5_axis_wrapper]
set checkpoint_dir [file join $root checkpoints lenet5_axis_wrapper]
file mkdir $report_dir
file mkdir $checkpoint_dir

set rtl [file join $root rtl]
set rtl_files [list \
    [file join $rtl activation_bank_set.sv] \
    [file join $rtl activation_scalar_reader.sv] \
    [file join $rtl fc_activation_reader.sv] \
    [file join $rtl maxpool2x2_int8.sv] \
    [file join $rtl banked_maxpool2x2.sv] \
    [file join $rtl activation_pingpong_subsystem.sv] \
    [file join $rtl window_gen_runtime.sv] \
    [file join $rtl fc_vector_gen.sv] \
    [file join $rtl dual_mode_weight_buffer.sv] \
    [file join $rtl skew_buf.sv] \
    [file join $rtl fc_group_skew.sv] \
    [file join $rtl packed_pe.sv] \
    [file join $rtl sa_packed_dual_mode.sv] \
    [file join $rtl column_result_router_runtime.sv] \
    [file join $rtl fc_result_router.sv] \
    [file join $rtl dual_lane_postprocess.sv] \
    [file join $rtl postprocess_array.sv] \
    [file join $rtl banked_activation_writer.sv] \
    [file join $rtl lenet_compute_core.sv] \
    [file join $rtl lenet_param_loader.sv] \
    [file join $rtl lenet_global_controller.sv] \
    [file join $rtl lenet5_accelerator_core.sv] \
    [file join $rtl lenet_dma_addr_gen.sv] \
    [file join $rtl axis_lenet_ingress.sv] \
    [file join $rtl axis_lenet_result.sv] \
    [file join $rtl lenet_axi_lite_regs.sv] \
    [file join $rtl axi_dma_simple_master.sv] \
    [file join $rtl lenet_system_scheduler.sv] \
    [file join $rtl lenet5_axis_wrapper.sv]]

foreach source_file $rtl_files {
  read_verilog -sv $source_file
}
read_xdc [file join $root constraints lenet5_axis_wrapper.xdc]

synth_design -top lenet5_axis_wrapper -part $part -mode out_of_context
write_checkpoint -force \
    [file join $checkpoint_dir lenet5_axis_wrapper_post_synth.dcp]
report_utilization -hierarchical -file \
    [file join $report_dir synth_utilization_hierarchical.rpt]
report_utilization -file \
    [file join $report_dir synth_utilization.rpt]
report_timing_summary -delay_type min_max -check_timing_verbose \
    -max_paths 10 -file \
    [file join $report_dir synth_timing_summary.rpt]
check_timing -verbose -file \
    [file join $report_dir synth_check_timing.rpt]

opt_design
place_design
phys_opt_design
route_design
phys_opt_design

write_checkpoint -force \
    [file join $checkpoint_dir lenet5_axis_wrapper_post_route.dcp]
report_utilization -hierarchical -file \
    [file join $report_dir impl_utilization_hierarchical.rpt]
report_utilization -file \
    [file join $report_dir impl_utilization.rpt]
report_timing_summary -delay_type min_max -check_timing_verbose \
    -max_paths 20 -file \
    [file join $report_dir impl_timing_summary.rpt]
report_timing -delay_type max -max_paths 10 -sort_by group \
    -file [file join $report_dir impl_setup_worst.rpt]
report_timing -delay_type min -max_paths 10 -sort_by group \
    -file [file join $report_dir impl_hold_worst.rpt]
check_timing -verbose -file \
    [file join $report_dir impl_check_timing.rpt]
set reset_sync_cells [
    get_cells -hierarchical -filter {NAME =~ *reset_sync_r_reg*}
]
if {[llength $reset_sync_cells] > 0} {
  foreach reset_cdc_id {CDC-1 CDC-26} {
    create_waiver -type CDC -id $reset_cdc_id -user "lenet5" \
        -description \
        "Reviewed async assertion into the two-flop reset synchronizer" \
        -from [get_ports rst_n] \
        -to [get_pins -of_objects $reset_sync_cells]
  }
}
report_cdc -details -file [file join $report_dir impl_cdc.rpt]
report_drc -file [file join $report_dir impl_drc.rpt]

set setup_path [lindex [get_timing_paths -delay_type max -max_paths 1] 0]
set hold_path [lindex [get_timing_paths -delay_type min -max_paths 1] 0]
if {$setup_path eq "" || $hold_path eq ""} {
  error "No setup/hold timing paths found"
}
set wns [get_property SLACK $setup_path]
set whs [get_property SLACK $hold_path]

set timing_checks [check_timing -return_string]
set unconstrained_count 0
if {[regexp {There are ([0-9]+) register/latch pins with no clock} \
        $timing_checks match count]} {
  set unconstrained_count $count
}

set summary_path [file join $report_dir signoff_summary.txt]
set fp [open $summary_path w]
puts $fp "PART=$part"
puts $fp "CLOCK_PERIOD_NS=5.000"
puts $fp "MAX_THREADS=8"
puts $fp "WNS_NS=$wns"
puts $fp "WHS_NS=$whs"
puts $fp "UNCONSTRAINED_REGISTER_PINS=$unconstrained_count"
puts $fp "TIMING_MET=[expr {$wns >= 0.0 && $whs >= 0.0}]"
close $fp

puts "LENET5_AXIS_WRAPPER_WNS_NS=$wns"
puts "LENET5_AXIS_WRAPPER_WHS_NS=$whs"
if {$wns < 0.0 || $whs < 0.0} {
  error "Timing sign-off failed: WNS=$wns WHS=$whs"
}
puts "LENET5_AXIS_WRAPPER_SYNTH_IMPL_PASS"
