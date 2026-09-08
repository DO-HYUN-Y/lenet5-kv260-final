set alexnet_root [file normalize [file join [file dirname [info script]] ..]]
set out_dir [file join $alexnet_root build dma_chunk_scheduler_sim]
file mkdir $out_dir

cd $out_dir
exec xvlog -sv -d SIMULATION \
    [file join $alexnet_root rtl control alexnet_dma_chunk_scheduler.sv] \
    [file join $alexnet_root tb tb_alexnet_dma_chunk_scheduler.sv]
exec xelab tb_alexnet_dma_chunk_scheduler -debug typical
exec xsim tb_alexnet_dma_chunk_scheduler -runall

set log_path [file join $out_dir xsim.log]
set log_file [open $log_path r]
set log_text [read $log_file]
close $log_file
if {![string match "*ALEXNET_DMA_CHUNK_SCHEDULER_TEST_PASSED*" $log_text] ||
    [string match "*Fatal:*" $log_text] ||
    [string match "*ERROR:*" $log_text]} {
  error "AlexNet DMA chunk scheduler simulation failed; see $log_path"
}
puts "ALEXNET_DMA_CHUNK_SCHEDULER_SIM_PASS"
