set seed 20260725
set random_count 0
if {$argc >= 1} { set seed [lindex $argv 0] }
if {$argc >= 2} { set random_count [lindex $argv 1] }

set root [file normalize [file join [file dirname [info script]] ..]]
set out_dir [file join $root build axis_lenet_ingress_dpic]
file mkdir $out_dir
cd $out_dir

set rtl_files [list \
    [file join $root rtl lenet_dma_addr_gen.sv] \
    [file join $root rtl axis_lenet_ingress.sv]]
set tb [file join $root tb tb_axis_lenet_ingress.sv]
set golden [file join $root golden axis_lenet_ingress_golden.c]
set coverage_db [file join $out_dir coverage.db]

exec xvlog -sv -d SIMULATION {*}$rtl_files $tb
exec xsc $golden
exec xelab tb_axis_lenet_ingress -debug typical -sv_lib dpi \
    -cc_db $coverage_db

proc check_log {path marker} {
  set fp [open $path r]
  set text [read $fp]
  close $fp
  if {![string match "*$marker*" $text] ||
      [string match {*Fatal:*} $text] ||
      [string match {*ERROR:*} $text]} {
    error "Simulation failed; see $path"
  }
}

exec xsim tb_axis_lenet_ingress -runall \
    -testplusarg SEED=$seed -testplusarg RANDOM_COUNT=0
check_log [file join $out_dir xsim.log] \
          "AXIS_LENET_INGRESS TEST PASSED"
file copy -force [file join $out_dir xsim.log] \
                 [file join $out_dir directed_xsim.log]

if {$random_count > 0} {
  exec xsim tb_axis_lenet_ingress -runall \
      -testplusarg SEED=$seed \
      -testplusarg RANDOM_COUNT=$random_count
  check_log [file join $out_dir xsim.log] \
            "AXIS_LENET_INGRESS TEST PASSED"
  file copy -force [file join $out_dir xsim.log] \
                   [file join $out_dir random_xsim.log]
}

puts "AXIS_LENET_INGRESS_DPIC_PASS seed=$seed random_count=$random_count"
