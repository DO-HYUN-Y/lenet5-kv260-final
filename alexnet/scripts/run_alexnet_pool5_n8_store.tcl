set alexnet_root [file normalize [file join [file dirname [info script]] ..]]
set out_dir [file join $alexnet_root build pool5_n8_store_sim]
file mkdir $out_dir
cd $out_dir

exec xvlog -sv -d SIMULATION \
    [file join $alexnet_root rtl memory alexnet_pool5_n8_store.sv] \
    [file join $alexnet_root tb tb_alexnet_pool5_n8_store.sv]
exec xelab tb_alexnet_pool5_n8_store -debug typical
exec xsim tb_alexnet_pool5_n8_store -runall

set log_path [file join $out_dir xsim.log]
set log_file [open $log_path r]
set log_text [read $log_file]
close $log_file
if {![string match "*ALEXNET_POOL5_N8_STORE_TEST_PASSED*" $log_text] ||
    [string match "*Fatal:*" $log_text] ||
    [string match "*ERROR:*" $log_text]} {
  error "AlexNet Pool5 N8 store simulation failed; see $log_path"
}
puts "ALEXNET_POOL5_N8_STORE_SIM_PASS"
