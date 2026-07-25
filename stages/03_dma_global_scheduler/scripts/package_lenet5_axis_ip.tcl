set ::lenet_stage_dir_override \
    [file normalize [file join [file dirname [info script]] ..]]
set ::lenet_autonomous_dma 1
source [file normalize [file join [file dirname [info script]] \
    .. .. 02_kv260_system scripts package_lenet5_axis_ip.tcl]]
