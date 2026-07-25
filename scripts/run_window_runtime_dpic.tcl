set seed 20260724
set random_stalls 0
if {$argc >= 1} { set seed [lindex $argv 0] }
if {$argc >= 2} { set random_stalls [lindex $argv 1] }

set root [file normalize [file join [file dirname [info script]] ..]]
set out_dir [file join $root build window_runtime_dpic]
file mkdir $out_dir
cd $out_dir

exec xvlog -sv -d SIMULATION \
    [file join $root rtl window_gen_runtime.sv] \
    [file join $root tb tb_window_gen_runtime.sv]
exec xsc [file join $root golden runtime_window_golden.c]
exec xelab tb_window_gen_runtime -debug typical -sv_lib dpi

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

exec xsim tb_window_gen_runtime -runall \
    -testplusarg SEED=$seed -testplusarg RANDOM_STALLS=0
check_log [file join $out_dir xsim.log] "WINDOW_GEN_RUNTIME TEST PASSED"
file copy -force [file join $out_dir xsim.log] \
                 [file join $out_dir directed_xsim.log]

if {$random_stalls} {
  exec xsim tb_window_gen_runtime -runall \
      -testplusarg SEED=$seed -testplusarg RANDOM_STALLS=1
  check_log [file join $out_dir xsim.log] \
            "WINDOW_GEN_RUNTIME TEST PASSED"
  file copy -force [file join $out_dir xsim.log] \
                   [file join $out_dir random_xsim.log]
}

puts "WINDOW_RUNTIME_DPIC_PASS seed=$seed random_stalls=$random_stalls"
