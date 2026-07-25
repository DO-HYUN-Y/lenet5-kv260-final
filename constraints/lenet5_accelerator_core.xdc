# Full LeNet-5 accelerator out-of-context timing contract: 200 MHz.
create_clock -period 5.000 -name clk [get_ports clk]

# Reset is asynchronous at this integration boundary.
set_false_path -from [get_ports rst_n]

# Reserve external setup/hold budget for model and activation preload ports.
set data_in [get_ports -filter {
  DIRECTION == IN && NAME != clk && NAME != rst_n
}]
set_input_delay  -clock clk 1.000 $data_in -min
set_input_delay  -clock clk 2.000 $data_in -max
set_output_delay -clock clk 1.000 [all_outputs] -min
set_output_delay -clock clk 2.000 [all_outputs] -max
