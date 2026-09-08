set alexnet_root [file normalize [file join [file dirname [info script]] ..]]
set out_dir [file join $alexnet_root build pool5_fc6_flatten_reader_sim]
file mkdir $out_dir
cd $out_dir

exec xvlog -sv -d SIMULATION \
    [file join $alexnet_root rtl feeder alexnet_pool5_fc6_flatten_reader.sv] \
    [file join $alexnet_root tb tb_alexnet_pool5_fc6_flatten_reader.sv]
exec xelab tb_alexnet_pool5_fc6_flatten_reader -debug typical
exec xsim tb_alexnet_pool5_fc6_flatten_reader -runall

set log_path [file join $out_dir xsim.log]
set log_file [open $log_path r]
set log_text [read $log_file]
close $log_file
if {![string match "*ALEXNET_POOL5_FC6_FLATTEN_TEST_PASSED*" $log_text] ||
    [string match "*Fatal:*" $log_text] ||
    [string match "*ERROR:*" $log_text]} {
  error "AlexNet Pool5-to-FC6 flatten simulation failed; see $log_path"
}
puts "ALEXNET_POOL5_FC6_FLATTEN_SIM_PASS"
