## OOC synthesis/implementation constraints for sa_packed_4x8.sv
## Target: KV260 (xck26-sfvc784-2LV-c), 200 MHz PL clock (my_self.md)
create_clock -period 5.000 -name clk [get_ports clk]

## en/inputs are combinational into each packed_pe's DSP AREG/DREG/BREG regs;
## give them a modest input delay budget so STA reports a meaningful setup
## slack instead of defaulting to 0 (typical for OOC block-level checks).
set data_in  [remove_from_collection [all_inputs] [get_ports clk]]
set_input_delay  -clock clk 1.000 $data_in -min
set_input_delay  -clock clk 2.000 $data_in -max
set_output_delay -clock clk 1.000 [all_outputs] -min
set_output_delay -clock clk 2.000 [all_outputs] -max
