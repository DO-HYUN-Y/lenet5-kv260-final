set_param general.maxThreads 8
set alexnet_root [file normalize [file join [file dirname [info script]] ..]]
set out_dir [file join $alexnet_root build m8n126_compute_island_ooc]
file delete -force $out_dir
file mkdir $out_dir

read_verilog -sv [list \
    [file join $alexnet_root rtl packed_mac alexnet_packed_pe.sv] \
    [file join $alexnet_root rtl sa alexnet_sa_m4n8.sv] \
    [file join $alexnet_root rtl sa alexnet_sa_m8n128_dynamic.sv] \
    [file join $alexnet_root rtl feeder alexnet_n8_rs_m4_feeder.sv] \
    [file join $alexnet_root rtl feeder alexnet_n8_rs_m16_feeder.sv] \
    [file join $alexnet_root rtl memory alexnet_n128_weight_pingpong.sv] \
    [file join $alexnet_root rtl postprocess alexnet_n8_requant.sv] \
    [file join $alexnet_root rtl postprocess alexnet_m8n8_parallel_requant.sv] \
    [file join $alexnet_root rtl integration \
        alexnet_m8n128_compute_island.sv]]
synth_design -top alexnet_m8n128_compute_island \
    -part xck26-sfvc784-2LV-c -mode out_of_context \
    -directive PerformanceOptimized
create_clock -name clk -period 5.000 [get_ports clk]
report_utilization -hierarchical -file [file join $out_dir utilization.rpt]
report_timing_summary -delay_type min_max -report_unconstrained \
    -file [file join $out_dir timing_summary.rpt]
report_timing -delay_type max -max_paths 20 -nworst 2 \
    -file [file join $out_dir timing_paths.rpt]
write_checkpoint -force [file join $out_dir post_synth.dcp]

set dsp_cells [get_cells -hierarchical -filter {REF_NAME == DSP48E2}]
set sa_dsp_cells [get_cells -hierarchical -filter {
    REF_NAME == DSP48E2 && NAME =~ *u_dynamic_sa*
}]
if {[llength $dsp_cells] != 576 || [llength $sa_dsp_cells] != 512} {
    error "OOC DSP contract failed: total=[llength $dsp_cells] SA=[llength $sa_dsp_cells]"
}
puts "ALEXNET_M8N126_COMPUTE_ISLAND_OOC_SYNTH_PASS total_dsp=576 sa_dsp=512"
exit
