## OOC synthesis/implementation constraints for weight_loader.sv
## Target: KV260 (xck26-sfvc784-2LV-c), 200 MHz PL clock (my_self.md)
create_clock -period 5.000 -name clk [get_ports clk]

set data_in [get_ports -filter {DIRECTION == IN && NAME != clk}]
set_input_delay  -clock clk 1.000 $data_in -min
set_input_delay  -clock clk 2.000 $data_in -max
set_output_delay -clock clk 1.000 [all_outputs] -min
set_output_delay -clock clk 2.000 [all_outputs] -max
