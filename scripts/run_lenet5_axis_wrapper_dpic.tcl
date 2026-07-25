set seed 20260725
set random_run 0
if {$argc >= 1} { set seed [lindex $argv 0] }
if {$argc >= 2} { set random_run [lindex $argv 1] }

set root [file normalize [file join [file dirname [info script]] ..]]
set out_dir [file join $root build lenet5_axis_wrapper_dpic]
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
    [file join $rtl lenet5_accelerator_core.sv] \
    [file join $rtl lenet_dma_addr_gen.sv] \
    [file join $rtl axis_lenet_ingress.sv] \
    [file join $rtl axis_lenet_result.sv] \
    [file join $rtl lenet_axi_lite_regs.sv] \
    [file join $rtl axi_dma_simple_master.sv] \
    [file join $rtl lenet_system_scheduler.sv] \
    [file join $rtl lenet5_axis_wrapper.sv]]

exec xvlog -sv -d SIMULATION {*}$rtl_files \
    [file join $root tb tb_lenet5_axis_wrapper.sv]
exec xsc [file join $root golden lenet5_axis_wrapper_golden.c]
exec xelab tb_lenet5_axis_wrapper -debug typical -sv_lib dpi

proc check_log {path marker} {
  set fp [open $path r]
  set log_text [read $fp]
  close $fp
  if {![string match "*$marker*" $log_text] ||
      [string match {*Fatal:*} $log_text] ||
      [string match {*ERROR:*} $log_text]} {
    error "Simulation failed; see $path"
  }
}

exec xsim tb_lenet5_axis_wrapper -runall \
    -testplusarg SEED=$seed -testplusarg RANDOM_STALLS=0
check_log [file join $out_dir xsim.log] \
          "LENET5_AXIS_WRAPPER TEST PASSED"
file copy -force [file join $out_dir xsim.log] \
                 [file join $out_dir directed_xsim.log]

if {$random_run > 0} {
  exec xsim tb_lenet5_axis_wrapper -runall \
      -testplusarg SEED=$seed -testplusarg RANDOM_STALLS=1
  check_log [file join $out_dir xsim.log] \
            "LENET5_AXIS_WRAPPER TEST PASSED"
  file copy -force [file join $out_dir xsim.log] \
                   [file join $out_dir random_stall_xsim.log]
}

puts "LENET5_AXIS_WRAPPER_DPIC_PASS seed=$seed random_run=$random_run"
