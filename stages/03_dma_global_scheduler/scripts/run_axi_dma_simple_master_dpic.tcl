set seed 20260725
set random_count 0
if {$argc >= 1} { set seed [lindex $argv 0] }
if {$argc >= 2} { set random_count [lindex $argv 1] }

set script_dir [file dirname [file normalize [info script]]]
set stage_dir [file normalize [file join $script_dir ..]]
set repo_dir [file normalize [file join $stage_dir .. ..]]
set out_dir [file join $stage_dir build axi_dma_simple_master_dpic]
file mkdir $out_dir
cd $out_dir

exec xvlog -sv -d SIMULATION \
    [file join $repo_dir rtl axi_dma_simple_master.sv] \
    [file join $stage_dir sim tb_axi_dma_simple_master_dpic.sv]
exec xsc [file join $stage_dir sim axi_dma_simple_master_golden.c]
exec xelab tb_axi_dma_simple_master_dpic -debug typical -sv_lib dpi \
    -cc_type sbct -cov_db_dir $out_dir -cov_db_name dma_master

proc run_and_check {seed random_count output_name} {
  exec xsim tb_axi_dma_simple_master_dpic -runall \
      -testplusarg SEED=$seed \
      -testplusarg RANDOM_COUNT=$random_count \
      -cov_db_dir . -cov_db_name dma_master
  set fp [open xsim.log r]
  set log_text [read $fp]
  close $fp
  if {![string match {*AXI_DMA_SIMPLE_MASTER TEST PASSED*} $log_text] ||
      [string match {*Fatal:*} $log_text] ||
      [string match {*ERROR:*} $log_text]} {
    error "AXI DMA master simulation failed; see $output_name"
  }
  file copy -force xsim.log $output_name
}

run_and_check $seed 0 directed_xsim.log
if {$random_count > 0} {
  run_and_check $seed $random_count random_xsim.log
}

file mkdir [file join $out_dir coverage_report]
if {[catch {
  exec xcrg -cov_db_dir $out_dir \
      -cov_db_name dma_master -report_format text \
      -report_dir [file join $out_dir coverage_report]
} coverage_message]} {
  puts "COVERAGE_REPORT_WARNING=$coverage_message"
}

puts "AXI_DMA_SIMPLE_MASTER_DPIC_PASS seed=$seed random_count=$random_count"
