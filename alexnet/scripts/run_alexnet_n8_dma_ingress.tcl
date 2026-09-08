set alexnet_root [file normalize [file join [file dirname [info script]] ..]]
set out_dir [file join $alexnet_root build n8_dma_ingress_sim]
file mkdir $out_dir

cd $out_dir
exec xvlog -sv -d SIMULATION \
    [file join $alexnet_root rtl dma alexnet_n8_dma_ingress.sv] \
    [file join $alexnet_root tb tb_alexnet_n8_dma_ingress.sv]
exec xelab tb_alexnet_n8_dma_ingress -debug typical
exec xsim tb_alexnet_n8_dma_ingress -runall

set log_path [file join $out_dir xsim.log]
set log_file [open $log_path r]
set log_text [read $log_file]
close $log_file
if {![string match "*ALEXNET_N8_DMA_INGRESS_TEST_PASSED*" $log_text] ||
    [string match "*Fatal:*" $log_text] ||
    [string match "*ERROR:*" $log_text]} {
  error "AlexNet N8 DMA ingress simulation failed; see $log_path"
}
puts "ALEXNET_N8_DMA_INGRESS_SIM_PASS"
