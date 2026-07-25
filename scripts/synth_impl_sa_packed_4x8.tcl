# Non-project batch synth + impl + STA for sa_packed_4x8.sv (OOC block-level)
set part xck26-sfvc784-2LV-c
# Use all eight physical cores on the i9-9900K host.
set_param general.maxThreads 8

read_verilog -sv rtl/packed_pe.sv
read_verilog -sv rtl/sa_packed_4x8.sv
read_xdc constraints/sa_packed_4x8.xdc

synth_design -top sa_packed_4x8 -part $part -mode out_of_context
write_checkpoint -force checkpoints/sa_packed_4x8_post_synth.dcp
report_utilization -file reports/sa_packed_4x8_synth_utilization.rpt
report_timing_summary -file reports/sa_packed_4x8_synth_timing_summary.rpt

opt_design
place_design
route_design

write_checkpoint -force checkpoints/sa_packed_4x8_post_route.dcp
report_utilization -file reports/sa_packed_4x8_impl_utilization.rpt
report_timing_summary -delay_type min_max -check_timing_verbose -max_paths 10 -file reports/sa_packed_4x8_impl_timing_summary.rpt
report_timing -delay_type max -max_paths 5 -sort_by group -file reports/sa_packed_4x8_impl_timing_worst.rpt

puts "SYNTH_IMPL_STA_DONE"
