set alexnet_root [file normalize [file join [file dirname [info script]] ..]]
set repo_root [file normalize [file join $alexnet_root ..]]
set out_dir [file join $alexnet_root build m8n126_graph_top_full_graph_sim]
set vector_root [file join $alexnet_root cpp build-release \
    full_graph_pattern_v1]
set board_root [file join $repo_root alexnet_output \
    int8_mlcommons500_board]
if {![file isdirectory [file join $vector_root full_graph_axis64]]} {
  error "trained full-graph vectors not found; run the full-graph golden verifier"
}
if {![file exists [file join $board_root weights_board.bin]] ||
    ![file exists [file join $board_root parameters_board.bin]]} {
  error "board weight/parameter images not found under $board_root"
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
    -testplusarg "VECTOR_ROOT=$vector_root" \
    -testplusarg "BOARD_ROOT=$board_root" -testplusarg FULL_GRAPH

set log_path [file join $out_dir xsim.log]
set log_file [open $log_path r]
set log_text [read $log_file]
close $log_file
if {![string match \
        "*ALEXNET_M8N126_GRAPH_TOP_TRAINED_FULL_GRAPH_PASS*" $log_text] ||
    [string match "*Fatal:*" $log_text]} {
  error "trained full-graph top regression failed; see $log_path"
}
puts "ALEXNET_M8N126_GRAPH_TOP_TRAINED_FULL_GRAPH_SIM_PASS"
