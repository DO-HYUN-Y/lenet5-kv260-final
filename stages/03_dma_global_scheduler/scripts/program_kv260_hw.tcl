set_param general.maxThreads 8

set stage_dir [file normalize [file join [file dirname [info script]] ..]]
set bit_file [file join $stage_dir build output lenet5_kv260.bit]
if {![file exists $bit_file]} {
    error "Bitstream is missing: $bit_file"
}

open_hw_manager
connect_hw_server -url localhost:3121 -allow_non_jtag
open_hw_target

set devices [get_hw_devices -quiet -filter {PART == xck26}]
if {[llength $devices] != 1} {
    error "Expected one xck26 device, found: $devices"
}
set device [lindex $devices 0]
current_hw_device $device
refresh_hw_device -update_hw_probes false $device
set_property PROGRAM.FILE $bit_file $device
program_hw_devices $device
refresh_hw_device -update_hw_probes false $device

puts "KV260_PROGRAM_PASS DEVICE=$device BITSTREAM=$bit_file"

close_hw_target
disconnect_hw_server
close_hw_manager
exit
