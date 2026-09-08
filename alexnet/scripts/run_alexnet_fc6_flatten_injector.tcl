set alexnet_root [file normalize [file join [file dirname [info script]] ..]]
set out_dir [file join $alexnet_root build fc6_flatten_injector_sim]
file mkdir $out_dir
cd $out_dir

exec xvlog -sv -d SIMULATION \
    [file join $alexnet_root rtl dma alexnet_n8_to_axis128_packer.sv] \
    [file join $alexnet_root rtl feeder alexnet_pool5_fc6_flatten_reader.sv] \
    [file join $alexnet_root rtl integration alexnet_fc6_flatten_injector.sv] \
    [file join $alexnet_root tb tb_alexnet_fc6_flatten_injector.sv]
exec xelab tb_alexnet_fc6_flatten_injector -debug typical
exec xsim tb_alexnet_fc6_flatten_injector -runall

set log_path [file join $out_dir xsim.log]
set log_file [open $log_path r]
set log_text [read $log_file]
close $log_file
if {![string match "*ALEXNET_FC6_FLATTEN_INJECTOR_TEST_PASSED*" $log_text] ||
    [string match "*Fatal:*" $log_text] ||
    [string match "*ERROR:*" $log_text]} {
  error "AlexNet FC6 flatten injector simulation failed; see $log_path"
}
puts "ALEXNET_FC6_FLATTEN_INJECTOR_SIM_PASS"
