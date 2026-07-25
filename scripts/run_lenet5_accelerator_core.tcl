set root [file normalize [file join [file dirname [info script]] ..]]
set out_dir [file join $root build lenet5_accelerator_core]
file mkdir $out_dir
cd $out_dir

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

exec xvlog -sv -d SIMULATION {*}$rtl_files \
    [file join $root tb tb_lenet5_accelerator_core.sv]
exec xelab tb_lenet5_accelerator_core -debug typical
exec xsim tb_lenet5_accelerator_core -runall

set log_path [file join $out_dir xsim.log]
set fp [open $log_path r]
set text [read $fp]
close $fp
if {![string match "*LENET5_ACCELERATOR_CORE TEST PASSED*" $text] ||
    [string match {*Fatal:*} $text] ||
    [string match {*ERROR:*} $text]} {
  error "Simulation failed; see $log_path"
}
file copy -force $log_path [file join $out_dir directed_xsim.log]
puts "LENET5_ACCELERATOR_CORE_PASS"
