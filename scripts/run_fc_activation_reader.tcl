set root [file normalize [file join [file dirname [info script]] ..]]
set out_dir [file join $root build fc_activation_reader]
file mkdir $out_dir
cd $out_dir

exec xvlog -sv -d SIMULATION \
    [file join $root rtl fc_activation_reader.sv] \
    [file join $root tb tb_fc_activation_reader.sv]
exec xelab tb_fc_activation_reader -debug typical
exec xsim tb_fc_activation_reader -runall

set log_path [file join $out_dir xsim.log]
set fp [open $log_path r]
set text [read $fp]
close $fp
if {![string match "*FC_ACTIVATION_READER TEST PASSED*" $text] ||
    [string match {*Fatal:*} $text] ||
    [string match {*ERROR:*} $text]} {
  error "Simulation failed; see $log_path"
}
file copy -force $log_path [file join $out_dir directed_xsim.log]
puts "FC_ACTIVATION_READER_PASS"
