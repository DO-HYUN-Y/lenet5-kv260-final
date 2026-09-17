set alexnet_root [file normalize [file join [file dirname [info script]] ..]]
set repo_root [file normalize [file join $alexnet_root ..]]
set out_dir [file join $alexnet_root build m8n128_trained_layer_tiles_sim]
set vector_root [file join $alexnet_root cpp build-release \
    full_graph_pattern_v1 rtl_tiles]
if {![file isdirectory $vector_root]} {
  error "trained layer vectors not found; run python3 alexnet/cpp/tools/verify_board_full_graph_golden.py --output-dir alexnet/cpp/build-release/full_graph_pattern_v1"
}
file mkdir $out_dir
cd $out_dir

exec xvlog -sv \
    [file join $alexnet_root rtl packed_mac alexnet_packed_pe.sv] \
    [file join $alexnet_root rtl sa alexnet_sa_m4n8.sv] \
    [file join $alexnet_root rtl sa alexnet_sa_m8n128_dynamic.sv] \
    [file join $alexnet_root rtl postprocess alexnet_n8_requant.sv] \
    [file join $alexnet_root rtl postprocess alexnet_m8n8_parallel_requant.sv] \
    [file join $alexnet_root rtl integration alexnet_m8n128_tile_payload.sv] \
    [file join $alexnet_root tb tb_alexnet_m8n128_trained_layer_tiles.sv]
exec xelab tb_alexnet_m8n128_trained_layer_tiles
exec xsim tb_alexnet_m8n128_trained_layer_tiles -runall \
    -testplusarg "VECTOR_ROOT=$vector_root"

set log_path [file join $out_dir xsim.log]
set log_file [open $log_path r]
set log_text [read $log_file]
close $log_file
if {![string match \
        "*ALEXNET_M8N128_TRAINED_LAYER_TILES_TEST_PASSED*" $log_text] ||
    [string match "*Fatal:*" $log_text]} {
  error "AlexNet trained layer tile simulation failed; see $log_path"
}
puts "ALEXNET_M8N128_TRAINED_LAYER_TILES_SIM_PASS"
