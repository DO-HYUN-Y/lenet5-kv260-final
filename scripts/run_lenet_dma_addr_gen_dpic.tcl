set seed 20260725
set random_count 0
if {$argc >= 1} { set seed [lindex $argv 0] }
if {$argc >= 2} { set random_count [lindex $argv 1] }

set root [file normalize [file join [file dirname [info script]] ..]]
set out_dir [file join $root build lenet_dma_addr_gen_dpic]
file mkdir $out_dir
cd $out_dir

set rtl [file join $root rtl lenet_dma_addr_gen.sv]
set tb [file join $root tb tb_lenet_dma_addr_gen.sv]
set golden [file join $root golden lenet_dma_addr_gen_golden.c]
set coverage_db [file join $out_dir coverage.db]

exec xvlog -sv -d SIMULATION $rtl $tb
exec xsc $golden
exec xelab tb_lenet_dma_addr_gen -debug typical -sv_lib dpi \
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

exec xsim tb_lenet_dma_addr_gen -runall \
    -testplusarg SEED=$seed -testplusarg RANDOM_COUNT=0
check_log [file join $out_dir xsim.log] \
          "LENET_DMA_ADDR_GEN TEST PASSED"
file copy -force [file join $out_dir xsim.log] \
                 [file join $out_dir directed_xsim.log]

if {$random_count > 0} {
  exec xsim tb_lenet_dma_addr_gen -runall \
      -testplusarg SEED=$seed \
      -testplusarg RANDOM_COUNT=$random_count
  check_log [file join $out_dir xsim.log] \
            "LENET_DMA_ADDR_GEN TEST PASSED"
  file copy -force [file join $out_dir xsim.log] \
                   [file join $out_dir random_xsim.log]
}

puts "LENET_DMA_ADDR_GEN_DPIC_PASS seed=$seed random_count=$random_count"
