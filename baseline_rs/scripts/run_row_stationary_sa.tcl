set root [file normalize [file join [file dirname [info script]] ..]]
set out [file join $root build rs_sa_extreme]
file mkdir $out
cd $out
exec xvlog -sv [file join $root rtl packed_mac alexnet_row_stationary_pe.sv] [file join $root rtl packed_mac alexnet_rs_filter_row_rf.sv] [file join $root rtl sa alexnet_sa_m8r128_row_stationary.sv] [file join $root tb tb_alexnet_row_stationary_sa.sv]
exec xelab tb_alexnet_row_stationary_sa -debug typical
exec xsim tb_alexnet_row_stationary_sa -runall -log sa.log
set fh [open sa.log r];set result [read $fh];close $fh
if {![string match "*TEST_PASSED contexts=22 N_tokens=44*" $result] || [string match "*Fatal:*" $result] || [string match "*Error:*" $result]} {error "RS SA extreme/stall test failed"}
puts "ALEXNET_RS_SA_EXTREME_AND_STALL_PASS contexts=22 tokens=44"
