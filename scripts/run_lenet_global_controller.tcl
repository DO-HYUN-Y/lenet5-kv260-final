set root [file normalize [file join [file dirname [info script]] ..]]
set out_dir [file join $root build lenet_global_controller]
file mkdir $out_dir
cd $out_dir

exec xvlog -sv -d SIMULATION \
    [file join $root rtl lenet_global_controller.sv] \
    [file join $root tb tb_lenet_global_controller.sv]
exec xelab tb_lenet_global_controller -debug typical
exec xsim tb_lenet_global_controller -runall

set log_path [file join $out_dir xsim.log]
set fp [open $log_path r]
set text [read $fp]
close $fp
if {![string match "*LENET_GLOBAL_CONTROLLER TEST PASSED*" $text] ||
    [string match {*Fatal:*} $text] ||
    [string match {*ERROR:*} $text]} {
  error "Simulation failed; see $log_path"
}
puts "LENET_GLOBAL_CONTROLLER_PASS"
