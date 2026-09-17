set alexnet_root [file normalize [file join [file dirname [info script]] ..]]
set repo_root [file normalize [file join $alexnet_root ..]]
set out_dir [file join $alexnet_root build m8n126_graph_top_conv1_smoke_sim]
set vector_root [file join $alexnet_root cpp build-release \
    full_graph_pattern_v1 top_conv1_smoke]
if {![file isdirectory $vector_root]} {
  error "trained top vectors not found; run the full-graph golden verifier with --output-dir"
}
file mkdir $out_dir
cd $out_dir

set rtl_sources [lsort [glob [file join $alexnet_root rtl * *.sv]]]
lappend rtl_sources [file join $repo_root rtl axi_dma_simple_master.sv]
lappend rtl_sources [file join $alexnet_root tb \
    tb_alexnet_m8n126_graph_top_trained_conv1_smoke.sv]

exec xvlog -sv -d SIMULATION {*}$rtl_sources
exec xelab tb_alexnet_m8n126_graph_top_trained_conv1_smoke
exec xsim tb_alexnet_m8n126_graph_top_trained_conv1_smoke -runall \
    -testplusarg "VECTOR_ROOT=$vector_root"

set log_path [file join $out_dir xsim.log]
set log_file [open $log_path r]
set log_text [read $log_file]
close $log_file
if {![string match \
        "*ALEXNET_M8N126_GRAPH_TOP_TRAINED_CONV1_SMOKE_PASS*" $log_text] ||
    [string match "*Fatal:*" $log_text]} {
  error "trained Conv1 graph-top smoke failed; see $log_path"
}
puts "ALEXNET_M8N126_GRAPH_TOP_TRAINED_CONV1_SMOKE_SIM_PASS"
