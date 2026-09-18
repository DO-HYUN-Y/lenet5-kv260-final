source [file join [file dirname [info script]] rs_sources.tcl]
set out_dir [file join $rs_root build rs_regression]
file mkdir $out_dir
cd $out_dir
set test_sources [list]
foreach name {sa graph control weight_dma_bridge} {lappend test_sources [file join $rs_root tb tb_alexnet_row_stationary_${name}.sv]}
lappend test_sources [file join $rs_root tb tb_alexnet_hybrid_schedule_trace.sv]
lappend test_sources [file join $alexnet_root rtl control alexnet_m8n126_graph_scheduler.sv]
exec xvlog -sv {*}$rs_sources {*}$test_sources
foreach top {tb_alexnet_row_stationary_sa tb_alexnet_row_stationary_graph tb_alexnet_row_stationary_control tb_alexnet_row_stationary_weight_dma_bridge tb_alexnet_hybrid_schedule_trace} {
    exec xelab $top -debug typical
    exec xsim $top -runall -log ${top}.log
    set fh [open ${top}.log r];set log [read $fh];close $fh
    if {![string match "*TEST_PASSED*" $log] || [string match "*Fatal:*" $log] || [string match "*Error:*" $log]} {error "RS regression failed: $top"}
    puts "RS_REGRESSION_PASS $top"
}
puts "ALEXNET_RS_REGRESSIONS_PASSED"
