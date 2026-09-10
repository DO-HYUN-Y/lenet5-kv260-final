# Reuse the existing numerical/error scoreboards as drivers of ONE top.
# Only hierarchy/clock/DUT ownership changes; no expected values are rewritten.
proc read_test {path} {
  set f [open $path r]; set s [read $f]; close $f; return $s
}
set generated ""
foreach kind {rs fc} {
  if {$kind eq "rs"} {
    set name alexnet_m4n8_rs_dma_scheduled_io_datapath
  } else {
    set name alexnet_m4n8_fc_layer_datapath
  }
  set s [read_test [file join $alexnet_root tb tb_$name.sv]]
  if {$kind eq "rs"} {
    set header "module shared_${kind}_test_driver(input logic clk, input logic run, input logic profile_mode, output logic test_done);"
  } else {
    set header "module shared_${kind}_test_driver(input logic clk, input logic run, output logic test_done);"
  }
  set s [string map [list "module tb_$name;" $header] $s]
  # The DUT is supplied by the parent bench. Signals remain visible for wiring.
  set begin [string first "  $name " $s]
  set end [string first ");" $s $begin]
  if {$begin < 0 || $end < 0} { error "cannot locate $kind DUT" }
  set s [string replace $s $begin [expr {$end+1}] ""]
  set s [string map [list {  logic clk, rst;} {  logic rst;} {  logic clk = 1'b0;} {} {  initial clk = 0;} {} {  always #2.5 clk = ~clk;} {}] $s]
  set s [string map [list {$finish;} {test_done = 1;}] $s]
  if {$kind eq "rs"} {
    set s [string map [list {    seed = 32'h7d62_4a17;} {    wait(run);
    seed = 32'h7d62_4a17;}] $s]
    set s [string map [list \
        {    random_compute_stalls = 1'b1;} \
        {    random_compute_stalls = profile_mode ? 1'b0 : 1'b1;}] $s]
    # The standalone RS scoreboard's internal probes now live below the RS
    # child of the shared-compute integration top.
    set s [string map [list {dut.} \
        {tb_alexnet_m4n8_shared_compute_top.dut.u_rs.}] $s]
    if {[info exists shared_compute_phys_rows] &&
        $shared_compute_phys_rows == 4} {
      set s [string map [list \
          {INPUT_H * ((OUTPUT_W + 3) / 4)} \
          {INPUT_H * ((OUTPUT_W + 7) / 8)}] $s]
    }
  } else {
    set s [string map [list {    seed_init = $urandom(seed);} {    wait(run);
    seed_init = $urandom(seed);}] $s]
    # The first clean FC8 follows Conv without reset. Fault recovery still resets.
    set s [string map [list {  task automatic reset_dut;} {  int reset_calls = 0;
  task automatic reset_dut;} {    rst = 1; job_valid = 0;} {    rst = (reset_calls != 0); reset_calls++; job_valid = 0;}] $s]
    set a [string first {    expect_fault = 1; inject_input_error = 1;} $s]
    set b [string first {    start_job(1,16'h8000);} $s $a]
    set c [string first {    expect_fault = 1; inject_ack_error = 1;} $s $b]
    if {$a < 0 || $b < 0 || $c < 0} { error "FC ordering anchors changed" }
    set bad [string range $s $a [expr {$b-1}]]
    set clean [string range $s $b [expr {$c-1}]]
    set s [string replace $s $a [expr {$c-1}] "$clean$bad"]
    set s [string map [list {dut.u_core.u_core.u_core.g_local.u_base.u_output_slice} {tb_alexnet_m4n8_shared_compute_top.dut.u_shared.u_output_slice} {dut.} {tb_alexnet_m4n8_shared_compute_top.dut.u_fc.}] $s]
    # Undo only the double prefix introduced in the shared-base replacement.
    set s [string map [list {tb_alexnet_m4n8_shared_compute_top.tb_alexnet_m4n8_shared_compute_top.dut.u_fc.u_shared} {tb_alexnet_m4n8_shared_compute_top.dut.u_shared}] $s]
  }
  if {$kind eq "fc"} {
    set init_block {  initial begin
    test_done = 0; rst = 0; ce = 0; job_valid = 0; service_error = 0;
    parameter_valid = 0; read_request_ready = 0; result_request_ready = 0;
    result_complete_valid = 0; result_complete_error = 0;
    s_axis_tvalid = 0; s_axis_tdata = 0; s_axis_tkeep = 0; s_axis_tlast = 0;
    m_axis_tready = 0;
  end
endmodule}
  } else {
    set init_block {  initial begin test_done = 0; rst = 0; end
endmodule}
  }
  set s [string map [list {endmodule} $init_block] $s]
  append generated $s "\n"
}
set f [open [file join $out_dir shared_compute_test_drivers.sv] w]
puts $f $generated
close $f
