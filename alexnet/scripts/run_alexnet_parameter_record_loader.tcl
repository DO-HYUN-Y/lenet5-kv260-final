set alexnet_root [file normalize [file join [file dirname [info script]] ..]]
set out_dir [file join $alexnet_root build parameter_record_loader_sim]
file mkdir $out_dir
cd $out_dir

exec xvlog -sv -d SIMULATION \
    [file join $alexnet_root rtl dma alexnet_parameter_record_loader.sv] \
    [file join $alexnet_root tb tb_alexnet_parameter_record_loader.sv]
exec xelab tb_alexnet_parameter_record_loader -debug typical
exec xsim tb_alexnet_parameter_record_loader -runall

set log_path [file join $out_dir xsim.log]
set log_file [open $log_path r]
set log_text [read $log_file]
close $log_file
if {![string match "*ALEXNET_PARAMETER_RECORD_LOADER_TEST_PASSED*" $log_text] ||
    [string match "*Fatal:*" $log_text] ||
    [string match "*ERROR:*" $log_text]} {
  error "AlexNet parameter record loader simulation failed; see $log_path"
}
puts "ALEXNET_PARAMETER_RECORD_LOADER_SIM_PASS"
