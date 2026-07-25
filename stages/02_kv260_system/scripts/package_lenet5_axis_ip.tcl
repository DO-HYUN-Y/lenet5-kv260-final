set_param general.maxThreads 8

if {[info exists ::lenet_stage_dir_override]} {
    set stage_dir [file normalize $::lenet_stage_dir_override]
} else {
    set stage_dir [file normalize [file join [file dirname [info script]] ..]]
}
set autonomous_dma 0
if {[info exists ::lenet_autonomous_dma]} {
    set autonomous_dma $::lenet_autonomous_dma
}
set repo_dir [file normalize [file join $stage_dir .. ..]]
set build_dir [file join $stage_dir build]
set package_project_dir [file join $build_dir ip_package_project]
set ip_root [file join $build_dir ip_repo lenet5_axis_wrapper_1.0]

file delete -force $package_project_dir
file delete -force $ip_root
file mkdir [file dirname $ip_root]
file mkdir [file join $build_dir reports]

create_project -force lenet5_axis_ip_package $package_project_dir \
    -part xck26-sfvc784-2LV-c

set rtl_files [list \
    activation_bank_set.sv \
    activation_scalar_reader.sv \
    fc_activation_reader.sv \
    maxpool2x2_int8.sv \
    banked_maxpool2x2.sv \
    activation_pingpong_subsystem.sv \
    window_gen_runtime.sv \
    fc_vector_gen.sv \
    dual_mode_weight_buffer.sv \
    skew_buf.sv \
    fc_group_skew.sv \
    packed_pe.sv \
    sa_packed_dual_mode.sv \
    column_result_router_runtime.sv \
    fc_result_router.sv \
    dual_lane_postprocess.sv \
    postprocess_array.sv \
    banked_activation_writer.sv \
    lenet_compute_core.sv \
    lenet_param_loader.sv \
    lenet_global_controller.sv \
    lenet5_accelerator_core.sv \
    lenet_dma_addr_gen.sv \
    axis_lenet_ingress.sv \
    axis_lenet_result.sv \
    lenet_axi_lite_regs.sv \
    lenet5_axis_wrapper.sv \
]
if {$autonomous_dma} {
    set wrapper_index [lsearch -exact $rtl_files lenet5_axis_wrapper.sv]
    set rtl_files [linsert $rtl_files $wrapper_index \
        axi_dma_simple_master.sv \
        lenet_system_scheduler.sv]
}

set source_paths {}
foreach rtl_file $rtl_files {
    lappend source_paths [file join $repo_dir rtl $rtl_file]
}
add_files -norecurse $source_paths
set_property top lenet5_axis_wrapper [current_fileset]
update_compile_order -fileset sources_1

ipx::package_project -root_dir $ip_root -vendor user.org -library user \
    -taxonomy /UserIP -import_files -set_current true
set core [ipx::current_core]
set_property name lenet5_axis_wrapper $core
set_property display_name {LeNet-5 AXI DMA Accelerator} $core
if {$autonomous_dma} {
    set_property description \
        {INT8 LeNet-5 accelerator with PL-controlled AXI DMA scheduler} \
        $core
    set_property core_revision 2 $core
} else {
    set_property description \
        {INT8 LeNet-5 accelerator with AXI4-Lite control and 128-bit AXI4-Stream data ports} \
        $core
    set_property core_revision 1 $core
}
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

# Remove any name-inferred duplicates before adding deterministic interfaces.
foreach interface_name {S_AXI M_AXI_DMA S_AXIS M_AXIS clk rst_n irq} {
    set existing [ipx::get_bus_interfaces $interface_name -of_objects $core]
    if {[llength $existing] != 0} {
        ipx::remove_bus_interface $interface_name $core
    }
}
foreach memory_map [ipx::get_memory_maps -of_objects $core] {
    ipx::remove_memory_map [get_property NAME $memory_map] $core
}
foreach address_space [ipx::get_address_spaces -of_objects $core] {
    ipx::remove_address_space [get_property NAME $address_space] $core
}

set s_axi_if [add_interface $core S_AXI \
    xilinx.com:interface:aximm:1.0 xilinx.com:interface:aximm_rtl:1.0 slave {
        AWADDR s_axi_awaddr
        AWVALID s_axi_awvalid
        AWREADY s_axi_awready
        WDATA s_axi_wdata
        WSTRB s_axi_wstrb
        WVALID s_axi_wvalid
        WREADY s_axi_wready
        BRESP s_axi_bresp
        BVALID s_axi_bvalid
        BREADY s_axi_bready
        ARADDR s_axi_araddr
        ARVALID s_axi_arvalid
        ARREADY s_axi_arready
        RDATA s_axi_rdata
        RRESP s_axi_rresp
        RVALID s_axi_rvalid
        RREADY s_axi_rready
    }]

if {$autonomous_dma} {
    set m_axi_dma_if [add_interface $core M_AXI_DMA \
        xilinx.com:interface:aximm:1.0 \
        xilinx.com:interface:aximm_rtl:1.0 master {
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
}

set s_axis_if [add_interface $core S_AXIS \
    xilinx.com:interface:axis:1.0 xilinx.com:interface:axis_rtl:1.0 slave {
        TDATA s_axis_tdata
        TKEEP s_axis_tkeep
        TVALID s_axis_tvalid
        TREADY s_axis_tready
        TLAST s_axis_tlast
    }]

set m_axis_if [add_interface $core M_AXIS \
    xilinx.com:interface:axis:1.0 xilinx.com:interface:axis_rtl:1.0 master {
        TDATA m_axis_tdata
        TKEEP m_axis_tkeep
        TVALID m_axis_tvalid
        TREADY m_axis_tready
        TLAST m_axis_tlast
    }]

set clock_if [add_interface $core clk \
    xilinx.com:signal:clock:1.0 xilinx.com:signal:clock_rtl:1.0 slave {
        CLK clk
    }]
set reset_if [add_interface $core rst_n \
    xilinx.com:signal:reset:1.0 xilinx.com:signal:reset_rtl:1.0 slave {
        RST rst_n
    }]
set irq_if [add_interface $core irq \
    xilinx.com:signal:interrupt:1.0 xilinx.com:signal:interrupt_rtl:1.0 master {
        INTERRUPT irq
    }]

ipx::associate_bus_interfaces -busif S_AXI -clock clk $core
if {$autonomous_dma} {
    ipx::associate_bus_interfaces -busif M_AXI_DMA -clock clk $core
}
ipx::associate_bus_interfaces -busif S_AXIS -clock clk $core
ipx::associate_bus_interfaces -busif M_AXIS -clock clk $core

set associated_reset [ipx::add_bus_parameter ASSOCIATED_RESET $clock_if]
set_property value rst_n $associated_reset
set reset_polarity [ipx::add_bus_parameter POLARITY $reset_if]
set_property value ACTIVE_LOW $reset_polarity
set irq_sensitivity [ipx::add_bus_parameter SENSITIVITY $irq_if]
set_property value LEVEL_HIGH $irq_sensitivity
foreach axis_interface [list $s_axis_if $m_axis_if] {
    set axis_bytes [ipx::add_bus_parameter TDATA_NUM_BYTES $axis_interface]
    set_property value 16 $axis_bytes
    set axis_keep [ipx::add_bus_parameter HAS_TKEEP $axis_interface]
    set_property value 1 $axis_keep
    set axis_last [ipx::add_bus_parameter HAS_TLAST $axis_interface]
    set_property value 1 $axis_last
}

set memory_map [ipx::add_memory_map S_AXI $core]
set_property slave_memory_map_ref S_AXI $s_axi_if
set address_block [ipx::add_address_block Reg $memory_map]
set_property range 65536 $address_block
set_property width 32 $address_block
set_property usage register $address_block
if {$autonomous_dma} {
    set dma_address_space [ipx::add_address_space m_axi_dma $core]
    set_property range 4294967296 $dma_address_space
    set_property width 32 $dma_address_space
    set_property master_address_space_ref m_axi_dma $m_axi_dma_if
}

ipx::create_xgui_files $core
ipx::update_checksums $core
ipx::check_integrity -quiet $core
ipx::save_core $core

set report_file [file join $build_dir reports ip_integrity.txt]
set report_handle [open $report_file w]
puts $report_handle "VLNV=[get_property VLNV $core]"
foreach interface [lsort [ipx::get_bus_interfaces -of_objects $core]] {
    puts $report_handle "BUS_INTERFACE=[get_property NAME $interface]"
}
close $report_handle

close_project
exit
