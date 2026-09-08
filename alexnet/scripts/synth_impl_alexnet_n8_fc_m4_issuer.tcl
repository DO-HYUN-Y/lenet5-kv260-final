set part xck26-sfvc784-2LV-c
set frequency_mhz 200
set_param general.maxThreads 8

set alexnet_root [file normalize [file join [file dirname [info script]] ..]]
set repo_root [file normalize [file join $alexnet_root ..]]
set rtl_source \
    [file join $alexnet_root rtl feeder alexnet_n8_fc_m4_issuer.sv]
set xdc_source \
    [file join $alexnet_root constraints alexnet_n8_fc_m4_issuer.xdc]
set out_dir [file join $alexnet_root build n8_fc_m4_issuer_ooc 200mhz]
set report_dir [file join $alexnet_root reports n8_fc_m4_issuer 200mhz]
file mkdir $out_dir
file mkdir $report_dir
cd $out_dir

read_verilog -sv $rtl_source
read_xdc $xdc_source
synth_design -top alexnet_n8_fc_m4_issuer -part $part \
    -mode out_of_context
write_checkpoint -force [file join $out_dir post_synth.dcp]
report_utilization -file [file join $report_dir synth_utilization.rpt]
report_utilization -hierarchical -file \
    [file join $report_dir synth_utilization_hierarchical.rpt]
report_timing_summary -delay_type min_max -check_timing_verbose \
    -file [file join $report_dir synth_timing_summary.rpt]
report_control_sets -verbose -file \
    [file join $report_dir synth_control_sets.rpt]

opt_design
place_design
phys_opt_design
route_design
write_checkpoint -force [file join $out_dir post_route.dcp]
report_utilization -file [file join $report_dir impl_utilization.rpt]
report_utilization -hierarchical -file \
    [file join $report_dir impl_utilization_hierarchical.rpt]
report_timing_summary -delay_type min_max -check_timing_verbose -max_paths 20 \
    -file [file join $report_dir impl_timing_summary.rpt]
report_timing -delay_type max -max_paths 20 -sort_by group \
    -file [file join $report_dir worst_setup.rpt]
report_timing -delay_type min -max_paths 20 -sort_by group \
    -file [file join $report_dir worst_hold.rpt]
report_high_fanout_nets -fanout_greater_than 16 -max_nets 100 \
    -file [file join $report_dir high_fanout.rpt]
report_route_status -file [file join $report_dir route_status.rpt]
report_control_sets -verbose -file \
    [file join $report_dir impl_control_sets.rpt]
report_drc -file [file join $report_dir drc.rpt]

set metadata_file [open [file join $report_dir run_metadata.txt] w]
puts $metadata_file "design=alexnet_n8_fc_m4_issuer"
puts $metadata_file "activation_layout=k_block,m,k_lane"
puts $metadata_file "activation_word_bits=64"
puts $metadata_file "activation_block_words_max=4"
puts $metadata_file "logical_shape=m4xn8"
puts $metadata_file "weight_layout=k,n_lane"
puts $metadata_file "one_weight_replay_per_descriptor=true"
puts $metadata_file "k_chunking_owned_by_parent=true"
puts $metadata_file "pe_rtl_changed=false"
puts $metadata_file "sa_rtl_changed=false"
puts $metadata_file "git_commit=[exec git -C $repo_root rev-parse HEAD]"
puts $metadata_file "vivado=[version -short]"
puts $metadata_file "part=$part"
puts $metadata_file "frequency_mhz=$frequency_mhz"
puts $metadata_file "clock_period_ns=5.000000"
puts $metadata_file \
    "rtl_sha256=[lindex [exec sha256sum $rtl_source] 0]"
puts $metadata_file \
    "xdc_sha256=[lindex [exec sha256sum $xdc_source] 0]"
close $metadata_file
puts "ALEXNET_N8_FC_M4_ISSUER_OOC_DONE frequency_mhz=$frequency_mhz"
