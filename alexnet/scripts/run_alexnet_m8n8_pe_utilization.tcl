source [file join [file dirname [info script]] shared_compute_sources.tcl]

set clean_env [list env -u LD_LIBRARY_PATH -u LD_PRELOAD]
set cpp_build [file join $alexnet_root cpp build]
exec {*}$clean_env cmake -S [file join $alexnet_root cpp] -B $cpp_build \
    -G Ninja -DCMAKE_BUILD_TYPE=Release
exec {*}$clean_env cmake --build $cpp_build --parallel

set sim_env [list env LD_PRELOAD=/usr/lib/libstdc++.so.6 \
    "LD_LIBRARY_PATH=$cpp_build:$env(LD_LIBRARY_PATH)"]

# First measure the feeder itself with an always-valid source and an
# always-ready sink over every AlexNet spatial geometry.
set feeder_top tb_alexnet_n8_rs_m4_feeder
set feeder_out [file join $alexnet_root build m8n8_pe_feeder_profile_sim]
file mkdir $feeder_out
cd $feeder_out
exec {*}$sim_env xvlog -sv -d SIMULATION \
    [file join $alexnet_root rtl feeder alexnet_n8_rs_m4_feeder.sv] \
    [file join $alexnet_root tb tb_alexnet_n8_rs_m4_feeder.sv]
exec {*}$sim_env xelab $feeder_top -debug typical \
    -generic_top PHYS_ROWS=4 -generic_top PERF_PROFILE=1 \
    -sv_root $cpp_build -sv_lib libalexnet_golden_dpi
exec {*}$sim_env xsim $feeder_top -runall
set f [open xsim.log r]
set feeder_log [read $f]
close $f
if {![string match "*ALEXNET_M8N8_PE_PROFILE_PASS*" $feeder_log] ||
    [string match "*Fatal:*" $feeder_log] ||
    [string match "*ERROR:*" $feeder_log]} {
  error "M8 feeder PE profile failed: $feeder_out/xsim.log"
}

# Then measure a complete Conv2 chunk through DMA-fed activation/weight
# storage, feeder, shared SA, accumulation bank and output scanner. Artificial
# CE stalls are disabled for the profiled chunk; every remaining idle cycle is
# classified by the monitor in the parent testbench.
set sim_top tb_alexnet_m4n8_shared_compute_top
set out_dir [file join $alexnet_root build m8n8_shared_pe_profile_sim]
file mkdir $out_dir
set shared_compute_phys_rows 4
source [file join $alexnet_root scripts shared_compute_test_drivers.tcl]
set tb_sources [list \
    [file join $alexnet_root tb tb_alexnet_m4n8_shared_compute_top.sv] \
    [file join $out_dir shared_compute_test_drivers.sv]]
cd $out_dir
exec {*}$sim_env xvlog -sv -d SIMULATION {*}$rtl_sources {*}$tb_sources
exec {*}$sim_env xelab $sim_top -debug typical \
    -generic_top PHYS_ROWS=4 -generic_top PERF_PROFILE=1 \
    -sv_root $cpp_build -sv_lib libalexnet_golden_dpi
exec {*}$sim_env xsim $sim_top -runall
set f [open xsim.log r]
set shared_log [read $f]
close $f
if {![string match "*ALEXNET_M8N8_SHARED_PE_PROFILE_PASS*" $shared_log] ||
    [string match "*Fatal:*" $shared_log] ||
    [string match "*ERROR:*" $shared_log]} {
  error "M8 shared PE profile failed: $out_dir/xsim.log"
}
puts "ALEXNET_M8N8_PE_UTILIZATION_SIM_PASS"
