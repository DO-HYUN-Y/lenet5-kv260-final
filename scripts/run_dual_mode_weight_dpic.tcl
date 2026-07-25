set seed 20260724
if {$argc >= 1} { set seed [lindex $argv 0] }

set root [file normalize [file join [file dirname [info script]] ..]]
set out_dir [file join $root build dual_mode_weight_dpic]
file mkdir $out_dir
cd $out_dir

set rtl [file join $root rtl dual_mode_weight_buffer.sv]
set tb [file join $root tb tb_dual_mode_weight_buffer.sv]
set golden [file join $root golden dual_weight_golden.c]
set coverage_db [file join $out_dir coverage.db]

exec xvlog -sv -d SIMULATION $rtl $tb
exec xsc $golden
exec xelab tb_dual_mode_weight_buffer -debug typical -sv_lib dpi \
    -cc_db $coverage_db
exec xsim tb_dual_mode_weight_buffer -runall -testplusarg SEED=$seed

set log_path [file join $out_dir xsim.log]
set fp [open $log_path r]
set text [read $fp]
close $fp
if {![string match "*DUAL_MODE_WEIGHT_BUFFER TEST PASSED*" $text] ||
    [string match {*Fatal:*} $text] ||
    [string match {*ERROR:*} $text]} {
  error "Simulation failed; see $log_path"
}
file copy -force $log_path [file join $out_dir directed_xsim.log]
puts "DUAL_MODE_WEIGHT_DPIC_PASS seed=$seed"
