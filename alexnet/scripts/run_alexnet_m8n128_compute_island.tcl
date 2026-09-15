set alexnet_root [file normalize [file join [file dirname [info script]] ..]]
set out_dir [file join $alexnet_root build m8n128_compute_island_sim]
file mkdir $out_dir
cd $out_dir

set rtl_sources [list \
    [file join $alexnet_root rtl packed_mac alexnet_packed_pe.sv] \
    [file join $alexnet_root rtl sa alexnet_sa_m4n8.sv] \
    [file join $alexnet_root rtl sa alexnet_sa_m8n128_dynamic.sv] \
    [file join $alexnet_root rtl feeder alexnet_n8_rs_m4_feeder.sv] \
    [file join $alexnet_root rtl feeder alexnet_n8_rs_m16_feeder.sv] \
    [file join $alexnet_root rtl memory alexnet_n128_weight_pingpong.sv] \
    [file join $alexnet_root rtl postprocess alexnet_n8_requant.sv] \
    [file join $alexnet_root rtl postprocess \
        alexnet_m8n8_parallel_requant.sv] \
    [file join $alexnet_root rtl integration \
        alexnet_m8n128_compute_island.sv]]
set tb_source [file join $alexnet_root tb \
    tb_alexnet_m8n128_compute_island.sv]

exec xvlog -sv -d SIMULATION {*}$rtl_sources $tb_source
exec xelab tb_alexnet_m8n128_compute_island -debug typical
exec xsim tb_alexnet_m8n128_compute_island -runall

set log_path [file join $out_dir xsim.log]
set log_file [open $log_path r]
set log_text [read $log_file]
close $log_file
if {![string match "*ALEXNET_M8N128_COMPUTE_ISLAND_TEST_PASSED*" \
        $log_text] ||
    [string match "*Fatal:*" $log_text] ||
    [string match "*ERROR:*" $log_text]} {
  error "M8xN128 compute-island simulation failed; see $log_path"
}
puts "ALEXNET_M8N128_COMPUTE_ISLAND_PASS"
