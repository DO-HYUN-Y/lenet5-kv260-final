set_param general.maxThreads 8

set stage_dir [file normalize [file join [file dirname [info script]] ..]]
set repo_dir [file normalize [file join $stage_dir .. ..]]
set build_dir [file join $stage_dir build]
set netlist_dir [file join $build_dir netlist_sim]
file mkdir $netlist_dir

set checkpoint [file join $repo_dir checkpoints lenet5_axis_wrapper \
    lenet5_axis_wrapper_post_route.dcp]
if {![file exists $checkpoint]} {
    error "Post-route checkpoint is missing: $checkpoint"
}

open_checkpoint $checkpoint
write_verilog -force -mode funcsim \
    -rename_top lenet5_axis_wrapper \
    [file join $netlist_dir ooc_postroute_funcsim.v]
write_verilog -force -mode timesim -sdf_anno false \
    -rename_top lenet5_axis_wrapper \
    [file join $netlist_dir ooc_postroute_timesim.v]
write_sdf -force -process_corner slow \
    -rename_top lenet5_axis_wrapper \
    [file join $netlist_dir ooc_postroute_timesim.sdf]

close_design
exit
