set stage_dir [file normalize [file join [file dirname [info script]] ..]]
set alexnet_dir [file normalize [file join $stage_dir .. ..]]
set build_dir [file join $stage_dir build camera_rgbx_axis_adapter_sim]
file mkdir $build_dir
cd $build_dir

exec xvlog -sv -d SIMULATION [file join $alexnet_dir rtl integration \
    alexnet_camera_rgbx_axis_adapter.sv] [file join $stage_dir tb \
    tb_alexnet_camera_rgbx_axis_adapter.sv]
exec xelab tb_alexnet_camera_rgbx_axis_adapter -debug typical
exec xsim tb_alexnet_camera_rgbx_axis_adapter -runall

set log_path [file join $build_dir xsim.log]
set log_file [open $log_path r]
set log_text [read $log_file]
close $log_file
if {![string match "*ALEXNET_CAMERA_RGBX_AXIS_ADAPTER_TEST_PASSED*" \
        $log_text] || [string match "*Fatal:*" $log_text] ||
        [string match "*ERROR:*" $log_text]} {
  error "AlexNet camera RGBX AXIS adapter simulation failed; see $log_path"
}
puts "ALEXNET_CAMERA_RGBX_AXIS_ADAPTER_SIM_PASS"
