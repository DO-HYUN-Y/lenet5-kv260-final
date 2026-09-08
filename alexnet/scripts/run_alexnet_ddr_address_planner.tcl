set alexnet_root [file normalize [file join [file dirname [info script]] ..]]
set out_dir [file join $alexnet_root build ddr_address_planner_sim]
file mkdir $out_dir
cd $out_dir

exec xvlog -sv -d SIMULATION \
    [file join $alexnet_root rtl control alexnet_ddr_address_planner.sv] \
    [file join $alexnet_root tb tb_alexnet_ddr_address_planner.sv]
exec xelab tb_alexnet_ddr_address_planner -debug typical
exec xsim tb_alexnet_ddr_address_planner -runall

set log_path [file join $out_dir xsim.log]
set log_file [open $log_path r]
set log_text [read $log_file]
close $log_file
if {![string match "*ALEXNET_DDR_ADDRESS_PLANNER_TEST_PASSED*" $log_text] ||
    [string match "*Fatal:*" $log_text] ||
    [string match "*ERROR:*" $log_text]} {
  error "AlexNet DDR address planner simulation failed; see $log_path"
}
puts "ALEXNET_DDR_ADDRESS_PLANNER_SIM_PASS"
