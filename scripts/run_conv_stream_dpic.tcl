# Directed run is mandatory; random stalls execute only after it passes.
set seed 314159
set random_cycles 0
if {$argc >= 1} { set seed [lindex $argv 0] }
if {$argc >= 2} { set random_cycles [lindex $argv 1] }

set root [file normalize [file join [file dirname [info script]] ..]]
set out_dir [file join $root build conv_stream_dpic]
file mkdir $out_dir
cd $out_dir

set rtl [file join $root rtl]
set tb [file join $root tb tb_conv_stream_datapath.sv]
set golden [file join $root golden conv_stream_golden.c]

exec xvlog -sv -d SIMULATION \
  [file join $rtl packed_pe.sv] [file join $rtl sa_packed_4x8.sv] \
  [file join $rtl skew_buf.sv] [file join $rtl weight_loader.sv] \
  [file join $rtl window_gen.sv] [file join $rtl column_result_router.sv] \
  [file join $rtl dual_lane_postprocess.sv] \
  [file join $rtl postprocess_array.sv] \
  [file join $rtl banked_activation_writer.sv] \
  [file join $rtl conv_stream_datapath.sv] $tb
exec xsc $golden
exec xelab tb_conv_stream_datapath -debug typical -sv_lib dpi

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

exec xsim tb_conv_stream_datapath -runall -testplusarg SEED=$seed -testplusarg RANDOM_CYCLES=0
check_log [file join $out_dir xsim.log] "CONV_STREAM_DATAPATH TEST PASSED"
file copy -force [file join $out_dir xsim.log] \
                 [file join $out_dir directed_xsim.log]

if {$random_cycles > 0} {
  exec xsim tb_conv_stream_datapath -runall -testplusarg SEED=$seed -testplusarg RANDOM_CYCLES=$random_cycles
  check_log [file join $out_dir xsim.log] "CONV_STREAM_DATAPATH TEST PASSED"
  file copy -force [file join $out_dir xsim.log] \
                   [file join $out_dir random_xsim.log]
}

puts "CONV_STREAM_DPIC_PASS seed=$seed random_cycles=$random_cycles"
