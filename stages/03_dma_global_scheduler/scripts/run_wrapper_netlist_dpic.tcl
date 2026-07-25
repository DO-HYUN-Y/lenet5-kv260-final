set seed 20260725
if {$argc >= 1} { set seed [lindex $argv 0] }

set stage_dir [file normalize [file join [file dirname [info script]] ..]]
set repo_dir [file normalize [file join $stage_dir .. ..]]
set netlist_dir [file join $stage_dir build netlist_sim]
set glbl_file [file join $::env(XILINX_VIVADO) data verilog src glbl.v]
set tb_file [file join $repo_dir tb tb_lenet5_axis_wrapper.sv]
set golden_file [file join $repo_dir golden lenet5_axis_wrapper_golden.c]

proc check_log {path marker} {
    set fp [open $path r]
    set log_text [read $fp]
    close $fp
    if {![string match "*$marker*" $log_text] ||
        [string match {*Fatal:*} $log_text] ||
        [string match {*ERROR:*} $log_text]} {
        error "Netlist simulation failed; see $path"
    }
}

proc run_netlist {name netlist sdf seed netlist_dir tb_file golden_file glbl_file} {
    set run_dir [file join $netlist_dir $name]
    set snapshot ${name}_snapshot
    file delete -force $run_dir
    file mkdir $run_dir
    cd $run_dir
    exec xvlog -sv $netlist $tb_file $glbl_file
    exec xsc $golden_file
    set elaborate [list xelab tb_lenet5_axis_wrapper glbl \
        -debug off -sv_lib dpi \
        -s $snapshot]
    if {$sdf ne ""} {
        lappend elaborate -L simprims_ver
        lappend elaborate -sdfmax \
            /tb_lenet5_axis_wrapper/dut=$sdf
    } else {
        lappend elaborate -L unisims_ver -L unimacro_ver
    }
    lappend elaborate -L secureip
    exec {*}$elaborate
    exec xsim $snapshot -runall \
        -testplusarg SEED=$seed \
        -testplusarg RANDOM_STALLS=0 \
        -testplusarg NETLIST_SMOKE=1
    check_log [file join $run_dir xsim.log] \
        "LENET5_AXIS_WRAPPER TEST PASSED"
    file copy -force [file join $run_dir xsim.log] \
        [file join $netlist_dir ${name}_xsim.log]
}

run_netlist funcsim \
    [file join $netlist_dir ooc_postroute_funcsim.v] "" \
    $seed $netlist_dir $tb_file $golden_file $glbl_file
run_netlist timesim \
    [file join $netlist_dir ooc_postroute_timesim.v] \
    [file join $netlist_dir ooc_postroute_timesim.sdf] \
    $seed $netlist_dir $tb_file $golden_file $glbl_file

puts "LENET5_AXIS_WRAPPER_NETLIST_DPIC_PASS seed=$seed"
exit
