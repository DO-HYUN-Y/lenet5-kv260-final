set_param general.maxThreads 8

set stage_dir [file normalize [file join [file dirname [info script]] ..]]
set build_dir [file join $stage_dir build discovery]
file mkdir $build_dir

set board_repo /tools/Xilinx/2025.1/data/xhub/boards/XilinxBoardStore/boards/Xilinx
set_param board.repoPaths [list $board_repo]

create_project -force kv260_discovery $build_dir -part xck26-sfvc784-2LV-c
set_property board_part xilinx.com:kv260_som:part0:1.4 [current_project]
create_bd_design discovery

create_bd_cell -type ip -vlnv xilinx.com:ip:zynq_ultra_ps_e:* zynq_ultra_ps_e_0
apply_bd_automation -rule xilinx.com:bd_rule:zynq_ultra_ps_e \
    -config {apply_board_preset "1"} [get_bd_cells zynq_ultra_ps_e_0]

create_bd_cell -type ip -vlnv xilinx.com:ip:axi_dma:* axi_dma_0
create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:* smartconnect_0

set out_file [open [file join $stage_dir build reports discovery.txt] w]
puts $out_file "BOARD_PARTS"
puts $out_file [join [get_board_parts *kv260*] \n]
puts $out_file "\nPS_PROPERTIES"
foreach property_name [lsort [list_property [get_bd_cells zynq_ultra_ps_e_0]]] {
    if {[regexp {PL0|IRQ|USE__M_AXI|USE__S_AXI|MAXIGP|SAXIGP} $property_name]} {
        puts $out_file "$property_name=[get_property $property_name [get_bd_cells zynq_ultra_ps_e_0]]"
    }
}
puts $out_file "\nPS_PINS"
foreach pin_name [lsort [get_property NAME [get_bd_pins -of_objects [get_bd_cells zynq_ultra_ps_e_0]]]] {
    puts $out_file $pin_name
}
puts $out_file "\nPS_INTERFACE_PINS"
foreach pin_name [lsort [get_property NAME [get_bd_intf_pins -of_objects [get_bd_cells zynq_ultra_ps_e_0]]]] {
    puts $out_file $pin_name
}
puts $out_file "\nDMA_PROPERTIES"
foreach property_name [lsort [list_property [get_bd_cells axi_dma_0]]] {
    if {[string match "CONFIG.*" $property_name]} {
        puts $out_file "$property_name=[get_property $property_name [get_bd_cells axi_dma_0]]"
    }
}
puts $out_file "\nDMA_PINS"
foreach pin_name [lsort [get_property NAME [get_bd_pins -of_objects [get_bd_cells axi_dma_0]]]] {
    puts $out_file $pin_name
}
puts $out_file "\nDMA_INTERFACE_PINS"
foreach pin_name [lsort [get_property NAME [get_bd_intf_pins -of_objects [get_bd_cells axi_dma_0]]]] {
    puts $out_file $pin_name
}
puts $out_file "\nSMARTCONNECT_PROPERTIES"
foreach property_name [lsort [list_property [get_bd_cells smartconnect_0]]] {
    if {[string match "CONFIG.*" $property_name]} {
        puts $out_file "$property_name=[get_property $property_name [get_bd_cells smartconnect_0]]"
    }
}
puts $out_file "\nSMARTCONNECT_PINS"
foreach pin_name [lsort [get_property NAME [get_bd_pins -of_objects [get_bd_cells smartconnect_0]]]] {
    puts $out_file $pin_name
}
puts $out_file "\nSMARTCONNECT_INTERFACE_PINS"
foreach pin_name [lsort [get_property NAME [get_bd_intf_pins -of_objects [get_bd_cells smartconnect_0]]]] {
    puts $out_file $pin_name
}
close $out_file

close_project
exit
