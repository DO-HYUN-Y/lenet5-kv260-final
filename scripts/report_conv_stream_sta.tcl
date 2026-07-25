# Re-evaluate the routed integrated checkpoint after a constraint-only change.
open_checkpoint checkpoints/conv_stream_datapath_post_route.dcp
reset_timing
read_xdc constraints/conv_stream_datapath.xdc
report_timing_summary -delay_type min_max -check_timing_verbose -max_paths 10 \
  -file reports/conv_stream_datapath_impl_timing_summary.rpt
report_timing -delay_type max -max_paths 5 -sort_by group \
  -file reports/conv_stream_datapath_impl_timing_worst.rpt
check_timing -file reports/conv_stream_datapath_impl_check_timing.rpt
puts "CONV_STREAM_STA_REPORTED"
