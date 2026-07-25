set_param general.maxThreads 16

set stage_dir [file normalize [file join [file dirname [info script]] ..]]
set build_dir [file join $stage_dir build clock_reset_timing]
set project_dir [file join $build_dir vivado]
set report_dir [file join $build_dir reports]
set netlist_dir [file join $build_dir netlist]
set sim_dir [file join $build_dir simulation]
file delete -force $build_dir
file mkdir $report_dir
file mkdir $netlist_dir
file mkdir $sim_dir

create_project -force clock_reset_timing_smoke $project_dir \
    -part xck26-sfvc784-2LV-c
set_property target_language Verilog [current_project]

create_ip -name clk_wiz -vendor xilinx.com -library ip \
    -module_name system_clk_wiz_150_0
set_property -dict [list \
    CONFIG.PRIMITIVE {MMCM} \
    CONFIG.PRIM_SOURCE {No_buffer} \
    CONFIG.PRIM_IN_FREQ {99.999001} \
    CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {150.000} \
    CONFIG.OVERRIDE_MMCM {true} \
    CONFIG.MMCM_DIVCLK_DIVIDE {1} \
    CONFIG.MMCM_CLKFBOUT_MULT_F {12.000} \
    CONFIG.MMCM_CLKOUT0_DIVIDE_F {8.000} \
    CONFIG.USE_LOCKED {true} \
    CONFIG.USE_RESET {false} \
] [get_ips system_clk_wiz_150_0]

create_ip -name proc_sys_reset -vendor xilinx.com -library ip \
    -module_name system_rst_pl_0
set_property -dict [list \
    CONFIG.C_EXT_RESET_HIGH {0} \
    CONFIG.C_AUX_RESET_HIGH {0} \
    CONFIG.C_NUM_BUS_RST {1} \
    CONFIG.C_NUM_PERP_RST {1} \
    CONFIG.C_NUM_INTERCONNECT_ARESETN {1} \
    CONFIG.C_NUM_PERP_ARESETN {1} \
] [get_ips system_rst_pl_0]

generate_target all [get_ips]

add_files -norecurse [file join $stage_dir sim clock_reset_harness.sv]
add_files -fileset constrs_1 -norecurse \
    [file join $stage_dir scripts clock_reset_harness.xdc]
set_property top clock_reset_harness [current_fileset]
update_compile_order -fileset sources_1

launch_runs synth_1 -jobs 16
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {
    error "Clock/reset harness synthesis failed: \
[get_property STATUS [get_runs synth_1]]"
}
open_run synth_1
opt_design
place_design
phys_opt_design
route_design

# This is an out-of-context verification harness, not a package-level
# bitstream. Its four observation ports intentionally have no package pins.
set_property SEVERITY Warning [get_drc_checks {NSTD-1 UCIO-1}]
report_timing_summary -delay_type min_max -check_timing_verbose \
    -report_unconstrained \
    -file [file join $report_dir timing_summary.rpt]
report_route_status -file [file join $report_dir route_status.rpt]
report_drc -file [file join $report_dir drc.rpt]
check_timing -verbose -file [file join $report_dir check_timing.rpt]

set setup_path [get_timing_paths -delay_type max -max_paths 1 -nworst 1]
set hold_path [get_timing_paths -delay_type min -max_paths 1 -nworst 1]
if {[llength $setup_path] == 0 || [llength $hold_path] == 0} {
    error "Clock/reset harness has no setup or hold timing path"
}
set wns [get_property SLACK $setup_path]
set whs [get_property SLACK $hold_path]
if {$wns < 0.0 || $whs < 0.0} {
    error "Clock/reset harness timing failed: WNS=$wns WHS=$whs"
}
set failed_route_nets [get_nets -quiet -hierarchical -filter {
    ROUTE_STATUS == "FAILED" ||
    ROUTE_STATUS == "UNROUTED" ||
    ROUTE_STATUS == "PARTIALLY_ROUTED"
}]
set drc_errors [get_drc_violations -quiet -filter {SEVERITY == "Error"}]
set drc_critical [get_drc_violations -quiet \
    -filter {SEVERITY == "Critical Warning"}]
if {[llength $failed_route_nets] != 0} {
    error "Clock/reset harness has [llength $failed_route_nets] failed nets"
}
if {[llength $drc_errors] != 0 || [llength $drc_critical] != 0} {
    error "Clock/reset harness DRC failed: errors=[llength $drc_errors] \
critical=[llength $drc_critical]"
}

write_checkpoint -force [file join $netlist_dir postroute.dcp]
write_verilog -force -mode funcsim \
    -rename_top clock_reset_harness \
    [file join $netlist_dir postroute_funcsim.v]
write_verilog -force -mode timesim -sdf_anno false \
    -rename_top clock_reset_harness \
    [file join $netlist_dir postroute_timesim.v]
write_sdf -force -process_corner slow \
    -rename_top clock_reset_harness \
    [file join $netlist_dir postroute_timesim.sdf]

set summary_file [open [file join $report_dir summary.txt] w]
puts $summary_file "TOP=clock_reset_harness"
puts $summary_file "WNS=$wns"
puts $summary_file "WHS=$whs"
puts $summary_file "FAILED_ROUTE_NETS=[llength $failed_route_nets]"
puts $summary_file "DRC_ERRORS=[llength $drc_errors]"
puts $summary_file "DRC_CRITICAL_WARNINGS=[llength $drc_critical]"
close $summary_file
close_project

set glbl_file [file join $::env(XILINX_VIVADO) data verilog src glbl.v]
set tb_file [file join $stage_dir sim tb_clock_reset_harness.sv]

proc check_log {path marker} {
    set fp [open $path r]
    set log_text [read $fp]
    close $fp
    if {![string match "*$marker*" $log_text] ||
            [string match {*Fatal:*} $log_text] ||
            [string match {*ERROR:*} $log_text]} {
        error "Clock/reset netlist simulation failed; see $path"
    }
}

proc run_netlist {name netlist sdf sim_dir tb_file glbl_file} {
    set run_dir [file join $sim_dir $name]
    set snapshot ${name}_snapshot
    file mkdir $run_dir
    cd $run_dir
    exec xvlog -sv $netlist $tb_file $glbl_file
    set elaborate [list xelab tb_clock_reset_harness glbl \
        -debug off -s $snapshot]
    if {$sdf ne ""} {
        lappend elaborate -L simprims_ver
        lappend elaborate -sdfmax \
            /tb_clock_reset_harness/dut=$sdf
    } else {
        lappend elaborate -L unisims_ver -L unimacro_ver
    }
    lappend elaborate -L secureip
    exec {*}$elaborate
    exec xsim $snapshot -runall
    check_log [file join $run_dir xsim.log] \
        "CLOCK_RESET_TIMING_SMOKE_PASS"
    file copy -force [file join $run_dir xsim.log] \
        [file join $sim_dir ${name}_xsim.log]
}

run_netlist funcsim \
    [file join $netlist_dir postroute_funcsim.v] "" \
    $sim_dir $tb_file $glbl_file
run_netlist timesim \
    [file join $netlist_dir postroute_timesim.v] \
    [file join $netlist_dir postroute_timesim.sdf] \
    $sim_dir $tb_file $glbl_file

puts "CLOCK_RESET_POSTROUTE_TIMING_SMOKE_PASS WNS=$wns WHS=$whs"
exit
