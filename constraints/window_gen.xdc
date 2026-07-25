## OOC synthesis/implementation constraints for window_gen.sv
## Target: KV260 (xck26-sfvc784-2LV-c), 200 MHz PL clock (my_self.md)
create_clock -period 5.000 -name clk [get_ports clk]

## start/pix_in feed the FSM and line-buffer write path; give them a modest
## input delay budget so STA reports a meaningful setup slack instead of
## defaulting to 0 (typical for OOC block-level checks).
set data_in [get_ports -filter {DIRECTION == IN && NAME != clk}]
set_input_delay  -clock clk 1.000 $data_in -min
set_input_delay  -clock clk 2.000 $data_in -max
set_output_delay -clock clk 1.000 [all_outputs] -min
set_output_delay -clock clk 2.000 [all_outputs] -max
