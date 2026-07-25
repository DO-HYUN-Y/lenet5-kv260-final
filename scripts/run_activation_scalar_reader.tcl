set root [file normalize [file join [file dirname [info script]] ..]]
set out_dir [file join $root build activation_scalar_reader]
file mkdir $out_dir
cd $out_dir

set rtl [file join $root rtl activation_scalar_reader.sv]
set tb [file join $root tb tb_activation_scalar_reader.sv]
set coverage_db [file join $out_dir coverage.db]

exec xvlog -sv -d SIMULATION $rtl $tb
exec xelab tb_activation_scalar_reader -debug typical \
    -cc_db $coverage_db
exec xsim tb_activation_scalar_reader -runall

set log_path [file join $out_dir xsim.log]
set fp [open $log_path r]
set text [read $fp]
close $fp
if {![string match "*ACTIVATION_SCALAR_READER TEST PASSED*" $text] ||
    [string match {*Fatal:*} $text] ||
    [string match {*ERROR:*} $text]} {
  error "Simulation failed; see $log_path"
}
file copy -force $log_path [file join $out_dir directed_xsim.log]
puts "ACTIVATION_SCALAR_READER_PASS"
