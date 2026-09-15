set alexnet_root [file normalize [file join [file dirname [info script]] ..]]
set out_dir [file join $alexnet_root build m16_patch_feeder_bridge_sim]
file mkdir $out_dir
cd $out_dir

exec xvlog -sv \
    [file join $alexnet_root rtl feeder alexnet_n8_rs_m4_feeder.sv] \
    [file join $alexnet_root rtl feeder alexnet_n8_rs_m16_feeder.sv] \
    [file join $alexnet_root rtl memory alexnet_m16_patch_pingpong.sv] \
    [file join $alexnet_root rtl integration alexnet_m16_patch_feeder_bridge.sv] \
    [file join $alexnet_root tb tb_alexnet_m16_patch_feeder_bridge.sv]
exec xelab tb_alexnet_m16_patch_feeder_bridge
exec xsim tb_alexnet_m16_patch_feeder_bridge -runall

set log_path [file join $out_dir xsim.log]
set log_file [open $log_path r]
set log_text [read $log_file]
close $log_file
if {![string match "*ALEXNET_M16_PATCH_FEEDER_BRIDGE_TEST_PASSED*" $log_text] ||
    [string match "*Fatal:*" $log_text]} {
  error "AlexNet M16 patch feeder bridge simulation failed; see $log_path"
}
puts "ALEXNET_M16_PATCH_FEEDER_BRIDGE_SIM_PASS"
