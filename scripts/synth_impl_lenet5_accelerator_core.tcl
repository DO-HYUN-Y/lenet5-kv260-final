# Full top OOC synthesis, implementation, timing/resource/DRC sign-off.
set part xck26-sfvc784-2LV-c
# Use all eight physical cores on the i9-9900K host.
set_param general.maxThreads 8

set root [file normalize [file join [file dirname [info script]] ..]]
set report_dir [file join $root reports lenet5_accelerator_core]
set checkpoint_dir [file join $root checkpoints lenet5_accelerator_core]
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
    [file join $rtl lenet5_accelerator_core.sv]]

foreach source_file $rtl_files {
  read_verilog -sv $source_file
}
read_xdc [file join $root constraints lenet5_accelerator_core.xdc]

synth_design -top lenet5_accelerator_core -part $part -mode out_of_context
write_checkpoint -force \
    [file join $checkpoint_dir lenet5_accelerator_core_post_synth.dcp]
report_utilization -hierarchical -file \
    [file join $report_dir synth_utilization_hierarchical.rpt]
report_utilization -file [file join $report_dir synth_utilization.rpt]
report_timing_summary -delay_type min_max -check_timing_verbose \
    -max_paths 10 -file [file join $report_dir synth_timing_summary.rpt]
check_timing -verbose -file [file join $report_dir synth_check_timing.rpt]

opt_design
place_design
phys_opt_design
route_design
phys_opt_design

write_checkpoint -force \
    [file join $checkpoint_dir lenet5_accelerator_core_post_route.dcp]
report_utilization -hierarchical -file \
    [file join $report_dir impl_utilization_hierarchical.rpt]
report_utilization -file [file join $report_dir impl_utilization.rpt]
report_timing_summary -delay_type min_max -check_timing_verbose \
    -max_paths 20 -file [file join $report_dir impl_timing_summary.rpt]
report_timing -delay_type max -max_paths 10 -sort_by group \
    -file [file join $report_dir impl_setup_worst.rpt]
report_timing -delay_type min -max_paths 10 -sort_by group \
    -file [file join $report_dir impl_hold_worst.rpt]
check_timing -verbose -file [file join $report_dir impl_check_timing.rpt]
report_drc -file [file join $report_dir impl_drc.rpt]

set setup_path [lindex [get_timing_paths -delay_type max -max_paths 1] 0]
set hold_path [lindex [get_timing_paths -delay_type min -max_paths 1] 0]
if {$setup_path eq "" || $hold_path eq ""} {
  error "No setup/hold timing paths found"
}
set wns [get_property SLACK $setup_path]
set whs [get_property SLACK $hold_path]

set summary_path [file join $report_dir signoff_summary.txt]
set fp [open $summary_path w]
puts $fp "PART=$part"
puts $fp "CLOCK_PERIOD_NS=5.000"
puts $fp "WNS_NS=$wns"
puts $fp "WHS_NS=$whs"
puts $fp "TIMING_MET=[expr {$wns >= 0.0 && $whs >= 0.0}]"
close $fp

puts "LENET5_FULL_TOP_WNS_NS=$wns"
puts "LENET5_FULL_TOP_WHS_NS=$whs"
if {$wns < 0.0 || $whs < 0.0} {
  error "Timing sign-off failed: WNS=$wns WHS=$whs"
}
puts "LENET5_ACCELERATOR_CORE_SYNTH_IMPL_PASS"
