# Integrated conv stream datapath OOC synthesis, implementation, and reports.
set part xck26-sfvc784-2LV-c
# Use all eight physical cores on the i9-9900K host.
set_param general.maxThreads 8
read_verilog -sv rtl/packed_pe.sv
read_verilog -sv rtl/sa_packed_4x8.sv
read_verilog -sv rtl/skew_buf.sv
read_verilog -sv rtl/weight_loader.sv
read_verilog -sv rtl/window_gen.sv
read_verilog -sv rtl/column_result_router.sv
read_verilog -sv rtl/dual_lane_postprocess.sv
read_verilog -sv rtl/postprocess_array.sv
read_verilog -sv rtl/conv_stream_datapath.sv
read_xdc constraints/conv_stream_datapath.xdc

synth_design -top conv_stream_datapath -part $part -mode out_of_context
write_checkpoint -force checkpoints/conv_stream_datapath_post_synth.dcp
report_utilization -file reports/conv_stream_datapath_synth_utilization.rpt
report_timing_summary -delay_type min_max -file reports/conv_stream_datapath_synth_timing_summary.rpt
check_timing -file reports/conv_stream_datapath_synth_check_timing.rpt

opt_design
place_design
route_design
write_checkpoint -force checkpoints/conv_stream_datapath_post_route.dcp
report_utilization -file reports/conv_stream_datapath_impl_utilization.rpt
report_timing_summary -delay_type min_max -check_timing_verbose -max_paths 10 \
  -file reports/conv_stream_datapath_impl_timing_summary.rpt
report_timing -delay_type max -max_paths 5 -sort_by group \
  -file reports/conv_stream_datapath_impl_timing_worst.rpt
check_timing -file reports/conv_stream_datapath_impl_check_timing.rpt
report_drc -file reports/conv_stream_datapath_impl_drc.rpt
puts "CONV_STREAM_SYNTH_IMPL_DONE"
