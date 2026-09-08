set alexnet_root [file normalize [file join [file dirname [info script]] ..]]
set out_dir [file join $alexnet_root build n8_int32_partial_sum_bank_sim]
set cpp_build [file join $alexnet_root cpp build]
file mkdir $out_dir

set clean_host_env [list env -u LD_LIBRARY_PATH -u LD_PRELOAD]
set system_cxx_runtime /usr/lib/libstdc++.so.6
if {![file exists $system_cxx_runtime]} {
  error "system C++ runtime not found at $system_cxx_runtime"
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
    [file join $alexnet_root rtl memory \
        alexnet_n8_int32_partial_sum_bank.sv] \
    [file join $alexnet_root tb tb_alexnet_n8_int32_partial_sum_bank.sv]
exec {*}$simulator_env xelab tb_alexnet_n8_int32_partial_sum_bank \
    -debug typical -sv_root $cpp_build -sv_lib libalexnet_golden_dpi
exec {*}$simulator_env xsim tb_alexnet_n8_int32_partial_sum_bank -runall

set log_path [file join $out_dir xsim.log]
set log_file [open $log_path r]
set log_text [read $log_file]
close $log_file
if {![string match "*ALEXNET_N8_INT32_PARTIAL_SUM_BANK_TEST_PASSED*" \
        $log_text] ||
    [string match "*Fatal:*" $log_text] ||
    [string match "*ERROR:*" $log_text]} {
  error "AlexNet N8 INT32 partial-sum simulation failed; see $log_path"
}
puts "ALEXNET_N8_INT32_PARTIAL_SUM_BANK_DPI_PASS"
