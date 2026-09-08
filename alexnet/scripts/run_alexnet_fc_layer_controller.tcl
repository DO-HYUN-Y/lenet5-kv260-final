set alexnet_root [file normalize [file join [file dirname [info script]] ..]]
set out_dir [file join $alexnet_root build fc_layer_controller_sim]
file mkdir $out_dir
cd $out_dir
exec xvlog -sv -d SIMULATION \
    [file join $alexnet_root rtl control alexnet_fc_layer_controller.sv] \
    [file join $alexnet_root tb tb_alexnet_fc_layer_controller.sv]
exec xelab tb_alexnet_fc_layer_controller -debug typical
exec xsim tb_alexnet_fc_layer_controller -runall
set f [open [file join $out_dir xsim.log] r]
set log_text [read $f]
close $f
if {![string match "*ALEXNET_FC_LAYER_CONTROLLER_TEST_PASSED*" $log_text] ||
    [string match "*Fatal:*" $log_text] || [string match "*ERROR:*" $log_text]} {
  error "FC layer controller simulation failed; see $out_dir/xsim.log"
}
puts "ALEXNET_FC_LAYER_CONTROLLER_SIM_PASS"
