# Non-project batch synth + impl + STA for skew_buf.sv (OOC block-level)
set part xck26-sfvc784-2LV-c
# Use all eight physical cores on the i9-9900K host.
set_param general.maxThreads 8

read_verilog -sv rtl/skew_buf.sv
read_xdc constraints/skew_buf.xdc

synth_design -top skew_buf -part $part -mode out_of_context
write_checkpoint -force checkpoints/skew_buf_post_synth.dcp
report_utilization -file reports/skew_buf_synth_utilization.rpt
report_timing_summary -file reports/skew_buf_synth_timing_summary.rpt

opt_design
place_design
route_design

write_checkpoint -force checkpoints/skew_buf_post_route.dcp
report_utilization -file reports/skew_buf_impl_utilization.rpt
report_timing_summary -delay_type min_max -check_timing_verbose -max_paths 10 -file reports/skew_buf_impl_timing_summary.rpt
report_timing -delay_type max -max_paths 5 -sort_by group -file reports/skew_buf_impl_timing_worst.rpt

puts "SYNTH_IMPL_STA_DONE"
