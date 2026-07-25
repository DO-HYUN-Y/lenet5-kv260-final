set seed 20260724
set random_count 0
if {$argc >= 1} { set seed [lindex $argv 0] }
if {$argc >= 2} { set random_count [lindex $argv 1] }

set root [file normalize [file join [file dirname [info script]] ..]]
set out_dir [file join $root build postprocess_dpic]
file mkdir $out_dir
cd $out_dir

set rtl [file join $root rtl dual_lane_postprocess.sv]
set tb [file join $root tb tb_dual_lane_postprocess.sv]
set golden [file join $root golden postprocess_golden.c]
set coverage_db [file join $out_dir coverage.db]

exec xvlog -sv -d SIMULATION $rtl $tb
exec xsc $golden
exec xelab tb_dual_lane_postprocess -debug typical -sv_lib dpi \
    -cc_db $coverage_db

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

exec xsim tb_dual_lane_postprocess -runall \
    -testplusarg SEED=$seed -testplusarg RANDOM_COUNT=0
check_log [file join $out_dir xsim.log] \
          "DUAL_LANE_POSTPROCESS TEST PASSED"
file copy -force [file join $out_dir xsim.log] \
                 [file join $out_dir directed_xsim.log]

if {$random_count > 0} {
  exec xsim tb_dual_lane_postprocess -runall \
      -testplusarg SEED=$seed -testplusarg RANDOM_COUNT=$random_count
  check_log [file join $out_dir xsim.log] \
            "DUAL_LANE_POSTPROCESS TEST PASSED"
  file copy -force [file join $out_dir xsim.log] \
                   [file join $out_dir random_xsim.log]
}

puts "POSTPROCESS_DPIC_PASS seed=$seed random_count=$random_count"
