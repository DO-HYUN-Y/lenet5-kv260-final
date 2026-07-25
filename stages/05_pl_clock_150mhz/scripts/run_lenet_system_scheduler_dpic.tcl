set seed 20260725
set random_count 0
if {$argc >= 1} { set seed [lindex $argv 0] }
if {$argc >= 2} { set random_count [lindex $argv 1] }

set script_dir [file dirname [file normalize [info script]]]
set stage_dir [file normalize [file join $script_dir ..]]
set repo_dir [file normalize [file join $stage_dir .. ..]]
set out_dir [file join $stage_dir build lenet_system_scheduler_dpic]
file mkdir $out_dir
cd $out_dir

exec xvlog -sv -d SIMULATION \
    [file join $repo_dir rtl lenet_system_scheduler.sv] \
    [file join $stage_dir sim tb_lenet_system_scheduler_dpic.sv]
exec xsc [file join $stage_dir sim lenet_system_scheduler_golden.c]
exec xelab tb_lenet_system_scheduler_dpic -debug typical -sv_lib dpi \
    -cc_type sbct -cov_db_dir $out_dir -cov_db_name system_scheduler

proc run_and_check {seed random_count output_name} {
  exec xsim tb_lenet_system_scheduler_dpic -runall \
      -testplusarg SEED=$seed \
      -testplusarg RANDOM_COUNT=$random_count \
      -cov_db_dir . -cov_db_name system_scheduler
  set fp [open xsim.log r]
  set log_text [read $fp]
  close $fp
  if {![string match {*LENET_SYSTEM_SCHEDULER TEST PASSED*} $log_text] ||
      [string match {*Fatal:*} $log_text] ||
      [string match {*ERROR:*} $log_text]} {
    error "System scheduler simulation failed; see $output_name"
  }
  file copy -force xsim.log $output_name
}

run_and_check $seed 0 directed_xsim.log
if {$random_count > 0} {
  run_and_check $seed $random_count random_xsim.log
}

file mkdir [file join $out_dir coverage_report]
if {[catch {
  exec xcrg -cov_db_dir $out_dir -cov_db_name system_scheduler \
      -report_format text -report_dir [file join $out_dir coverage_report]
} coverage_message]} {
  puts "COVERAGE_REPORT_WARNING=$coverage_message"
}

puts "LENET_SYSTEM_SCHEDULER_DPIC_PASS seed=$seed random_count=$random_count"
