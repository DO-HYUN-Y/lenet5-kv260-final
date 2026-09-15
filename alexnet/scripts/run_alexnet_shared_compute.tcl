source [file join [file dirname [info script]] shared_compute_sources.tcl]
set sim_top tb_alexnet_m4n8_shared_compute_top
if {[llength $argv] > 0} { set sim_top [lindex $argv 0] }
set out_dir [file join $alexnet_root build ${sim_top}_sim]
file mkdir $out_dir
set cpp_build [file join $alexnet_root cpp build]
set clean_env [list env -u LD_LIBRARY_PATH -u LD_PRELOAD]
exec {*}$clean_env cmake -S [file join $alexnet_root cpp] -B $cpp_build -G Ninja -DCMAKE_BUILD_TYPE=Release
exec {*}$clean_env cmake --build $cpp_build --parallel
exec {*}$clean_env ctest --test-dir $cpp_build --output-on-failure
set system_cxx_runtime ""
foreach candidate [list /usr/lib/libstdc++.so.6 \
                         /lib/x86_64-linux-gnu/libstdc++.so.6 \
                         /usr/lib/x86_64-linux-gnu/libstdc++.so.6] {
  if {[file exists $candidate]} {
    set system_cxx_runtime $candidate
    break
  }
}
if {$system_cxx_runtime eq ""} {
  error "system 64-bit C++ runtime not found"
}
set sim_env [list env LD_PRELOAD=$system_cxx_runtime \
    "LD_LIBRARY_PATH=$cpp_build:$env(LD_LIBRARY_PATH)"]
set tb_sources [list [file join $alexnet_root tb $sim_top.sv]]
if {$sim_top eq "tb_alexnet_m4n8_shared_compute_top"} {
  source [file join $alexnet_root scripts shared_compute_test_drivers.tcl]
  lappend tb_sources [file join $out_dir shared_compute_test_drivers.sv]
}
cd $out_dir
exec {*}$sim_env xvlog -sv -d SIMULATION {*}$rtl_sources {*}$tb_sources
exec {*}$sim_env xelab $sim_top -debug typical -sv_root $cpp_build -sv_lib libalexnet_golden_dpi
exec {*}$sim_env xsim $sim_top -runall
set f [open xsim.log r]
set log_text [read $f]
close $f
if {![string match "*TEST_PASSED*" $log_text] || [string match "*Fatal:*" $log_text] || [string match "*ERROR:*" $log_text]} {
  error "shared-compute regression failed: $out_dir/xsim.log"
}
puts "ALEXNET_SHARED_COMPUTE_SIM_PASS top=$sim_top"
