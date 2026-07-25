connect -url tcp:localhost:3121

puts "KV260_XSCT_TARGETS_BEGIN"
puts [targets]
puts "KV260_XSCT_TARGETS_END"

targets -set -filter {name == "PSU"}
set id_value [mrd -force -value 0xa0000000]
set status_value [mrd -force -value 0xa0000008]
set dma_mm2s_status [mrd -force -value 0xa0010004]
set dma_s2mm_status [mrd -force -value 0xa0010034]

puts [format "KV260_ACCEL_ID=0x%08x" $id_value]
puts [format "KV260_ACCEL_STATUS=0x%08x" $status_value]
puts [format "KV260_DMA_MM2S_STATUS=0x%08x" $dma_mm2s_status]
puts [format "KV260_DMA_S2MM_STATUS=0x%08x" $dma_s2mm_status]

disconnect
exit
