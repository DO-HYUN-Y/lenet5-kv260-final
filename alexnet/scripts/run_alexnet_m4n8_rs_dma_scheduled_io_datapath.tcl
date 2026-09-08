set alexnet_root [file normalize [file join [file dirname [info script]] ..]]
set out_dir [file join $alexnet_root build \
    m4n8_rs_dma_scheduled_io_datapath_sim]
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
    [file join $alexnet_root rtl dma alexnet_n8_dma_result_egress.sv] \
    [file join $alexnet_root rtl integration \
        alexnet_m4n8_rs_dma_io_activation_resident_weight_dual_accum_datapath.sv] \
    [file join $alexnet_root rtl control alexnet_dma_chunk_scheduler.sv] \
    [file join $alexnet_root rtl integration \
        alexnet_m4n8_rs_dma_scheduled_io_datapath.sv] \
    [file join $alexnet_root tb \
        tb_alexnet_m4n8_rs_dma_scheduled_io_datapath.sv]
exec xelab tb_alexnet_m4n8_rs_dma_scheduled_io_datapath -debug typical
exec xsim tb_alexnet_m4n8_rs_dma_scheduled_io_datapath -runall
file copy -force xsim.log xsim_conv2.log

# Recompile the same end-to-end DMA/compute test with Conv3's 169-word
# activation geometry. This guards the replicated short-tensor path used by
# Conv3, Conv4, and Conv5 while retaining the original 729-word coverage.
exec xvlog -sv -d SIMULATION -d CONV3_GEOMETRY \
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
    [file join $alexnet_root rtl dma alexnet_n8_dma_result_egress.sv] \
    [file join $alexnet_root rtl integration \
        alexnet_m4n8_rs_dma_io_activation_resident_weight_dual_accum_datapath.sv] \
    [file join $alexnet_root rtl control alexnet_dma_chunk_scheduler.sv] \
    [file join $alexnet_root rtl integration \
        alexnet_m4n8_rs_dma_scheduled_io_datapath.sv] \
    [file join $alexnet_root tb \
        tb_alexnet_m4n8_rs_dma_scheduled_io_datapath.sv]
exec xelab tb_alexnet_m4n8_rs_dma_scheduled_io_datapath \
    -s tb_alexnet_m4n8_rs_dma_scheduled_io_datapath_conv3 -debug typical
exec xsim tb_alexnet_m4n8_rs_dma_scheduled_io_datapath_conv3 -runall

set log_path [file join $out_dir xsim.log]
set log_file [open $log_path r]
set log_text [read $log_file]
close $log_file
set conv2_log_file [open [file join $out_dir xsim_conv2.log] r]
set conv2_log_text [read $conv2_log_file]
close $conv2_log_file
if {![string match \
        "*ALEXNET_M4N8_RS_DMA_SCHEDULED_IO_DATAPATH_TEST_PASSED*" \
        $conv2_log_text] ||
    [string match "*Fatal:*" $conv2_log_text] ||
    [string match "*ERROR:*" $conv2_log_text] ||
    ![string match \
        "*ALEXNET_M4N8_RS_DMA_SCHEDULED_IO_DATAPATH_TEST_PASSED*" \
        $log_text] ||
    [string match "*Fatal:*" $log_text] ||
    [string match "*ERROR:*" $log_text]} {
  error "AlexNet scheduled full DMA-loop simulation failed; see $log_path"
}
puts "ALEXNET_M4N8_RS_DMA_SCHEDULED_IO_DATAPATH_SIM_PASS geometries=conv2,conv3"
