set alexnet_root [file normalize [file join [file dirname [info script]] ..]]
set out_dir [file join $alexnet_root build conv_fc_data_service_sim]
file mkdir $out_dir
cd $out_dir

exec xvlog -sv -d SIMULATION \
    [file join $alexnet_root rtl dma alexnet_axis128_to_n8_unpacker.sv] \
    [file join $alexnet_root rtl dma alexnet_n8_to_axis128_packer.sv] \
    [file join $alexnet_root rtl pool alexnet_n8_maxpool3x3.sv] \
    [file join $alexnet_root rtl feeder alexnet_pool5_fc6_flatten_reader.sv] \
    [file join $alexnet_root rtl memory alexnet_pool5_n8_store.sv] \
    [file join $alexnet_root rtl integration alexnet_conv_result_pool_service.sv] \
    [file join $alexnet_root rtl integration alexnet_fc6_flatten_injector.sv] \
    [file join $alexnet_root rtl integration alexnet_conv_fc_data_service.sv] \
    [file join $alexnet_root tb tb_alexnet_conv_fc_data_service.sv]
exec xelab tb_alexnet_conv_fc_data_service -debug typical
exec xsim tb_alexnet_conv_fc_data_service -runall

set log_path [file join $out_dir xsim.log]
set log_file [open $log_path r]
set log_text [read $log_file]
close $log_file
if {![string match "*ALEXNET_CONV_FC_DATA_SERVICE_TEST_PASSED*" $log_text] ||
    [string match "*Fatal:*" $log_text] ||
    [string match "*ERROR:*" $log_text]} {
  error "AlexNet Conv/FC data service simulation failed; see $log_path"
}
puts "ALEXNET_CONV_FC_DATA_SERVICE_SIM_PASS"
