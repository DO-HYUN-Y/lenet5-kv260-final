source [file join [file dirname [info script]] shared_compute_sources.tcl]
set part xck26-sfvc784-2LV-c
set design_top alexnet_parameter_record_loader
set_param general.maxThreads 8
set out_dir [file join $alexnet_root build parameter_record_loader_ooc 200mhz]
set report_dir [file join $alexnet_root reports parameter_record_loader 200mhz]
file mkdir $out_dir
file mkdir $report_dir
cd $out_dir
foreach rtl_source $rtl_sources { read_verilog -sv $rtl_source }
set xdc_source [file join $alexnet_root constraints $design_top.xdc]
read_xdc $xdc_source
synth_design -top $design_top -part $part -mode out_of_context
set dsp_cells [get_cells -hierarchical -filter {REF_NAME == DSP48E2}]
set bram_cells [get_cells -hierarchical -filter {REF_NAME == RAMB36E2}]
if {[llength $dsp_cells] != 0 || [llength $bram_cells] != 0} {
  error "parameter record loader must consume zero DSP and BRAM"
}
write_checkpoint -force [file join $out_dir post_synth.dcp]
report_utilization -file [file join $report_dir synth_utilization.rpt]
report_timing_summary -delay_type min_max -check_timing_verbose \
    -file [file join $report_dir synth_timing_summary.rpt]
opt_design
place_design
phys_opt_design
route_design
write_checkpoint -force [file join $out_dir post_route.dcp]
report_utilization -file [file join $report_dir impl_utilization.rpt]
report_timing_summary -delay_type min_max -check_timing_verbose -max_paths 20 \
    -file [file join $report_dir impl_timing_summary.rpt]
report_route_status -file [file join $report_dir route_status.rpt]
report_drc -file [file join $report_dir drc.rpt]
set f [open [file join $report_dir run_metadata.txt] w]
puts $f "design=$design_top"
puts $f "boundary=axis128_parameter_tile_to_eight_lane_requant_records"
puts $f "frequency_mhz=200"
puts $f "clock_period_ns=5.000"
puts $f "part=$part"
puts $f "vivado=[version -short]"
puts $f "record_format=little_endian_<iiBB6x>"
puts $f "records_per_tile=8"
puts $f "bytes_per_record=16"
puts $f "synth_dsp48e2=[llength $dsp_cells]"
puts $f "synth_bram36e2=[llength $bram_cells]"
puts $f "rtl_sha256=[lindex [exec sha256sum [file join $alexnet_root rtl dma alexnet_parameter_record_loader.sv]] 0]"
puts $f "xdc_sha256=[lindex [exec sha256sum $xdc_source] 0]"
close $f
puts "ALEXNET_PARAMETER_RECORD_LOADER_OOC_DONE frequency_mhz=200"
