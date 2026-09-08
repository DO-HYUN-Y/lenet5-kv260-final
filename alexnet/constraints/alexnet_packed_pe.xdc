## AlexNet packed PE out-of-context timing constraints.
## Project baseline: KV260 PL clock at 200 MHz.
create_clock -period 5.000 -name clk [get_ports clk]

set_input_delay -clock clk 0.500 \
    [get_ports {rst ce act_lo[*] act_hi[*] weight[*] mac_valid acc_clear \
                reduce_last lane_mask[*] result_ready}] -min
set_input_delay -clock clk 1.000 \
    [get_ports {rst ce act_lo[*] act_hi[*] weight[*] mac_valid acc_clear \
                reduce_last lane_mask[*] result_ready}] -max
set_output_delay -clock clk 0.500 [all_outputs] -min
set_output_delay -clock clk 1.000 [all_outputs] -max
