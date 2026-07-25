# Non-project batch synth + impl + STA for window_gen.sv (OOC block-level)
set part xck26-sfvc784-2LV-c
# Use all eight physical cores on the i9-9900K host.
set_param general.maxThreads 8

read_verilog -sv rtl/window_gen.sv
read_xdc constraints/window_gen.xdc

synth_design -top window_gen -part $part -mode out_of_context
write_checkpoint -force checkpoints/window_gen_post_synth.dcp
report_utilization -file reports/window_gen_synth_utilization.rpt
report_timing_summary -file reports/window_gen_synth_timing_summary.rpt

opt_design
place_design
route_design

write_checkpoint -force checkpoints/window_gen_post_route.dcp
report_utilization -file reports/window_gen_impl_utilization.rpt
report_timing_summary -delay_type min_max -check_timing_verbose -max_paths 10 -file reports/window_gen_impl_timing_summary.rpt
report_timing -delay_type max -max_paths 5 -sort_by group -file reports/window_gen_impl_timing_worst.rpt

puts "SYNTH_IMPL_STA_DONE"
