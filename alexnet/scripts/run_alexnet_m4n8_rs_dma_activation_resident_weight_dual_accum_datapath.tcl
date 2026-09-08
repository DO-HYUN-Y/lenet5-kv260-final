set alexnet_root [file normalize [file join [file dirname [info script]] ..]]
set out_dir [file join $alexnet_root build \
    m4n8_rs_dma_activation_resident_weight_dual_accum_datapath_sim]
file mkdir $out_dir

cd $out_dir
exec xvlog -sv -d SIMULATION \
    [file join $alexnet_root rtl packed_mac alexnet_packed_pe.sv] \
    [file join $alexnet_root rtl sa alexnet_sa_m4n8.sv] \
    [file join $alexnet_root rtl result alexnet_m4n8_result_scanner.sv] \
    [file join $alexnet_root rtl memory \
        alexnet_n8_int32_partial_sum_bank.sv] \
    [file join $alexnet_root rtl memory \
        alexnet_n8_int32_partial_sum_bank_pair.sv] \
    [file join $alexnet_root rtl postprocess alexnet_n8_requant.sv] \
    [file join $alexnet_root rtl result alexnet_n8_output_router.sv] \
    [file join $alexnet_root rtl integration \
        alexnet_m4n8_n8_dual_accum_output_slice.sv] \
    [file join $alexnet_root rtl integration \
        alexnet_m4n8_dual_accum_base_datapath.sv] \
    [file join $alexnet_root rtl feeder alexnet_n8_rs_m4_feeder.sv] \
    [file join $alexnet_root rtl control \
        alexnet_m4n8_rs_issue_controller.sv] \
    [file join $alexnet_root rtl memory alexnet_n8_weight_tile_bank.sv] \
    [file join $alexnet_root rtl integration \
        alexnet_m4n8_rs_resident_weight_dual_accum_datapath.sv] \
    [file join $alexnet_root rtl memory alexnet_n8_activation_bank.sv] \
    [file join $alexnet_root rtl memory alexnet_n8_activation_pingpong.sv] \
    [file join $alexnet_root rtl memory \
        alexnet_n8_activation_dual_segment_pingpong.sv] \
    [file join $alexnet_root rtl integration \
        alexnet_m4n8_rs_activation_resident_weight_dual_accum_datapath.sv] \
    [file join $alexnet_root rtl dma alexnet_n8_dma_ingress.sv] \
    [file join $alexnet_root rtl integration \
        alexnet_m4n8_rs_dma_activation_resident_weight_dual_accum_datapath.sv] \
    [file join $alexnet_root tb \
        tb_alexnet_m4n8_rs_dma_activation_resident_weight_dual_accum_datapath.sv]
exec xelab \
    tb_alexnet_m4n8_rs_dma_activation_resident_weight_dual_accum_datapath \
    -debug typical
exec xsim \
    tb_alexnet_m4n8_rs_dma_activation_resident_weight_dual_accum_datapath \
    -runall

set log_path [file join $out_dir xsim.log]
set log_file [open $log_path r]
set log_text [read $log_file]
close $log_file
if {![string match \
        "*ALEXNET_M4N8_RS_DMA_ACTIVATION_RESIDENT_WEIGHT_DUAL_ACCUM_DATAPATH_TEST_PASSED*" \
        $log_text] ||
    [string match "*Fatal:*" $log_text] ||
    [string match "*ERROR:*" $log_text]} {
  error "AlexNet DMA-fed RS simulation failed; see $log_path"
}
puts "ALEXNET_M4N8_RS_DMA_ACTIVATION_RESIDENT_WEIGHT_DUAL_ACCUM_DATAPATH_SIM_PASS"
