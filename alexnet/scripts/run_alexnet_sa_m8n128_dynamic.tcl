set seed 1295540274
if {$argc >= 1} { set seed [lindex $argv 0] }

set alexnet_root [file normalize [file join [file dirname [info script]] ..]]
set out_dir [file join $alexnet_root build sa_m8n128_dynamic_sim]
file mkdir $out_dir
cd $out_dir

exec xvlog -sv -d SIMULATION \
    [file join $alexnet_root rtl packed_mac alexnet_packed_pe.sv] \
    [file join $alexnet_root rtl sa alexnet_sa_m4n8.sv] \
    [file join $alexnet_root rtl sa alexnet_sa_m8n128_dynamic.sv] \
    [file join $alexnet_root tb tb_alexnet_sa_m8n128_dynamic.sv]
exec xelab tb_alexnet_sa_m8n128_dynamic -debug typical
exec xsim tb_alexnet_sa_m8n128_dynamic -runall -testplusarg SEED=$seed

set log_path [file join $out_dir xsim.log]
set log_file [open $log_path r]
set log_text [read $log_file]
close $log_file
if {![string match "*ALEXNET_SA_M8N128_DYNAMIC_TEST_PASSED*" $log_text] ||
    [string match "*Fatal:*" $log_text] ||
    [string match "*ERROR:*" $log_text]} {
  error "AlexNet dynamic M8xN128 simulation failed; see $log_path"
}

puts "ALEXNET_SA_M8N128_DYNAMIC_PASS seed=$seed"
