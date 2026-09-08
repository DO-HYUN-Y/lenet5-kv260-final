create_clock -name aclk -period 5.000 -waveform {0.000 2.500} [get_ports aclk]
set_input_delay -clock aclk -min 0.500 \
    [get_ports -filter {DIRECTION == IN && NAME != aclk}]
set_input_delay -clock aclk -max 1.000 \
    [get_ports -filter {DIRECTION == IN && NAME != aclk}]
set_output_delay -clock aclk -min 0.500 [all_outputs]
set_output_delay -clock aclk -max 1.000 [all_outputs]
