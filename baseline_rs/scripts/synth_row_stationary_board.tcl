set_param general.maxThreads 8
source [file join [file dirname [info script]] rs_sources.tcl]
set out_dir [file join $rs_root build rs_board_synth]
file mkdir $out_dir
foreach name {utilization.rpt timing.rpt worst_setup.rpt summary.txt post_synth.dcp} {file delete -force [file join $out_dir $name]}
read_verilog -sv $rs_sources
synth_design -top alexnet_row_stationary_accelerator_top -part xck26-sfvc784-2LV-c -mode out_of_context
create_clock -name aclk -period 5 [get_ports aclk]
report_utilization -hierarchical -file [file join $out_dir utilization.rpt]
report_timing_summary -file [file join $out_dir timing.rpt]
report_timing -max_paths 10 -file [file join $out_dir worst_setup.rpt]
write_checkpoint -force [file join $out_dir post_synth.dcp]
set dsp [get_cells -hier -filter {REF_NAME == DSP48E2}]
set sa_dsp [get_cells -hier -filter {REF_NAME == DSP48E2 && NAME =~ *u_sa*}]
set uram [get_cells -hier -filter {REF_NAME =~ URAM*}]
set input_uram [get_cells -hier -filter {REF_NAME =~ URAM* && NAME =~ *u_input_banks*}]
if {[llength $dsp]!=576 || [llength $sa_dsp]!=512 || [llength $uram]!=4 || [llength $input_uram]!=4} {error "RS resource contract failed DSP=[llength $dsp] SA=[llength $sa_dsp] URAM=[llength $uram]"}
set wns [get_property SLACK [get_timing_paths -delay_type max -max_paths 1]]
set whs [get_property SLACK [get_timing_paths -delay_type min -max_paths 1]]
set fh [open [file join $out_dir summary.txt] w]
puts $fh "SA_DSP=512
TOTAL_DSP=576
INPUT_URAM=4
WEIGHT_URAM=0
PERIOD_NS=5
WNS=$wns
WHS=$whs"
close $fh
puts "ALEXNET_RS_BOARD_RESOURCES_PASS DSP=576 SA_DSP=512 INPUT_URAM=4 WEIGHT_URAM=0 WNS=$wns WHS=$whs"
if {$wns<0 || $whs<0} {error "RS shell synthesis timing failed"}
puts "ALEXNET_RS_BOARD_SYNTH_PASS WNS=$wns WHS=$whs"
