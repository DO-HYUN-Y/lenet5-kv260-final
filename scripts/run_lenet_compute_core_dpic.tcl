set seed 20260724
set random_stalls 0
if {$argc >= 1} { set seed [lindex $argv 0] }
if {$argc >= 2} { set random_stalls [lindex $argv 1] }

set root [file normalize [file join [file dirname [info script]] ..]]
set out_dir [file join $root build lenet_compute_core_dpic]
file mkdir $out_dir
cd $out_dir
set rtl [file join $root rtl]

exec xvlog -sv -d SIMULATION \
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
    [file join $root tb tb_lenet_compute_core.sv]
exec xsc [file join $root golden conv_stream_golden.c] \
         [file join $root golden fc_stream_golden.c]
exec xelab tb_lenet_compute_core -debug typical -sv_lib dpi

proc check_log {path marker} {
  set fp [open $path r]
  set text [read $fp]
  close $fp
  if {![string match "*$marker*" $text] ||
      [string match {*Fatal:*} $text] ||
      [string match {*ERROR:*} $text]} {
    error "Simulation failed; see $path"
  }
}

exec xsim tb_lenet_compute_core -runall \
    -testplusarg SEED=$seed -testplusarg RANDOM_STALLS=0
check_log [file join $out_dir xsim.log] \
          "LENET_COMPUTE_CORE TEST PASSED"
file copy -force [file join $out_dir xsim.log] \
                 [file join $out_dir directed_xsim.log]

if {$random_stalls} {
  exec xsim tb_lenet_compute_core -runall \
      -testplusarg SEED=$seed -testplusarg RANDOM_STALLS=1
  check_log [file join $out_dir xsim.log] \
            "LENET_COMPUTE_CORE TEST PASSED"
  file copy -force [file join $out_dir xsim.log] \
                   [file join $out_dir random_xsim.log]
}

puts "LENET_COMPUTE_CORE_DPIC_PASS seed=$seed random_stalls=$random_stalls"
