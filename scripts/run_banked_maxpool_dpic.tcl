set root [file normalize [file join [file dirname [info script]] ..]]
set out_dir [file join $root build banked_maxpool_dpic]
file mkdir $out_dir
cd $out_dir

set rtl [list \
    [file join $root rtl maxpool2x2_int8.sv] \
    [file join $root rtl banked_maxpool2x2.sv]]
set tb [file join $root tb tb_banked_maxpool2x2.sv]
set golden [file join $root golden maxpool2x2_golden.c]
set coverage_db [file join $out_dir coverage.db]

exec xvlog -sv -d SIMULATION {*}$rtl $tb
exec xsc $golden
exec xelab tb_banked_maxpool2x2 -debug typical -sv_lib dpi \
    -cc_db $coverage_db
exec xsim tb_banked_maxpool2x2 -runall

set log_path [file join $out_dir xsim.log]
set fp [open $log_path r]
set text [read $fp]
close $fp
if {![string match "*BANKED_MAXPOOL2X2 TEST PASSED*" $text] ||
    [string match {*Fatal:*} $text] ||
    [string match {*ERROR:*} $text]} {
  error "Simulation failed; see $log_path"
}
file copy -force $log_path [file join $out_dir directed_xsim.log]
puts "BANKED_MAXPOOL_DPIC_PASS"
