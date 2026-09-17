set script_dir [file dirname [info script]]
set alexnet_dir [file normalize [file join $script_dir ..]]
set work_dir [file join $alexnet_dir .xsim_m8n126_activation_patch_service]
file delete -force $work_dir
file mkdir $work_dir
cd $work_dir

set rtl [file join $alexnet_dir rtl integration \
    alexnet_m8n126_activation_patch_service.sv]
set tb [file join $alexnet_dir tb \
    tb_alexnet_m8n126_activation_patch_service.sv]

exec xvlog -sv $rtl $tb
exec xelab tb_alexnet_m8n126_activation_patch_service -s patch_service_sim
set result [exec xsim patch_service_sim -runall]
puts $result
if {![string match {*ALEXNET_M8N126_ACTIVATION_PATCH_SERVICE_TEST_PASSED*} \
        $result]} {
  error "M8N126 activation patch service simulation did not report PASS"
}
puts "ALEXNET_M8N126_ACTIVATION_PATCH_SERVICE_SIM_PASS"
