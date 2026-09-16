set alexnet_root [file normalize [file join [file dirname [info script]] ..]]
set out_dir [file join $alexnet_root build m8n128_tile_payload_sim]
file mkdir $out_dir
cd $out_dir

exec xvlog -sv \
    [file join $alexnet_root rtl packed_mac alexnet_packed_pe.sv] \
    [file join $alexnet_root rtl sa alexnet_sa_m4n8.sv] \
    [file join $alexnet_root rtl sa alexnet_sa_m8n128_dynamic.sv] \
    [file join $alexnet_root rtl postprocess alexnet_n8_requant.sv] \
    [file join $alexnet_root rtl postprocess alexnet_m8n8_parallel_requant.sv] \
    [file join $alexnet_root rtl integration alexnet_m8n128_tile_payload.sv] \
    [file join $alexnet_root tb tb_alexnet_m8n128_tile_payload.sv]
exec xelab tb_alexnet_m8n128_tile_payload -debug typical
exec xsim tb_alexnet_m8n128_tile_payload -runall

set log_path [file join $out_dir xsim.log]
set log_file [open $log_path r]
set log_text [read $log_file]
close $log_file
if {![string match "*ALEXNET_M8N128_TILE_PAYLOAD_TEST_PASSED*" $log_text] ||
    [string match "*Fatal:*" $log_text]} {
  error "AlexNet M8N128 tile payload simulation failed; see $log_path"
}
puts "ALEXNET_M8N128_TILE_PAYLOAD_SIM_PASS"
