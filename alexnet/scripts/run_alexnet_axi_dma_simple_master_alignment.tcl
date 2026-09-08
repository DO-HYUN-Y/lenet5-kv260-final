set alexnet_root [file normalize [file join [file dirname [info script]] ..]]
set repo_root [file normalize [file join $alexnet_root ..]]
set out_dir [file join $alexnet_root build axi_dma_simple_master_alignment_sim]
file mkdir $out_dir
cd $out_dir

exec xvlog -sv -d SIMULATION \
    [file join $repo_root rtl axi_dma_simple_master.sv] \
    [file join $alexnet_root tb tb_alexnet_axi_dma_simple_master_alignment.sv]
exec xelab tb_alexnet_axi_dma_simple_master_alignment -debug typical
exec xsim tb_alexnet_axi_dma_simple_master_alignment -runall

set log_path [file join $out_dir xsim.log]
set log_file [open $log_path r]
set log_text [read $log_file]
close $log_file
if {![string match "*ALEXNET_AXI_DMA_ALIGNMENT_TEST_PASSED*" $log_text] ||
    [string match "*Fatal:*" $log_text] ||
    [string match "*ERROR:*" $log_text]} {
  error "AlexNet AXI DMA alignment simulation failed; see $log_path"
}
puts "ALEXNET_AXI_DMA_ALIGNMENT_SIM_PASS"
