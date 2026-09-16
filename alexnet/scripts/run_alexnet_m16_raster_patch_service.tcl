set alexnet_root [file normalize [file join [file dirname [info script]] ..]]
set out_dir [file join $alexnet_root build m16_raster_patch_service_sim]
file mkdir $out_dir
cd $out_dir

exec xvlog -sv \
    [file join $alexnet_root rtl dma alexnet_axis128_to_n8_unpacker.sv] \
    [file join $alexnet_root rtl feeder alexnet_n8_rs_m4_feeder.sv] \
    [file join $alexnet_root rtl feeder alexnet_n8_rs_m16_feeder.sv] \
    [file join $alexnet_root rtl feeder alexnet_n8_rs_m16_xmod4_feeder.sv] \
    [file join $alexnet_root rtl memory alexnet_m16_patch_pingpong.sv] \
    [file join $alexnet_root rtl integration alexnet_m16_patch_feeder_bridge.sv] \
    [file join $alexnet_root rtl integration alexnet_m16_raster_patch_service.sv] \
    [file join $alexnet_root tb tb_alexnet_m16_raster_patch_service.sv]
exec xelab tb_alexnet_m16_raster_patch_service
exec xsim tb_alexnet_m16_raster_patch_service -runall

set log_path [file join $out_dir xsim.log]
set log_file [open $log_path r]
set log_text [read $log_file]
close $log_file
if {![string match "*ALEXNET_M16_RASTER_PATCH_SERVICE_TEST_PASSED*" $log_text] ||
    [string match "*Fatal:*" $log_text]} {
  error "AlexNet M16 raster patch service simulation failed; see $log_path"
}
puts "ALEXNET_M16_RASTER_PATCH_SERVICE_SIM_PASS"
