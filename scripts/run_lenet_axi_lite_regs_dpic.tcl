set seed 20260725
set random_count 0
if {$argc >= 1} { set seed [lindex $argv 0] }
if {$argc >= 2} { set random_count [lindex $argv 1] }

set root [file normalize [file join [file dirname [info script]] ..]]
set out_dir [file join $root build lenet_axi_lite_regs_dpic]
file mkdir $out_dir
cd $out_dir

exec xvlog -sv -d SIMULATION \
    [file join $root rtl lenet_axi_lite_regs.sv] \
    [file join $root tb tb_lenet_axi_lite_regs.sv]
exec xsc [file join $root golden lenet_axi_lite_regs_golden.c]
exec xelab tb_lenet_axi_lite_regs -debug typical -sv_lib dpi

proc check_log {path marker} {
  set fp [open $path r]
  set log_text [read $fp]
  close $fp
  if {![string match "*$marker*" $log_text] ||
      [string match {*Fatal:*} $log_text] ||
      [string match {*ERROR:*} $log_text]} {
    error "Simulation failed; see $path"
  }
}

exec xsim tb_lenet_axi_lite_regs -runall \
    -testplusarg SEED=$seed -testplusarg RANDOM_COUNT=0
check_log [file join $out_dir xsim.log] \
          "LENET_AXI_LITE_REGS TEST PASSED"
file copy -force [file join $out_dir xsim.log] \
                 [file join $out_dir directed_xsim.log]

if {$random_count > 0} {
  exec xsim tb_lenet_axi_lite_regs -runall \
      -testplusarg SEED=$seed \
      -testplusarg RANDOM_COUNT=$random_count
  check_log [file join $out_dir xsim.log] \
            "LENET_AXI_LITE_REGS TEST PASSED"
  file copy -force [file join $out_dir xsim.log] \
                   [file join $out_dir random_xsim.log]
}

puts "LENET_AXI_LITE_REGS_DPIC_PASS seed=$seed random_count=$random_count"
