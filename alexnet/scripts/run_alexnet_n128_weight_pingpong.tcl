set alexnet_root [file normalize [file join [file dirname [info script]] ..]]
set out_dir [file join $alexnet_root build n128_weight_pingpong_sim]
file mkdir $out_dir
cd $out_dir

exec xvlog -sv -d SIMULATION \
    [file join $alexnet_root rtl memory alexnet_n128_weight_pingpong.sv] \
    [file join $alexnet_root tb tb_alexnet_n128_weight_pingpong.sv]
exec xelab tb_alexnet_n128_weight_pingpong -debug typical
exec xsim tb_alexnet_n128_weight_pingpong -runall

set log_path [file join $out_dir xsim.log]
set log_file [open $log_path r]
set log_text [read $log_file]
close $log_file
if {![string match "*ALEXNET_N128_WEIGHT_PINGPONG_TEST_PASSED*" \
        $log_text] ||
    [string match "*Fatal:*" $log_text] ||
    [string match "*ERROR:*" $log_text]} {
  error "AlexNet N128 weight ping-pong simulation failed; see $log_path"
}
puts "ALEXNET_N128_WEIGHT_PINGPONG_PASS"
