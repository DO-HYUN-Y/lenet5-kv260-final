set seed 20260724
set random_stalls 0
if {$argc >= 1} { set seed [lindex $argv 0] }
if {$argc >= 2} { set random_stalls [lindex $argv 1] }

set root [file normalize [file join [file dirname [info script]] ..]]
set out_dir [file join $root build fc_stream_dpic]
file mkdir $out_dir
cd $out_dir
set rtl [file join $root rtl]
set tb [file join $root tb tb_fc_stream_datapath.sv]
set golden [file join $root golden fc_stream_golden.c]

exec xvlog -sv -d SIMULATION \
    [file join $rtl packed_pe.sv] \
    [file join $rtl fc_vector_gen.sv] \
    [file join $rtl dual_mode_weight_buffer.sv] \
    [file join $rtl fc_group_skew.sv] \
    [file join $rtl sa_packed_dual_mode.sv] \
    [file join $rtl fc_result_router.sv] \
    [file join $rtl dual_lane_postprocess.sv] \
    [file join $rtl postprocess_array.sv] \
    [file join $rtl banked_activation_writer.sv] \
    [file join $rtl fc_stream_datapath.sv] $tb
exec xsc $golden
exec xelab tb_fc_stream_datapath -debug typical -sv_lib dpi

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

exec xsim tb_fc_stream_datapath -runall \
    -testplusarg SEED=$seed -testplusarg RANDOM_STALLS=0
check_log [file join $out_dir xsim.log] \
          "FC_STREAM_DATAPATH TEST PASSED"
file copy -force [file join $out_dir xsim.log] \
                 [file join $out_dir directed_xsim.log]

if {$random_stalls} {
  exec xsim tb_fc_stream_datapath -runall \
      -testplusarg SEED=$seed -testplusarg RANDOM_STALLS=1
  check_log [file join $out_dir xsim.log] \
            "FC_STREAM_DATAPATH TEST PASSED"
  file copy -force [file join $out_dir xsim.log] \
                   [file join $out_dir random_xsim.log]
}

puts "FC_STREAM_DPIC_PASS seed=$seed random_stalls=$random_stalls"
