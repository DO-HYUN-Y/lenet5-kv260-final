# Run DRC on the already placed-and-routed integrated checkpoint.
open_checkpoint checkpoints/conv_stream_datapath_post_route.dcp
report_drc -file reports/conv_stream_datapath_impl_drc.rpt
puts "CONV_STREAM_DRC_DONE"
