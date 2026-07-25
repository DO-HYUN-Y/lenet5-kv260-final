set root [file normalize [file join [file dirname [info script]] ..]]
set out_dir [file join $root build activation_pingpong_dpic]
file mkdir $out_dir
cd $out_dir
set rtl [file join $root rtl]

exec xvlog -sv -d SIMULATION \
    [file join $rtl activation_bank_set.sv] \
    [file join $rtl activation_scalar_reader.sv] \
    [file join $rtl fc_activation_reader.sv] \
    [file join $rtl maxpool2x2_int8.sv] \
    [file join $rtl banked_maxpool2x2.sv] \
    [file join $rtl activation_pingpong_subsystem.sv] \
    [file join $root tb tb_activation_pingpong_subsystem.sv]
exec xsc [file join $root golden maxpool2x2_golden.c]
exec xelab tb_activation_pingpong_subsystem -debug typical -sv_lib dpi
exec xsim tb_activation_pingpong_subsystem -runall

set log_path [file join $out_dir xsim.log]
set fp [open $log_path r]
set text [read $fp]
close $fp
if {![string match "*ACTIVATION_PINGPONG_SUBSYSTEM TEST PASSED*" $text] ||
    [string match {*Fatal:*} $text] ||
    [string match {*ERROR:*} $text]} {
  error "Simulation failed; see $log_path"
}
file copy -force $log_path [file join $out_dir directed_xsim.log]
puts "ACTIVATION_PINGPONG_DPIC_PASS"
