set seed 20260724
set random_cycles 0
if {$argc >= 1} { set seed [lindex $argv 0] }
if {$argc >= 2} { set random_cycles [lindex $argv 1] }

set root [file normalize [file join [file dirname [info script]] ..]]
set out_dir [file join $root build banked_writer]
file mkdir $out_dir
cd $out_dir

set rtl [file join $root rtl banked_activation_writer.sv]
set tb [file join $root tb tb_banked_activation_writer.sv]
set coverage_db [file join $out_dir coverage.db]

exec xvlog -sv -d SIMULATION $rtl $tb
exec xelab tb_banked_activation_writer -debug typical \
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

exec xsim tb_banked_activation_writer -runall \
    -testplusarg SEED=$seed -testplusarg RANDOM_CYCLES=0
check_log [file join $out_dir xsim.log] \
          "BANKED_ACTIVATION_WRITER TEST PASSED"
file copy -force [file join $out_dir xsim.log] \
                 [file join $out_dir directed_xsim.log]

if {$random_cycles > 0} {
  exec xsim tb_banked_activation_writer -runall \
      -testplusarg SEED=$seed -testplusarg RANDOM_CYCLES=$random_cycles
  check_log [file join $out_dir xsim.log] \
            "BANKED_ACTIVATION_WRITER TEST PASSED"
  file copy -force [file join $out_dir xsim.log] \
                   [file join $out_dir random_xsim.log]
}

puts "BANKED_WRITER_PASS seed=$seed random_cycles=$random_cycles"
