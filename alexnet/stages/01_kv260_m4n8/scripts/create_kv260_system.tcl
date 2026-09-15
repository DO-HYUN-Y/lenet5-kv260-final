set_param general.maxThreads 8

if {[info exists ::alexnet_stage_dir_override]} {
    set stage_dir [file normalize $::alexnet_stage_dir_override]
} else {
    set stage_dir [file normalize [file join [file dirname [info script]] ..]]
}
set build_dir [file join $stage_dir build]
set project_dir [file join $build_dir vivado]
set report_dir [file join $build_dir reports]
set ip_repo_dir [file join $build_dir ip_repo]
set use_four_hp 0
if {[info exists ::alexnet_use_four_hp]} {
    set use_four_hp $::alexnet_use_four_hp
}
file mkdir $report_dir
file delete -force $project_dir

if {[info exists ::env(XILINX_VIVADO)]} {
    set board_repo [file join $::env(XILINX_VIVADO) data xhub boards \
        XilinxBoardStore boards Xilinx]
    if {[file isdirectory $board_repo]} {
        set_param board.repoPaths [list $board_repo]
    }
}

create_project -force alexnet_m4n8_kv260 $project_dir \
    -part xck26-sfvc784-2LV-c
set_property board_part xilinx.com:kv260_som:part0:1.4 [current_project]
set_property ip_repo_paths [list $ip_repo_dir] [current_project]
update_ip_catalog

create_bd_design system

set ps [create_bd_cell -type ip \
    -vlnv xilinx.com:ip:zynq_ultra_ps_e:* zynq_ultra_ps_e_0]
apply_bd_automation -rule xilinx.com:bd_rule:zynq_ultra_ps_e \
    -config {apply_board_preset "1"} $ps
set ps_config [list \
    CONFIG.PSU__FPGA_PL0_ENABLE {1} \
    CONFIG.PSU__FPGA_PL1_ENABLE {0} \
    CONFIG.PSU__CRL_APB__PL0_REF_CTRL__FREQMHZ {100} \
    CONFIG.PSU__USE__M_AXI_GP0 {1} \
    CONFIG.PSU__USE__M_AXI_GP1 {0} \
    CONFIG.PSU__MAXIGP0__DATA_WIDTH {128} \
    CONFIG.PSU__USE__S_AXI_GP2 {1} \
    CONFIG.PSU__SAXIGP2__DATA_WIDTH {128} \
    CONFIG.PSU__USE__IRQ0 {1} \
]
if {$use_four_hp} {
    lappend ps_config \
        CONFIG.PSU__USE__S_AXI_GP3 {1} \
        CONFIG.PSU__USE__S_AXI_GP4 {1} \
        CONFIG.PSU__USE__S_AXI_GP5 {1} \
        CONFIG.PSU__SAXIGP3__DATA_WIDTH {128} \
        CONFIG.PSU__SAXIGP4__DATA_WIDTH {128} \
        CONFIG.PSU__SAXIGP5__DATA_WIDTH {128}
}
set_property -dict $ps_config $ps

# Main model/activation DMA. The accelerator is its autonomous register owner.
# DRE is required because AlexNet N8 payload descriptors are eight-byte aligned
# while the main stream and memory ports are 128 bits wide.
set main_dma [create_bd_cell -type ip \
    -vlnv xilinx.com:ip:axi_dma:* axi_dma_main]
set_property -dict [list \
    CONFIG.c_include_sg {0} \
    CONFIG.c_include_mm2s {1} \
    CONFIG.c_include_s2mm {1} \
    CONFIG.c_include_mm2s_dre {1} \
    CONFIG.c_include_s2mm_dre {1} \
    CONFIG.c_m_axi_mm2s_data_width {128} \
    CONFIG.c_m_axi_s2mm_data_width {128} \
    CONFIG.c_m_axis_mm2s_tdata_width {128} \
    CONFIG.c_s_axis_s2mm_tdata_width {128} \
    CONFIG.c_mm2s_burst_size {64} \
    CONFIG.c_s2mm_burst_size {64} \
    CONFIG.c_sg_length_width {26} \
    CONFIG.c_addr_width {32} \
] $main_dma

# Camera DMA is PS-owned and MM2S-only. One 64-bit DDR beat represents one
# RGB pixel plus five padding bytes, so no DRE is needed for its fixed layout.
set camera_dma [create_bd_cell -type ip \
    -vlnv xilinx.com:ip:axi_dma:* axi_dma_camera]
set_property -dict [list \
    CONFIG.c_include_sg {0} \
    CONFIG.c_include_mm2s {1} \
    CONFIG.c_include_s2mm {0} \
    CONFIG.c_include_mm2s_dre {0} \
    CONFIG.c_m_axi_mm2s_data_width {128} \
    CONFIG.c_m_axis_mm2s_tdata_width {64} \
    CONFIG.c_mm2s_burst_size {64} \
    CONFIG.c_sg_length_width {26} \
    CONFIG.c_addr_width {32} \
] $camera_dma

set accelerator [create_bd_cell -type ip \
    -vlnv user.org:user:alexnet_m4n8_accelerator:1.0 \
    alexnet_m4n8_0]
set camera_adapter [create_bd_cell -type ip \
    -vlnv user.org:user:alexnet_camera_rgbx_adapter:1.0 \
    camera_rgbx_0]

set ctrl_ic [create_bd_cell -type ip \
    -vlnv xilinx.com:ip:smartconnect:* axi_ctrl]
set_property -dict [list CONFIG.NUM_SI {2} CONFIG.NUM_MI {3}] $ctrl_ic

if {!$use_four_hp} {
    set mem_ic [create_bd_cell -type ip \
        -vlnv xilinx.com:ip:smartconnect:* axi_mem]
    set_property -dict [list CONFIG.NUM_SI {3} CONFIG.NUM_MI {1}] $mem_ic
}

set reset_ctrl [create_bd_cell -type ip \
    -vlnv xilinx.com:ip:proc_sys_reset:* rst_pl]
set fabric_clk [create_bd_cell -type ip \
    -vlnv xilinx.com:ip:clk_wiz:* clk_wiz_200]
set_property -dict [list \
    CONFIG.PRIMITIVE {MMCM} \
    CONFIG.PRIM_SOURCE {No_buffer} \
    CONFIG.PRIM_IN_FREQ {99.999001} \
    CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {200.000} \
    CONFIG.OVERRIDE_MMCM {true} \
    CONFIG.MMCM_DIVCLK_DIVIDE {1} \
    CONFIG.MMCM_CLKFBOUT_MULT_F {10.000} \
    CONFIG.MMCM_CLKOUT0_DIVIDE_F {5.000} \
    CONFIG.USE_LOCKED {true} \
    CONFIG.USE_RESET {false} \
] $fabric_clk
set const_zero [create_bd_cell -type ip \
    -vlnv xilinx.com:ip:xlconstant:* const_zero]
set_property -dict [list CONFIG.CONST_WIDTH {1} CONFIG.CONST_VAL {0}] \
    $const_zero
set const_one [create_bd_cell -type ip \
    -vlnv xilinx.com:ip:xlconstant:* const_one]
set_property -dict [list CONFIG.CONST_WIDTH {1} CONFIG.CONST_VAL {1}] \
    $const_one
set irq_concat [create_bd_cell -type ip \
    -vlnv xilinx.com:ip:xlconcat:* irq_concat]
set_property -dict [list CONFIG.NUM_PORTS {5}] $irq_concat

# PS controls the accelerator and may inspect both DMA register banks while
# idle. The accelerator's master reaches only the main DMA register bank.
connect_bd_intf_net \
    [get_bd_intf_pins zynq_ultra_ps_e_0/M_AXI_HPM0_FPD] \
    [get_bd_intf_pins axi_ctrl/S00_AXI]
connect_bd_intf_net \
    [get_bd_intf_pins alexnet_m4n8_0/M_AXI_DMA] \
    [get_bd_intf_pins axi_ctrl/S01_AXI]
connect_bd_intf_net \
    [get_bd_intf_pins axi_ctrl/M00_AXI] \
    [get_bd_intf_pins alexnet_m4n8_0/S_AXI_CTRL]
connect_bd_intf_net \
    [get_bd_intf_pins axi_ctrl/M01_AXI] \
    [get_bd_intf_pins axi_dma_main/S_AXI_LITE]
connect_bd_intf_net \
    [get_bd_intf_pins axi_ctrl/M02_AXI] \
    [get_bd_intf_pins axi_dma_camera/S_AXI_LITE]

# The compatibility build shares HP0.  The wide-array probe removes that
# arbitration point: main read, main write and camera read receive HP0/1/2.
# HP3 is enabled and clocked as the reserved fourth path for the separate
# weight MM2S master used by the subsequent full-graph integration.
if {$use_four_hp} {
    connect_bd_intf_net \
        [get_bd_intf_pins axi_dma_main/M_AXI_MM2S] \
        [get_bd_intf_pins zynq_ultra_ps_e_0/S_AXI_HP0_FPD]
    connect_bd_intf_net \
        [get_bd_intf_pins axi_dma_main/M_AXI_S2MM] \
        [get_bd_intf_pins zynq_ultra_ps_e_0/S_AXI_HP1_FPD]
    connect_bd_intf_net \
        [get_bd_intf_pins axi_dma_camera/M_AXI_MM2S] \
        [get_bd_intf_pins zynq_ultra_ps_e_0/S_AXI_HP2_FPD]
} else {
    connect_bd_intf_net \
        [get_bd_intf_pins axi_dma_main/M_AXI_MM2S] \
        [get_bd_intf_pins axi_mem/S00_AXI]
    connect_bd_intf_net \
        [get_bd_intf_pins axi_dma_main/M_AXI_S2MM] \
        [get_bd_intf_pins axi_mem/S01_AXI]
    connect_bd_intf_net \
        [get_bd_intf_pins axi_dma_camera/M_AXI_MM2S] \
        [get_bd_intf_pins axi_mem/S02_AXI]
    connect_bd_intf_net \
        [get_bd_intf_pins axi_mem/M00_AXI] \
        [get_bd_intf_pins zynq_ultra_ps_e_0/S_AXI_HP0_FPD]
}

# Main payload loop and independent camera stream.
connect_bd_intf_net \
    [get_bd_intf_pins axi_dma_main/M_AXIS_MM2S] \
    [get_bd_intf_pins alexnet_m4n8_0/S_AXIS_MM2S]
connect_bd_intf_net \
    [get_bd_intf_pins alexnet_m4n8_0/M_AXIS_S2MM] \
    [get_bd_intf_pins axi_dma_main/S_AXIS_S2MM]
connect_bd_intf_net \
    [get_bd_intf_pins axi_dma_camera/M_AXIS_MM2S] \
    [get_bd_intf_pins camera_rgbx_0/S_AXIS]
connect_bd_intf_net \
    [get_bd_intf_pins camera_rgbx_0/M_AXIS] \
    [get_bd_intf_pins alexnet_m4n8_0/S_AXIS_CAMERA]

# Stock KV260 Ubuntu owns PL0 at approximately 100 MHz. One PL MMCM doubles
# that reference and provides the only 200 MHz control/DMA/compute domain.
connect_bd_net \
    [get_bd_pins zynq_ultra_ps_e_0/pl_clk0] \
    [get_bd_pins clk_wiz_200/clk_in1]
set clock_source [get_bd_pins clk_wiz_200/clk_out1]
set clock_sinks [list \
    zynq_ultra_ps_e_0/maxihpm0_fpd_aclk \
    zynq_ultra_ps_e_0/saxihp0_fpd_aclk \
    axi_ctrl/aclk \
    axi_dma_main/s_axi_lite_aclk \
    axi_dma_main/m_axi_mm2s_aclk \
    axi_dma_main/m_axi_s2mm_aclk \
    axi_dma_camera/s_axi_lite_aclk \
    axi_dma_camera/m_axi_mm2s_aclk \
    alexnet_m4n8_0/aclk \
    camera_rgbx_0/aclk \
    rst_pl/slowest_sync_clk \
]
if {$use_four_hp} {
    lappend clock_sinks \
        zynq_ultra_ps_e_0/saxihp1_fpd_aclk \
        zynq_ultra_ps_e_0/saxihp2_fpd_aclk \
        zynq_ultra_ps_e_0/saxihp3_fpd_aclk
} else {
    lappend clock_sinks axi_mem/aclk
}
foreach clock_sink $clock_sinks {
    connect_bd_net $clock_source [get_bd_pins $clock_sink]
}

connect_bd_net \
    [get_bd_pins const_one/dout] \
    [get_bd_pins rst_pl/ext_reset_in] \
    [get_bd_pins rst_pl/aux_reset_in]
connect_bd_net \
    [get_bd_pins const_zero/dout] \
    [get_bd_pins rst_pl/mb_debug_sys_rst]
connect_bd_net \
    [get_bd_pins clk_wiz_200/locked] \
    [get_bd_pins rst_pl/dcm_locked]
set reset_source [get_bd_pins rst_pl/peripheral_aresetn]
set reset_sinks [list \
    axi_ctrl/aresetn \
    axi_dma_main/axi_resetn \
    axi_dma_camera/axi_resetn \
    alexnet_m4n8_0/aresetn \
    camera_rgbx_0/aresetn \
]
if {!$use_four_hp} {
    lappend reset_sinks axi_mem/aresetn
}
foreach reset_sink $reset_sinks {
    connect_bd_net $reset_source [get_bd_pins $reset_sink]
}

# IRQ bit order is a software ABI.
# 0 accelerator, 1 main MM2S, 2 main S2MM, 3 camera MM2S,
# 4 malformed camera RGBX frame.
connect_bd_net [get_bd_pins alexnet_m4n8_0/irq] \
    [get_bd_pins irq_concat/In0]
connect_bd_net [get_bd_pins axi_dma_main/mm2s_introut] \
    [get_bd_pins irq_concat/In1]
connect_bd_net [get_bd_pins axi_dma_main/s2mm_introut] \
    [get_bd_pins irq_concat/In2]
connect_bd_net [get_bd_pins axi_dma_camera/mm2s_introut] \
    [get_bd_pins irq_concat/In3]
connect_bd_net [get_bd_pins camera_rgbx_0/format_error] \
    [get_bd_pins irq_concat/In4]
connect_bd_net [get_bd_pins irq_concat/dout] \
    [get_bd_pins zynq_ultra_ps_e_0/pl_ps_irq0]

# Fixed PS control map.
assign_bd_address -offset 0xA0000000 -range 0x00010000 \
    -target_address_space [get_bd_addr_spaces zynq_ultra_ps_e_0/Data] \
    [get_bd_addr_segs alexnet_m4n8_0/S_AXI_CTRL/Reg] -force
assign_bd_address -offset 0xA0010000 -range 0x00010000 \
    -target_address_space [get_bd_addr_spaces zynq_ultra_ps_e_0/Data] \
    [get_bd_addr_segs axi_dma_main/S_AXI_LITE/Reg] -force
assign_bd_address -offset 0xA0020000 -range 0x00010000 \
    -target_address_space [get_bd_addr_spaces zynq_ultra_ps_e_0/Data] \
    [get_bd_addr_segs axi_dma_camera/S_AXI_LITE/Reg] -force

assign_bd_address -offset 0xA0010000 -range 0x00010000 \
    -target_address_space [get_bd_addr_spaces alexnet_m4n8_0/M_AXI_DMA] \
    [get_bd_addr_segs axi_dma_main/S_AXI_LITE/Reg] -force
exclude_bd_addr_seg -target_address_space \
    [get_bd_addr_spaces alexnet_m4n8_0/M_AXI_DMA] \
    [get_bd_addr_segs alexnet_m4n8_0/S_AXI_CTRL/Reg]
exclude_bd_addr_seg -target_address_space \
    [get_bd_addr_spaces alexnet_m4n8_0/M_AXI_DMA] \
    [get_bd_addr_segs axi_dma_camera/S_AXI_LITE/Reg]

if {$use_four_hp} {
    foreach {dma_space_name ps_segment} [list \
            axi_dma_main/Data_MM2S SAXIGP2/HP0_DDR_LOW \
            axi_dma_main/Data_S2MM SAXIGP3/HP1_DDR_LOW \
            axi_dma_camera/Data_MM2S SAXIGP4/HP2_DDR_LOW] {
        assign_bd_address -offset 0x00000000 -range 0x80000000 \
            -target_address_space [get_bd_addr_spaces $dma_space_name] \
            [get_bd_addr_segs zynq_ultra_ps_e_0/$ps_segment] -force
    }
} else {
    foreach dma_space_name [list \
            axi_dma_main/Data_MM2S axi_dma_main/Data_S2MM \
            axi_dma_camera/Data_MM2S] {
        assign_bd_address -offset 0x00000000 -range 0x80000000 \
            -target_address_space [get_bd_addr_spaces $dma_space_name] \
            [get_bd_addr_segs \
                zynq_ultra_ps_e_0/SAXIGP2/HP0_DDR_LOW] -force
    }
}

validate_bd_design
set ext_reset_active_high \
    [get_property CONFIG.C_EXT_RESET_HIGH $reset_ctrl]
set aux_reset_active_high \
    [get_property CONFIG.C_AUX_RESET_HIGH $reset_ctrl]
if {$ext_reset_active_high ne "0" || $aux_reset_active_high ne "0"} {
    error "KV260 reset polarity mismatch: C_EXT_RESET_HIGH=$ext_reset_active_high C_AUX_RESET_HIGH=$aux_reset_active_high"
}
save_bd_design

set bd_file [get_files system.bd]
generate_target all $bd_file
make_wrapper -files $bd_file -top
add_files -norecurse [file join $project_dir \
    alexnet_m4n8_kv260.gen sources_1 bd system hdl system_wrapper.v]
set_property top system_wrapper [current_fileset]
update_compile_order -fileset sources_1

set address_file [open [file join $report_dir address_map.txt] w]
puts $address_file "PS_CONTROL_ADDRESS_SPACE"
foreach segment [lsort [get_bd_addr_segs \
        -of_objects [get_bd_addr_spaces zynq_ultra_ps_e_0/Data]]] {
    puts $address_file "[get_property NAME $segment] \
OFFSET=[get_property OFFSET $segment] RANGE=[get_property RANGE $segment]"
}
puts $address_file "\nACCELERATOR_DMA_CONTROL_ADDRESS_SPACE"
foreach segment [lsort [get_bd_addr_segs -of_objects \
        [get_bd_addr_spaces alexnet_m4n8_0/M_AXI_DMA]]] {
    puts $address_file "[get_property NAME $segment] \
OFFSET=[get_property OFFSET $segment] RANGE=[get_property RANGE $segment]"
}
puts $address_file "\nDMA_DDR_ADDRESS_SPACES"
foreach space_name [list \
        axi_dma_main/Data_MM2S axi_dma_main/Data_S2MM \
        axi_dma_camera/Data_MM2S] {
    puts $address_file $space_name
    foreach segment [lsort [get_bd_addr_segs -of_objects \
            [get_bd_addr_spaces $space_name]]] {
        puts $address_file "[get_property NAME $segment] \
OFFSET=[get_property OFFSET $segment] RANGE=[get_property RANGE $segment]"
    }
}
close $address_file

set summary_file [open [file join $report_dir block_design.txt] w]
puts $summary_file "BOARD_PART=[get_property BOARD_PART [current_project]]"
puts $summary_file "PART=[get_property PART [current_project]]"
puts $summary_file "TOP=[get_property TOP [current_fileset]]"
puts $summary_file \
    "PL0_FREQ_MHZ=[get_property CONFIG.PSU__CRL_APB__PL0_REF_CTRL__ACT_FREQMHZ $ps]"
puts $summary_file \
    "FABRIC_CLOCK_HZ=[get_property CONFIG.FREQ_HZ [get_bd_pins clk_wiz_200/clk_out1]]"
puts $summary_file "FABRIC_RESET_SOURCE=clk_wiz_200_locked"
puts $summary_file "EXTERNAL_RESET_ACTIVE_HIGH=$ext_reset_active_high"
puts $summary_file "AUX_RESET_ACTIVE_HIGH=$aux_reset_active_high"
puts $summary_file "EXTERNAL_RESET_INACTIVE_VALUE=1"
puts $summary_file "AUX_RESET_INACTIVE_VALUE=1"
puts $summary_file \
    "HP0_WIDTH=[get_property CONFIG.PSU__SAXIGP2__DATA_WIDTH $ps]"
puts $summary_file "FOUR_HP_ENABLED=$use_four_hp"
if {$use_four_hp} {
    puts $summary_file \
        "HP1_WIDTH=[get_property CONFIG.PSU__SAXIGP3__DATA_WIDTH $ps]"
    puts $summary_file \
        "HP2_WIDTH=[get_property CONFIG.PSU__SAXIGP4__DATA_WIDTH $ps]"
    puts $summary_file \
        "HP3_WIDTH=[get_property CONFIG.PSU__SAXIGP5__DATA_WIDTH $ps]"
    puts $summary_file "HP0_MASTER=MAIN_MM2S"
    puts $summary_file "HP1_MASTER=MAIN_S2MM"
    puts $summary_file "HP2_MASTER=CAMERA_MM2S"
    puts $summary_file "HP3_MASTER=RESERVED_WEIGHT_MM2S"
}
puts $summary_file \
    "MAIN_DMA_MM2S_DRE=[get_property CONFIG.c_include_mm2s_dre $main_dma]"
puts $summary_file \
    "MAIN_DMA_S2MM_DRE=[get_property CONFIG.c_include_s2mm_dre $main_dma]"
puts $summary_file "MAIN_DMA_AXIS_WIDTH=128"
puts $summary_file "CAMERA_DMA_AXIS_WIDTH=64"
puts $summary_file "CAMERA_DMA_MM2S_ONLY=1"
puts $summary_file "CAMERA_LAYOUT=224x224_RGB_INT8_IN_8_BYTE_WORD"
puts $summary_file "CAMERA_BUFFER_BYTES=401408"
puts $summary_file "CAMERA_VALID_LANE_MASK=0x07"
puts $summary_file "ACCELERATOR_M=8"
if {$use_four_hp} {
    puts $summary_file "ACCELERATOR_N=126_LOGICAL_128_PHYSICAL"
} else {
    puts $summary_file "ACCELERATOR_N=8"
}
close $summary_file

close_project
if {![info exists ::alexnet_composite_build]} {
    exit
}
