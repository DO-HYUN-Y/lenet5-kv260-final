set alexnet_root [file normalize [file join [file dirname [info script]] ..]]
set out_dir [file join $alexnet_root build graph_compute_orchestrator_sim]
file mkdir $out_dir
cd $out_dir

exec xvlog -sv -d SIMULATION \
    [file join $alexnet_root rtl control alexnet_graph_controller.sv] \
    [file join $alexnet_root rtl control alexnet_conv_layer_controller.sv] \
    [file join $alexnet_root rtl integration alexnet_graph_compute_orchestrator.sv] \
    [file join $alexnet_root tb tb_alexnet_graph_compute_orchestrator.sv]
exec xelab tb_alexnet_graph_compute_orchestrator -debug typical
exec xsim tb_alexnet_graph_compute_orchestrator -runall

set log_path [file join $out_dir xsim.log]
set log_file [open $log_path r]
set log_text [read $log_file]
close $log_file
if {![string match "*ALEXNET_GRAPH_COMPUTE_ORCHESTRATOR_TEST_PASSED*" $log_text] ||
    [string match "*Fatal:*" $log_text] ||
    [string match "*ERROR:*" $log_text]} {
  error "AlexNet graph/compute orchestrator simulation failed; see $log_path"
}
puts "ALEXNET_GRAPH_COMPUTE_ORCHESTRATOR_SIM_PASS"
