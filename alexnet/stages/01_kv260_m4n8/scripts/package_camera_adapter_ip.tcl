set_param general.maxThreads 8

if {[info exists ::alexnet_stage_dir_override]} {
    set stage_dir [file normalize $::alexnet_stage_dir_override]
} else {
    set stage_dir [file normalize [file join [file dirname [info script]] ..]]
}
set alexnet_dir [file normalize [file join $stage_dir .. ..]]
set build_dir [file join $stage_dir build]
set package_project_dir [file join $build_dir ip_package_camera_adapter]
set ip_root [file join $build_dir ip_repo alexnet_camera_rgbx_adapter_1.0]

file delete -force $package_project_dir
file delete -force $ip_root
file mkdir [file dirname $ip_root]
file mkdir [file join $build_dir reports]

create_project -force alexnet_camera_adapter_ip_package $package_project_dir \
    -part xck26-sfvc784-2LV-c
add_files -norecurse [file join $alexnet_dir rtl integration \
    alexnet_camera_rgbx_axis_adapter.sv]
set_property top alexnet_camera_rgbx_axis_adapter [current_fileset]
update_compile_order -fileset sources_1

ipx::package_project -root_dir $ip_root -vendor user.org -library user \
    -taxonomy /UserIP -import_files -set_current true
set core [ipx::current_core]
set_property name alexnet_camera_rgbx_adapter $core
set_property display_name {AlexNet Camera RGBX AXIS Adapter} $core
set_property description \
    {Converts one 64-bit RGBX DDR word per pixel into a three-lane Conv1 N8 stream} \
    $core
set_property core_revision 1 $core
set_property version 1.0 $core
set_property supported_families {zynquplus Production} $core

proc camera_add_port_mapping {interface logical physical} {
    ipx::add_port_map $logical $interface
    set_property physical_name $physical \
        [ipx::get_port_maps $logical -of_objects $interface]
}

proc camera_add_interface {core name bus_vlnv abstraction_vlnv mode mappings} {
    set interface [ipx::add_bus_interface $name $core]
    set_property bus_type_vlnv $bus_vlnv $interface
    set_property abstraction_type_vlnv $abstraction_vlnv $interface
    set_property interface_mode $mode $interface
    foreach {logical physical} $mappings {
        camera_add_port_mapping $interface $logical $physical
    }
    return $interface
}

foreach interface [ipx::get_bus_interfaces -of_objects $core] {
    ipx::remove_bus_interface [get_property NAME $interface] $core
}

set s_axis_if [camera_add_interface $core S_AXIS \
    xilinx.com:interface:axis:1.0 xilinx.com:interface:axis_rtl:1.0 slave {
        TDATA s_axis_tdata
        TKEEP s_axis_tkeep
        TVALID s_axis_tvalid
        TREADY s_axis_tready
        TLAST s_axis_tlast
    }]
set m_axis_if [camera_add_interface $core M_AXIS \
    xilinx.com:interface:axis:1.0 xilinx.com:interface:axis_rtl:1.0 master {
        TDATA m_axis_tdata
        TKEEP m_axis_tkeep
        TVALID m_axis_tvalid
        TREADY m_axis_tready
        TLAST m_axis_tlast
    }]
set clock_if [camera_add_interface $core aclk \
    xilinx.com:signal:clock:1.0 xilinx.com:signal:clock_rtl:1.0 slave {
        CLK aclk
    }]
set reset_if [camera_add_interface $core aresetn \
    xilinx.com:signal:reset:1.0 xilinx.com:signal:reset_rtl:1.0 slave {
        RST aresetn
    }]
set error_if [camera_add_interface $core format_error_irq \
    xilinx.com:signal:interrupt:1.0 \
    xilinx.com:signal:interrupt_rtl:1.0 master {
        INTERRUPT format_error
    }]

foreach busif {S_AXIS M_AXIS} {
    ipx::associate_bus_interfaces -busif $busif -clock aclk $core
}
set associated_reset [ipx::add_bus_parameter ASSOCIATED_RESET $clock_if]
set_property value aresetn $associated_reset
set reset_polarity [ipx::add_bus_parameter POLARITY $reset_if]
set_property value ACTIVE_LOW $reset_polarity
set irq_sensitivity [ipx::add_bus_parameter SENSITIVITY $error_if]
set_property value LEVEL_HIGH $irq_sensitivity

foreach axis_interface [list $s_axis_if $m_axis_if] {
    set data_bytes [ipx::add_bus_parameter TDATA_NUM_BYTES $axis_interface]
    set_property value 8 $data_bytes
    set has_keep [ipx::add_bus_parameter HAS_TKEEP $axis_interface]
    set_property value 1 $has_keep
    set has_last [ipx::add_bus_parameter HAS_TLAST $axis_interface]
    set_property value 1 $has_last
}

ipx::create_xgui_files $core
ipx::update_checksums $core
ipx::check_integrity $core
ipx::save_core $core

set report_file [file join $build_dir reports camera_adapter_ip_integrity.txt]
set report_handle [open $report_file w]
puts $report_handle "VLNV=[get_property VLNV $core]"
foreach interface [lsort [ipx::get_bus_interfaces -of_objects $core]] {
    puts $report_handle "BUS_INTERFACE=[get_property NAME $interface]"
}
close $report_handle

close_project
if {![info exists ::alexnet_composite_build]} {
    exit
}
