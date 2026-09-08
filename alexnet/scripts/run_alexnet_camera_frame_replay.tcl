set alexnet_root [file normalize [file join [file dirname [info script]] ..]]
set out_dir [file join $alexnet_root build camera_frame_replay_sim]
file mkdir $out_dir
cd $out_dir

exec xvlog -sv -d SIMULATION \
    [file join $alexnet_root rtl integration alexnet_camera_frame_replay.sv] \
    [file join $alexnet_root tb tb_alexnet_camera_frame_replay.sv]
exec xelab tb_alexnet_camera_frame_replay -debug typical
exec xsim tb_alexnet_camera_frame_replay -runall

set log_path [file join $out_dir xsim.log]
set log_file [open $log_path r]
set log_text [read $log_file]
close $log_file
if {![string match "*ALEXNET_CAMERA_FRAME_REPLAY_TEST_PASSED*" $log_text] ||
    [string match "*Fatal:*" $log_text] ||
    [string match "*ERROR:*" $log_text]} {
  error "AlexNet camera frame replay simulation failed; see $log_path"
}
puts "ALEXNET_CAMERA_FRAME_REPLAY_SIM_PASS"
