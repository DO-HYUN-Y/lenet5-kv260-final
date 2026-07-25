# Integrated datapath out-of-context timing contract: 200 MHz.
# The reader / DMA interface has 2 ns of setup budget and 1 ns hold budget
# relative to the accelerator clock. This makes the top-level WNS/WHS include
# activation input, eight-bank weight preload, configuration, and result ports
# instead of checking only internal register-to-register paths.
create_clock -period 5.000 -name clk [get_ports clk]
set data_in [get_ports -filter {DIRECTION == IN && NAME != clk}]
set_input_delay  -clock clk 1.000 $data_in -min
set_input_delay  -clock clk 2.000 $data_in -max
set_output_delay -clock clk 1.000 [all_outputs] -min
set_output_delay -clock clk 2.000 [all_outputs] -max
