set alexnet_root [file normalize [file join [file dirname [info script]] ..]]
set out_dir [file join $alexnet_root build n8_maxpool3x3_sim]
set cpp_build [file join $alexnet_root cpp build]
file mkdir $out_dir

set clean_host_env [list env -u LD_LIBRARY_PATH -u LD_PRELOAD]
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
set simulator_library_path "$cpp_build:$env(LD_LIBRARY_PATH)"
set simulator_env [list env LD_PRELOAD=$system_cxx_runtime \
    LD_LIBRARY_PATH=$simulator_library_path]

exec {*}$clean_host_env cmake \
    -S [file join $alexnet_root cpp] -B $cpp_build -G Ninja \
    -DCMAKE_BUILD_TYPE=Release
exec {*}$clean_host_env cmake --build $cpp_build --parallel
exec {*}$clean_host_env ctest --test-dir $cpp_build --output-on-failure

cd $out_dir
exec {*}$simulator_env xvlog -sv -d SIMULATION \
    [file join $alexnet_root rtl pool alexnet_n8_maxpool3x3.sv] \
    [file join $alexnet_root tb tb_alexnet_n8_maxpool3x3.sv]
exec {*}$simulator_env xelab tb_alexnet_n8_maxpool3x3 -debug typical \
    -sv_root $cpp_build -sv_lib libalexnet_golden_dpi
exec {*}$simulator_env xsim tb_alexnet_n8_maxpool3x3 -runall

set log_path [file join $out_dir xsim.log]
set log_file [open $log_path r]
set log_text [read $log_file]
close $log_file
if {![string match "*ALEXNET_N8_MAXPOOL3X3_TEST_PASSED*" $log_text] ||
    [string match "*Fatal:*" $log_text] ||
    [string match "*ERROR:*" $log_text]} {
  error "AlexNet N8 maxpool3x3 simulation failed; see $log_path"
}
puts "ALEXNET_N8_MAXPOOL3X3_DPI_PASS"
