set_param general.maxThreads 8

if {[info exists ::alexnet_stage_dir_override]} {
    set stage_dir [file normalize $::alexnet_stage_dir_override]
} else {
    set stage_dir [file normalize [file join [file dirname [info script]] ..]]
}
set alexnet_dir [file normalize [file join $stage_dir .. ..]]
set repo_dir [file normalize [file join $alexnet_dir ..]]
set build_dir [file join $stage_dir build]
set package_project_dir [file join $build_dir ip_package_accelerator]
set ip_root [file join $build_dir ip_repo alexnet_m4n8_accelerator_1.0]
set accelerator_top alexnet_m4n8_accelerator_top
set accelerator_display_name {AlexNet M8xN8 DMA Accelerator}
set accelerator_description \
    {INT8 AlexNet M8xN8 accelerator with autonomous main AXI DMA control}
if {[info exists ::alexnet_accelerator_top_override]} {
    set accelerator_top $::alexnet_accelerator_top_override
}
if {[info exists ::alexnet_accelerator_display_name_override]} {
    set accelerator_display_name $::alexnet_accelerator_display_name_override
}
if {[info exists ::alexnet_accelerator_description_override]} {
    set accelerator_description $::alexnet_accelerator_description_override
}

file delete -force $package_project_dir
file delete -force $ip_root
file mkdir [file dirname $ip_root]
file mkdir [file join $build_dir reports]

create_project -force alexnet_m4n8_ip_package $package_project_dir \
    -part xck26-sfvc784-2LV-c

set rtl_sources [lsort [glob [file join $alexnet_dir rtl * *.sv]]]
lappend rtl_sources [file join $repo_dir rtl axi_dma_simple_master.sv]
add_files -norecurse $rtl_sources
set_property top $accelerator_top [current_fileset]
update_compile_order -fileset sources_1

ipx::package_project -root_dir $ip_root -vendor user.org -library user \
    -taxonomy /UserIP -import_files -set_current true
set core [ipx::current_core]
set_property name alexnet_m4n8_accelerator $core
set_property display_name $accelerator_display_name $core
set_property description $accelerator_description $core
set_property core_revision 2 $core
set_property version 1.0 $core
set_property supported_families {zynquplus Production} $core

proc add_port_mapping {interface logical physical} {
    ipx::add_port_map $logical $interface
    set_property physical_name $physical \
        [ipx::get_port_maps $logical -of_objects $interface]
}

proc add_interface {core name bus_vlnv abstraction_vlnv mode mappings} {
    set interface [ipx::add_bus_interface $name $core]
    set_property bus_type_vlnv $bus_vlnv $interface
    set_property abstraction_type_vlnv $abstraction_vlnv $interface
    set_property interface_mode $mode $interface
    foreach {logical physical} $mappings {
        add_port_mapping $interface $logical $physical
    }
    return $interface
}

foreach interface [ipx::get_bus_interfaces -of_objects $core] {
    ipx::remove_bus_interface [get_property NAME $interface] $core
}
foreach memory_map [ipx::get_memory_maps -of_objects $core] {
    ipx::remove_memory_map [get_property NAME $memory_map] $core
}
foreach address_space [ipx::get_address_spaces -of_objects $core] {
    ipx::remove_address_space [get_property NAME $address_space] $core
}

set s_axi_ctrl_if [add_interface $core S_AXI_CTRL \
    xilinx.com:interface:aximm:1.0 xilinx.com:interface:aximm_rtl:1.0 slave {
        AWADDR s_axi_ctrl_awaddr
        AWPROT s_axi_ctrl_awprot
        AWVALID s_axi_ctrl_awvalid
        AWREADY s_axi_ctrl_awready
        WDATA s_axi_ctrl_wdata
        WSTRB s_axi_ctrl_wstrb
        WVALID s_axi_ctrl_wvalid
        WREADY s_axi_ctrl_wready
        BRESP s_axi_ctrl_bresp
        BVALID s_axi_ctrl_bvalid
        BREADY s_axi_ctrl_bready
        ARADDR s_axi_ctrl_araddr
        ARPROT s_axi_ctrl_arprot
        ARVALID s_axi_ctrl_arvalid
        ARREADY s_axi_ctrl_arready
        RDATA s_axi_ctrl_rdata
        RRESP s_axi_ctrl_rresp
        RVALID s_axi_ctrl_rvalid
        RREADY s_axi_ctrl_rready
    }]

set m_axi_dma_if [add_interface $core M_AXI_DMA \
    xilinx.com:interface:aximm:1.0 xilinx.com:interface:aximm_rtl:1.0 master {
        AWADDR m_axi_dma_awaddr
        AWPROT m_axi_dma_awprot
        AWVALID m_axi_dma_awvalid
        AWREADY m_axi_dma_awready
        WDATA m_axi_dma_wdata
        WSTRB m_axi_dma_wstrb
        WVALID m_axi_dma_wvalid
        WREADY m_axi_dma_wready
        BRESP m_axi_dma_bresp
        BVALID m_axi_dma_bvalid
        BREADY m_axi_dma_bready
        ARADDR m_axi_dma_araddr
        ARPROT m_axi_dma_arprot
        ARVALID m_axi_dma_arvalid
        ARREADY m_axi_dma_arready
        RDATA m_axi_dma_rdata
        RRESP m_axi_dma_rresp
        RVALID m_axi_dma_rvalid
        RREADY m_axi_dma_rready
    }]

set s_axis_camera_if [add_interface $core S_AXIS_CAMERA \
    xilinx.com:interface:axis:1.0 xilinx.com:interface:axis_rtl:1.0 slave {
        TDATA s_axis_camera_tdata
        TKEEP s_axis_camera_tkeep
        TVALID s_axis_camera_tvalid
        TREADY s_axis_camera_tready
        TLAST s_axis_camera_tlast
    }]
set s_axis_mm2s_if [add_interface $core S_AXIS_MM2S \
    xilinx.com:interface:axis:1.0 xilinx.com:interface:axis_rtl:1.0 slave {
        TDATA s_axis_mm2s_tdata
        TKEEP s_axis_mm2s_tkeep
        TVALID s_axis_mm2s_tvalid
        TREADY s_axis_mm2s_tready
        TLAST s_axis_mm2s_tlast
    }]
set m_axis_s2mm_if [add_interface $core M_AXIS_S2MM \
    xilinx.com:interface:axis:1.0 xilinx.com:interface:axis_rtl:1.0 master {
        TDATA m_axis_s2mm_tdata
        TKEEP m_axis_s2mm_tkeep
        TVALID m_axis_s2mm_tvalid
        TREADY m_axis_s2mm_tready
        TLAST m_axis_s2mm_tlast
    }]

set clock_if [add_interface $core aclk \
    xilinx.com:signal:clock:1.0 xilinx.com:signal:clock_rtl:1.0 slave {
        CLK aclk
    }]
set reset_if [add_interface $core aresetn \
    xilinx.com:signal:reset:1.0 xilinx.com:signal:reset_rtl:1.0 slave {
        RST aresetn
    }]
set irq_if [add_interface $core irq \
    xilinx.com:signal:interrupt:1.0 \
    xilinx.com:signal:interrupt_rtl:1.0 master {
        INTERRUPT irq
    }]

foreach busif {S_AXI_CTRL M_AXI_DMA S_AXIS_CAMERA S_AXIS_MM2S M_AXIS_S2MM} {
    ipx::associate_bus_interfaces -busif $busif -clock aclk $core
}
set associated_reset [ipx::add_bus_parameter ASSOCIATED_RESET $clock_if]
set_property value aresetn $associated_reset
set reset_polarity [ipx::add_bus_parameter POLARITY $reset_if]
set_property value ACTIVE_LOW $reset_polarity
set irq_sensitivity [ipx::add_bus_parameter SENSITIVITY $irq_if]
set_property value LEVEL_HIGH $irq_sensitivity

foreach {axis_interface axis_bytes} [list \
        $s_axis_camera_if 8 $s_axis_mm2s_if 16 $m_axis_s2mm_if 16] {
    set data_bytes [ipx::add_bus_parameter TDATA_NUM_BYTES $axis_interface]
    set_property value $axis_bytes $data_bytes
    set has_keep [ipx::add_bus_parameter HAS_TKEEP $axis_interface]
    set_property value 1 $has_keep
    set has_last [ipx::add_bus_parameter HAS_TLAST $axis_interface]
    set_property value 1 $has_last
}

set memory_map [ipx::add_memory_map S_AXI_CTRL $core]
set_property slave_memory_map_ref S_AXI_CTRL $s_axi_ctrl_if
set address_block [ipx::add_address_block Reg $memory_map]
set_property range 65536 $address_block
set_property width 32 $address_block
set_property usage register $address_block

set dma_address_space [ipx::add_address_space M_AXI_DMA $core]
set_property range 4294967296 $dma_address_space
set_property width 32 $dma_address_space
set_property master_address_space_ref M_AXI_DMA $m_axi_dma_if

ipx::create_xgui_files $core
ipx::update_checksums $core
ipx::check_integrity $core
ipx::save_core $core

set report_file [file join $build_dir reports accelerator_ip_integrity.txt]
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
