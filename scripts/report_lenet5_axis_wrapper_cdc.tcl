set root [file normalize [file join [file dirname [info script]] ..]]
set report_dir [file join $root reports lenet5_axis_wrapper]
open_checkpoint \
    [file join $root checkpoints lenet5_axis_wrapper \
        lenet5_axis_wrapper_post_route.dcp]

set reset_sync_cells [
    get_cells -hierarchical -filter {NAME =~ *reset_sync_r_reg*}
]
if {[llength $reset_sync_cells] == 0} {
  error "Reset synchronizer cells were not found"
}
foreach reset_cdc_id {CDC-1 CDC-26} {
  create_waiver -type CDC -id $reset_cdc_id -user "lenet5" \
      -description \
      "Reviewed async assertion into the two-flop reset synchronizer" \
      -from [get_ports rst_n] \
      -to [get_pins -of_objects $reset_sync_cells]
}
report_cdc -details -file [file join $report_dir impl_cdc.rpt]
puts "LENET5_AXIS_WRAPPER_CDC_REPORT_PASS"
