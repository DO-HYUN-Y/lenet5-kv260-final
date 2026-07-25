set_param general.maxThreads 8

open_hw_manager
if {[catch {connect_hw_server -url localhost:3121 -allow_non_jtag} message]} {
    puts "HW_CONNECT_ERROR=$message"
    close_hw_manager
    exit 2
}

if {[catch {open_hw_target} message]} {
    puts "HW_TARGET_ERROR=$message"
    disconnect_hw_server
    close_hw_manager
    exit 3
}

set devices [get_hw_devices]
puts "HW_DEVICE_COUNT=[llength $devices]"
foreach device $devices {
    puts "HW_DEVICE=$device PART=[get_property PART $device]"
}

close_hw_target
disconnect_hw_server
close_hw_manager

if {[llength $devices] == 0} {
    exit 4
}
exit 0
