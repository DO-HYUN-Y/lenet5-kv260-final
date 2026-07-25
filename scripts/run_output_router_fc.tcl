set root [file normalize [file join [file dirname [info script]] ..]]
set out_dir [file join $root build output_router_fc]
file mkdir $out_dir
cd $out_dir

exec xvlog -sv -d SIMULATION \
  [file join $root rtl output_router.sv] \
  [file join $root tb tb_output_router_fc.sv]
exec xelab tb_output_router_fc -debug typical
exec xsim tb_output_router_fc -runall
