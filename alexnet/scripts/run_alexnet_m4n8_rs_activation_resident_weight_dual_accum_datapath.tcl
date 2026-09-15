set alexnet_root [file normalize [file join [file dirname [info script]] ..]]
set out_dir [file join $alexnet_root build \
    m4n8_rs_activation_resident_weight_dual_accum_datapath_sim]
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
    [file join $alexnet_root rtl packed_mac alexnet_packed_pe.sv] \
    [file join $alexnet_root rtl sa alexnet_sa_m4n8.sv] \
    [file join $alexnet_root rtl result alexnet_m4n8_result_scanner.sv] \
    [file join $alexnet_root rtl memory \
        alexnet_n8_int32_partial_sum_bank.sv] \
    [file join $alexnet_root rtl memory \
        alexnet_n8_int32_partial_sum_bank_pair.sv] \
    [file join $alexnet_root rtl postprocess alexnet_n8_requant.sv] \
    [file join $alexnet_root rtl result alexnet_n8_output_router.sv] \
    [file join $alexnet_root rtl integration \
        alexnet_m4n8_n8_dual_accum_output_slice.sv] \
    [file join $alexnet_root rtl integration \
        alexnet_m4n8_dual_accum_base_datapath.sv] \
    [file join $alexnet_root rtl feeder alexnet_n8_rs_m4_feeder.sv] \
    [file join $alexnet_root rtl control \
        alexnet_m4n8_rs_issue_controller.sv] \
    [file join $alexnet_root rtl memory alexnet_n8_weight_tile_bank.sv] \
    [file join $alexnet_root rtl integration \
        alexnet_m4n8_rs_resident_weight_dual_accum_datapath.sv] \
    [file join $alexnet_root rtl memory alexnet_n8_activation_bank.sv] \
    [file join $alexnet_root rtl memory alexnet_n8_activation_pingpong.sv] \
    [file join $alexnet_root rtl memory \
        alexnet_n8_activation_dual_segment_pingpong.sv] \
    [file join $alexnet_root rtl integration \
        alexnet_m4n8_rs_activation_resident_weight_dual_accum_datapath.sv] \
    [file join $alexnet_root tb \
        tb_alexnet_m4n8_rs_activation_resident_weight_dual_accum_datapath.sv]
exec {*}$simulator_env xelab \
    tb_alexnet_m4n8_rs_activation_resident_weight_dual_accum_datapath \
    -sv_root $cpp_build -sv_lib libalexnet_golden_dpi
exec {*}$simulator_env xsim \
    tb_alexnet_m4n8_rs_activation_resident_weight_dual_accum_datapath -runall

set log_path [file join $out_dir xsim.log]
set log_file [open $log_path r]
set log_text [read $log_file]
close $log_file
if {![string match \
        "*ALEXNET_M4N8_RS_ACTIVATION_RESIDENT_WEIGHT_DUAL_ACCUM_DATAPATH_TEST_PASSED*" \
        $log_text] ||
    [string match "*Fatal:*" $log_text] ||
    [string match "*ERROR:*" $log_text]} {
  error "AlexNet activation-buffered RS simulation failed; see $log_path"
}
puts "ALEXNET_M4N8_RS_ACTIVATION_RESIDENT_WEIGHT_DUAL_ACCUM_DATAPATH_DPI_PASS"
