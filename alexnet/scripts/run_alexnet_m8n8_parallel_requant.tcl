set alexnet_root [file normalize [file join [file dirname [info script]] ..]]
set out_dir [file join $alexnet_root build m8n8_parallel_requant_sim]
set cpp_build [file join $alexnet_root cpp build]
file mkdir $out_dir

set clean_env [list env -u LD_LIBRARY_PATH -u LD_PRELOAD]
exec {*}$clean_env cmake -S [file join $alexnet_root cpp] -B $cpp_build \
    -G Ninja -DCMAKE_BUILD_TYPE=Release
exec {*}$clean_env cmake --build $cpp_build --parallel
exec {*}$clean_env ctest --test-dir $cpp_build --output-on-failure

set sim_env [list env LD_PRELOAD=/usr/lib/libstdc++.so.6 \
    "LD_LIBRARY_PATH=$cpp_build:$env(LD_LIBRARY_PATH)"]
cd $out_dir
exec {*}$sim_env xvlog -sv -d SIMULATION \
    [file join $alexnet_root rtl postprocess alexnet_n8_requant.sv] \
    [file join $alexnet_root rtl postprocess alexnet_m8n8_parallel_requant.sv] \
    [file join $alexnet_root tb tb_alexnet_m8n8_parallel_requant.sv]
exec {*}$sim_env xelab tb_alexnet_m8n8_parallel_requant -debug typical \
    -sv_root $cpp_build -sv_lib libalexnet_golden_dpi
exec {*}$sim_env xsim tb_alexnet_m8n8_parallel_requant -runall

set f [open xsim.log r]
set log_text [read $f]
close $f
if {![string match "*ALEXNET_M8N8_PARALLEL_REQUANT_TEST_PASSED*" $log_text] ||
    [string match "*Fatal:*" $log_text] ||
    [string match "*ERROR:*" $log_text]} {
  error "M8 parallel requant simulation failed: $out_dir/xsim.log"
}
puts "ALEXNET_M8N8_PARALLEL_REQUANT_SIM_PASS"
