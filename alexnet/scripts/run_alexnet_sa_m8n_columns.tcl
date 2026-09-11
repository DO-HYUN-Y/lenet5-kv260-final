set cols 32
set seed 1295535688
set random_tiles 100
if {$argc >= 1} { set cols [lindex $argv 0] }
if {$argc >= 2} { set seed [lindex $argv 1] }
if {$argc >= 3} { set random_tiles [lindex $argv 2] }
if {$cols < 8 || $cols > 256 || ($cols & ($cols - 1)) != 0} {
  error "column count must be a power of two from 8 through 256"
}

set alexnet_root [file normalize [file join [file dirname [info script]] ..]]
set out_dir [file join $alexnet_root build sa_m8n${cols}_sim]
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
    [file join $alexnet_root rtl packed_mac alexnet_packed_pe.sv] \
    [file join $alexnet_root rtl sa alexnet_sa_m4n8.sv] \
    [file join $alexnet_root tb tb_alexnet_sa_m4n8.sv]
exec {*}$simulator_env xelab tb_alexnet_sa_m4n8 -debug typical \
    -generic_top PHYS_ROWS=4 -generic_top COLS=$cols \
    -sv_root $cpp_build -sv_lib libalexnet_golden_dpi
exec {*}$simulator_env xsim tb_alexnet_sa_m4n8 -runall \
    -testplusarg SEED=$seed -testplusarg RANDOM_TILES=$random_tiles

set log_path [file join $out_dir xsim.log]
set log_file [open $log_path r]
set log_text [read $log_file]
close $log_file
if {![string match "*ALEXNET_SA_M8N${cols}_TEST_PASSED*" $log_text] ||
    [string match "*Fatal:*" $log_text] ||
    [string match "*ERROR:*" $log_text]} {
  error "AlexNet M8xN${cols} simulation failed; see $log_path"
}

puts "ALEXNET_SA_M8N${cols}_DPI_PASS seed=$seed random_tiles=$random_tiles"
