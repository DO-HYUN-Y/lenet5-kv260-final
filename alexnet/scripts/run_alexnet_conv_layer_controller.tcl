set alexnet_root [file normalize [file join [file dirname [info script]] ..]]
set out_dir [file join $alexnet_root build conv_layer_controller_sim]
file mkdir $out_dir
cd $out_dir

exec xvlog -sv -d SIMULATION \
    [file join $alexnet_root rtl control alexnet_conv_layer_controller.sv] \
    [file join $alexnet_root tb tb_alexnet_conv_layer_controller.sv]
exec xelab tb_alexnet_conv_layer_controller -debug typical
exec xsim tb_alexnet_conv_layer_controller -runall

set log_path [file join $out_dir xsim.log]
set log_file [open $log_path r]
set log_text [read $log_file]
close $log_file
if {![string match "*ALEXNET_CONV_LAYER_CONTROLLER_TEST_PASSED*" $log_text] ||
    [string match "*Fatal:*" $log_text] ||
    [string match "*ERROR:*" $log_text]} {
  error "AlexNet Conv layer-controller simulation failed; see $log_path"
}
puts "ALEXNET_CONV_LAYER_CONTROLLER_SIM_PASS"
