set_param general.maxThreads 16

if {[info exists ::lenet_stage_dir_override]} {
    set stage_dir [file normalize $::lenet_stage_dir_override]
} else {
    set stage_dir [file normalize [file join [file dirname [info script]] ..]]
}
set autonomous_dma 1
if {[info exists ::lenet_autonomous_dma]} {
    set autonomous_dma $::lenet_autonomous_dma
}
set build_dir [file join $stage_dir build]
set project_dir [file join $build_dir vivado]
set report_dir [file join $build_dir reports]
set ip_repo_dir [file join $build_dir ip_repo]
file mkdir $report_dir
file delete -force $project_dir

set board_repo /tools/Xilinx/2025.1/data/xhub/boards/XilinxBoardStore/boards/Xilinx
set_param board.repoPaths [list $board_repo]

create_project -force lenet5_kv260_system $project_dir \
    -part xck26-sfvc784-2LV-c
set_property board_part xilinx.com:kv260_som:part0:1.4 [current_project]
set_property ip_repo_paths [list $ip_repo_dir] [current_project]
update_ip_catalog

create_bd_design system

set ps [create_bd_cell -type ip \
    -vlnv xilinx.com:ip:zynq_ultra_ps_e:* zynq_ultra_ps_e_0]
apply_bd_automation -rule xilinx.com:bd_rule:zynq_ultra_ps_e \
    -config {apply_board_preset "1"} $ps
set_property -dict [list \
    CONFIG.PSU__FPGA_PL0_ENABLE {1} \
    CONFIG.PSU__FPGA_PL1_ENABLE {0} \
    CONFIG.PSU__CRL_APB__PL0_REF_CTRL__FREQMHZ {100} \
    CONFIG.PSU__USE__M_AXI_GP0 {1} \
    CONFIG.PSU__USE__M_AXI_GP1 {0} \
    CONFIG.PSU__MAXIGP0__DATA_WIDTH {128} \
    CONFIG.PSU__USE__S_AXI_GP2 {1} \
    CONFIG.PSU__SAXIGP2__DATA_WIDTH {128} \
    CONFIG.PSU__USE__IRQ0 {1} \
] $ps

set dma [create_bd_cell -type ip \
    -vlnv xilinx.com:ip:axi_dma:* axi_dma_0]
set_property -dict [list \
    CONFIG.c_include_sg {0} \
    CONFIG.c_include_mm2s {1} \
    CONFIG.c_include_s2mm {1} \
    CONFIG.c_include_mm2s_dre {0} \
    CONFIG.c_include_s2mm_dre {0} \
    CONFIG.c_m_axi_mm2s_data_width {128} \
    CONFIG.c_m_axi_s2mm_data_width {128} \
    CONFIG.c_m_axis_mm2s_tdata_width {128} \
    CONFIG.c_s_axis_s2mm_tdata_width {128} \
    CONFIG.c_mm2s_burst_size {64} \
    CONFIG.c_s2mm_burst_size {64} \
    CONFIG.c_sg_length_width {26} \
    CONFIG.c_addr_width {32} \
] $dma

set accelerator [create_bd_cell -type ip \
    -vlnv user.org:user:lenet5_axis_wrapper:1.0 lenet5_0]

set ctrl_ic [create_bd_cell -type ip \
    -vlnv xilinx.com:ip:smartconnect:* axi_ctrl]
if {$autonomous_dma} {
    set_property -dict [list CONFIG.NUM_SI {2} CONFIG.NUM_MI {2}] $ctrl_ic
} else {
    set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {2}] $ctrl_ic
}

set mem_ic [create_bd_cell -type ip \
    -vlnv xilinx.com:ip:smartconnect:* axi_mem]
set_property -dict [list CONFIG.NUM_SI {2} CONFIG.NUM_MI {1}] $mem_ic

set reset_ctrl [create_bd_cell -type ip \
    -vlnv xilinx.com:ip:proc_sys_reset:* rst_pl]
set_property CONFIG.C_AUX_RESET_HIGH {0} $reset_ctrl
set aux_reset_active_high \
    [get_property CONFIG.C_AUX_RESET_HIGH $reset_ctrl]
if {$aux_reset_active_high ne "0"} {
    error "Stage05 requires active-low aux_reset_in; got \
C_AUX_RESET_HIGH=$aux_reset_active_high"
}

set fabric_clk [create_bd_cell -type ip \
    -vlnv xilinx.com:ip:clk_wiz:* clk_wiz_150]
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
] $fabric_clk

set const_zero [create_bd_cell -type ip \
    -vlnv xilinx.com:ip:xlconstant:* const_zero]
set_property -dict [list CONFIG.CONST_WIDTH {1} CONFIG.CONST_VAL {0}] $const_zero
set const_one [create_bd_cell -type ip \
    -vlnv xilinx.com:ip:xlconstant:* const_one]
set_property -dict [list CONFIG.CONST_WIDTH {1} CONFIG.CONST_VAL {1}] $const_one

set irq_concat [create_bd_cell -type ip \
    -vlnv xilinx.com:ip:xlconcat:* irq_concat]
set_property -dict [list CONFIG.NUM_PORTS {3}] $irq_concat

# PS control master to the AXI DMA and accelerator register banks.
connect_bd_intf_net \
    [get_bd_intf_pins zynq_ultra_ps_e_0/M_AXI_HPM0_FPD] \
    [get_bd_intf_pins axi_ctrl/S00_AXI]
connect_bd_intf_net \
    [get_bd_intf_pins axi_ctrl/M00_AXI] \
    [get_bd_intf_pins axi_dma_0/S_AXI_LITE]
connect_bd_intf_net \
    [get_bd_intf_pins axi_ctrl/M01_AXI] \
    [get_bd_intf_pins lenet5_0/s_axi]
if {$autonomous_dma} {
    connect_bd_intf_net \
        [get_bd_intf_pins lenet5_0/m_axi_dma] \
        [get_bd_intf_pins axi_ctrl/S01_AXI]
}

# Both direct-register DMA memory masters share the non-coherent 128-bit HP0
# port. Software must flush input buffers and invalidate output buffers.
connect_bd_intf_net \
    [get_bd_intf_pins axi_dma_0/M_AXI_MM2S] \
    [get_bd_intf_pins axi_mem/S00_AXI]
connect_bd_intf_net \
    [get_bd_intf_pins axi_dma_0/M_AXI_S2MM] \
    [get_bd_intf_pins axi_mem/S01_AXI]
connect_bd_intf_net \
    [get_bd_intf_pins axi_mem/M00_AXI] \
    [get_bd_intf_pins zynq_ultra_ps_e_0/S_AXI_HP0_FPD]

# 128-bit streaming loop: DDR -> MM2S -> accelerator -> S2MM -> DDR.
connect_bd_intf_net \
    [get_bd_intf_pins axi_dma_0/M_AXIS_MM2S] \
    [get_bd_intf_pins lenet5_0/s_axis]
connect_bd_intf_net \
    [get_bd_intf_pins lenet5_0/m_axis] \
    [get_bd_intf_pins axi_dma_0/S_AXIS_S2MM]

# The stock Ubuntu firmware owns PL0 at 100 MHz. A PL MMCM generates the
# single 150 MHz domain used by control, DMA, streams, and compute.
connect_bd_net \
    [get_bd_pins zynq_ultra_ps_e_0/pl_clk0] \
    [get_bd_pins clk_wiz_150/clk_in1]
set clock_source [get_bd_pins clk_wiz_150/clk_out1]
foreach clock_sink [list \
    zynq_ultra_ps_e_0/maxihpm0_fpd_aclk \
    zynq_ultra_ps_e_0/saxihp0_fpd_aclk \
    axi_ctrl/aclk \
    axi_mem/aclk \
    axi_dma_0/s_axi_lite_aclk \
    axi_dma_0/m_axi_mm2s_aclk \
    axi_dma_0/m_axi_s2mm_aclk \
    lenet5_0/clk \
    rst_pl/slowest_sync_clk \
] {
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
    [get_bd_pins clk_wiz_150/locked] \
    [get_bd_pins rst_pl/dcm_locked]
set reset_source [get_bd_pins rst_pl/peripheral_aresetn]
foreach reset_sink [list \
    axi_ctrl/aresetn \
    axi_mem/aresetn \
    axi_dma_0/axi_resetn \
    lenet5_0/rst_n \
] {
    connect_bd_net $reset_source [get_bd_pins $reset_sink]
}

# Interrupt vector order is documented for software/device-tree generation.
# bit 0 = accelerator, bit 1 = DMA MM2S, bit 2 = DMA S2MM.
connect_bd_net [get_bd_pins lenet5_0/irq] [get_bd_pins irq_concat/In0]
connect_bd_net [get_bd_pins axi_dma_0/mm2s_introut] [get_bd_pins irq_concat/In1]
connect_bd_net [get_bd_pins axi_dma_0/s2mm_introut] [get_bd_pins irq_concat/In2]
connect_bd_net \
    [get_bd_pins irq_concat/dout] \
    [get_bd_pins zynq_ultra_ps_e_0/pl_ps_irq0]

# Fixed control map; memory data spaces are automatically mapped to PS DDR.
assign_bd_address -offset 0xA0000000 -range 0x00010000 \
    -target_address_space [get_bd_addr_spaces zynq_ultra_ps_e_0/Data] \
    [get_bd_addr_segs lenet5_0/s_axi/Reg] -force
assign_bd_address -offset 0xA0010000 -range 0x00010000 \
    -target_address_space [get_bd_addr_spaces zynq_ultra_ps_e_0/Data] \
    [get_bd_addr_segs axi_dma_0/S_AXI_LITE/Reg] -force
if {$autonomous_dma} {
    assign_bd_address -offset 0xA0010000 -range 0x00010000 \
        -target_address_space \
        [get_bd_addr_spaces lenet5_0/m_axi_dma] \
        [get_bd_addr_segs axi_dma_0/S_AXI_LITE/Reg] -force
    exclude_bd_addr_seg -target_address_space \
        [get_bd_addr_spaces lenet5_0/m_axi_dma] \
        [get_bd_addr_segs lenet5_0/s_axi/Reg]
}
foreach dma_space_name {axi_dma_0/Data_MM2S axi_dma_0/Data_S2MM} {
    assign_bd_address -offset 0x00000000 -range 0x80000000 \
        -target_address_space [get_bd_addr_spaces $dma_space_name] \
        [get_bd_addr_segs zynq_ultra_ps_e_0/SAXIGP2/HP0_DDR_LOW] -force
}

validate_bd_design

set ext_reset_active_high \
    [get_property CONFIG.C_EXT_RESET_HIGH $reset_ctrl]
set aux_reset_active_high \
    [get_property CONFIG.C_AUX_RESET_HIGH $reset_ctrl]
if {$ext_reset_active_high ne "0" || $aux_reset_active_high ne "0"} {
    error "Stage05 reset polarity propagation failed; got \
C_EXT_RESET_HIGH=$ext_reset_active_high \
C_AUX_RESET_HIGH=$aux_reset_active_high"
}
save_bd_design

set bd_file [get_files system.bd]
generate_target all $bd_file
make_wrapper -files $bd_file -top
add_files -norecurse \
    [file join $project_dir lenet5_kv260_system.gen sources_1 bd system hdl system_wrapper.v]
set_property top system_wrapper [current_fileset]
update_compile_order -fileset sources_1

set address_file [open [file join $report_dir address_map.txt] w]
puts $address_file "PS_CONTROL_ADDRESS_SPACE"
foreach segment [lsort [get_bd_addr_segs \
        -of_objects [get_bd_addr_spaces zynq_ultra_ps_e_0/Data]]] {
    puts $address_file "[get_property NAME $segment] \
OFFSET=[get_property OFFSET $segment] RANGE=[get_property RANGE $segment]"
}
puts $address_file "\nDMA_ADDRESS_SPACES"
foreach space_name {axi_dma_0/Data_MM2S axi_dma_0/Data_S2MM} {
    set space [get_bd_addr_spaces $space_name]
    puts $address_file $space_name
    foreach segment [lsort [get_bd_addr_segs -of_objects $space]] {
        puts $address_file "[get_property NAME $segment] \
OFFSET=[get_property OFFSET $segment] RANGE=[get_property RANGE $segment]"
    }
}
if {$autonomous_dma} {
    puts $address_file "\nACCELERATOR_DMA_CONTROL_ADDRESS_SPACE"
    set accelerator_dma_space \
        [get_bd_addr_spaces lenet5_0/m_axi_dma]
    foreach segment [lsort \
            [get_bd_addr_segs -of_objects $accelerator_dma_space]] {
        puts $address_file "[get_property NAME $segment] \
OFFSET=[get_property OFFSET $segment] RANGE=[get_property RANGE $segment]"
    }
}
close $address_file

set summary_file [open [file join $report_dir block_design.txt] w]
puts $summary_file "BOARD_PART=[get_property BOARD_PART [current_project]]"
puts $summary_file "PART=[get_property PART [current_project]]"
puts $summary_file "TOP=[get_property TOP [current_fileset]]"
puts $summary_file "PL0_FREQ_MHZ=[get_property CONFIG.PSU__CRL_APB__PL0_REF_CTRL__ACT_FREQMHZ $ps]"
puts $summary_file "FABRIC_CLOCK_REQUESTED_MHZ=150.000"
puts $summary_file "FABRIC_CLOCK_HZ=[get_property CONFIG.FREQ_HZ [get_bd_pins clk_wiz_150/clk_out1]]"
puts $summary_file "FABRIC_RESET_SOURCE=clk_wiz_150_locked"
puts $summary_file "EXTERNAL_RESET_ACTIVE_HIGH=[get_property CONFIG.C_EXT_RESET_HIGH $reset_ctrl]"
puts $summary_file "AUX_RESET_ACTIVE_HIGH=[get_property CONFIG.C_AUX_RESET_HIGH $reset_ctrl]"
puts $summary_file "EXTERNAL_RESET_INACTIVE_VALUE=1"
puts $summary_file "AUX_RESET_INACTIVE_VALUE=1"
puts $summary_file "MB_DEBUG_RESET_INACTIVE_VALUE=0"
puts $summary_file "HP0_WIDTH=[get_property CONFIG.PSU__SAXIGP2__DATA_WIDTH $ps]"
puts $summary_file "DMA_MM2S_MM_WIDTH=[get_property CONFIG.c_m_axi_mm2s_data_width $dma]"
puts $summary_file "DMA_S2MM_MM_WIDTH=[get_property CONFIG.c_m_axi_s2mm_data_width $dma]"
puts $summary_file "DMA_MM2S_AXIS_WIDTH=[get_property CONFIG.c_m_axis_mm2s_tdata_width $dma]"
puts $summary_file "DMA_S2MM_AXIS_WIDTH=[get_property CONFIG.c_s_axis_s2mm_tdata_width $dma]"
puts $summary_file "DMA_SCATTER_GATHER=[get_property CONFIG.c_include_sg $dma]"
puts $summary_file "DMA_MM2S_DRE=[get_property CONFIG.c_include_mm2s_dre $dma]"
puts $summary_file "DMA_S2MM_DRE=[get_property CONFIG.c_include_s2mm_dre $dma]"
puts $summary_file "AUTONOMOUS_DMA_SCHEDULER=$autonomous_dma"
close $summary_file

close_project
exit
