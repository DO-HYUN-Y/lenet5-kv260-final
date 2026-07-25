set root [file normalize [file join [file dirname [info script]] ..]]
set out_dir [file join $root build lenet_param_loader]
file mkdir $out_dir
cd $out_dir

exec xvlog -sv -d SIMULATION \
    [file join $root rtl lenet_param_loader.sv] \
    [file join $root tb tb_lenet_param_loader.sv]
exec xelab tb_lenet_param_loader -debug typical
exec xsim tb_lenet_param_loader -runall

set log_path [file join $out_dir xsim.log]
set fp [open $log_path r]
set text [read $fp]
close $fp
if {![string match "*LENET_PARAM_LOADER TEST PASSED*" $text] ||
    [string match {*Fatal:*} $text] ||
    [string match {*ERROR:*} $text]} {
  error "Simulation failed; see $log_path"
}
puts "LENET_PARAM_LOADER_PASS"
