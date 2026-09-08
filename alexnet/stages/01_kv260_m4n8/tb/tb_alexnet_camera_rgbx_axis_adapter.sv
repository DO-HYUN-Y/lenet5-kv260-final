`timescale 1ns/1ps

module tb_alexnet_camera_rgbx_axis_adapter;
  localparam int FRAME_PIXELS = 5;

  logic aclk = 1'b0;
  logic aresetn = 1'b0;
  logic [63:0] s_axis_tdata;
  logic [7:0] s_axis_tkeep;
  logic s_axis_tvalid, s_axis_tready, s_axis_tlast;
  logic [63:0] m_axis_tdata;
  logic [7:0] m_axis_tkeep;
  logic m_axis_tvalid, m_axis_tready, m_axis_tlast;
  logic format_error;
  int accepted_outputs;

  always #2.5 aclk = ~aclk;

  alexnet_camera_rgbx_axis_adapter #(
      .FRAME_PIXELS(FRAME_PIXELS)
  ) dut (.*);

  task automatic reset_dut;
    begin
      s_axis_tdata = '0;
      s_axis_tkeep = 8'hff;
      s_axis_tvalid = 1'b0;
      s_axis_tlast = 1'b0;
      m_axis_tready = 1'b0;
      aresetn = 1'b0;
      repeat (3) @(posedge aclk);
      aresetn = 1'b1;
      @(negedge aclk);
    end
  endtask

  task automatic send_beat(
      input int index,
      input logic [7:0] keep,
      input logic last
  );
    logic [63:0] payload;
    begin
      payload = {8'hd7, 8'hd6, 8'hd5, 8'hd4, 8'hd3,
                 8'(index + 2), 8'(index + 1), 8'(index)};
      @(negedge aclk);
      s_axis_tdata = payload;
      s_axis_tkeep = keep;
      s_axis_tlast = last;
      s_axis_tvalid = 1'b1;
      do @(posedge aclk); while (!s_axis_tready);
      if (m_axis_tdata !== {40'b0, payload[23:0]} ||
          m_axis_tkeep !== 8'h07 || m_axis_tlast !== last) begin
        $fatal(1, "camera adapter payload mismatch at beat %0d", index);
      end
      @(negedge aclk);
      s_axis_tvalid = 1'b0;
      s_axis_tlast = 1'b0;
      s_axis_tdata = '0;
    end
  endtask

  always_ff @(posedge aclk) begin
    if (!aresetn) begin
      accepted_outputs <= 0;
    end else if (m_axis_tvalid && m_axis_tready) begin
      accepted_outputs <= accepted_outputs + 1;
    end
  end

  initial begin
    reset_dut();
    m_axis_tready = 1'b1;
    send_beat(0, 8'hff, 1'b0);
    m_axis_tready = 1'b0;
    fork
      begin
        repeat (3) @(posedge aclk);
        @(negedge aclk);
        m_axis_tready = 1'b1;
      end
      send_beat(1, 8'hff, 1'b0);
    join
    send_beat(2, 8'hff, 1'b0);
    send_beat(3, 8'hff, 1'b0);
    send_beat(4, 8'hff, 1'b1);
    @(posedge aclk);
    if (format_error || accepted_outputs != FRAME_PIXELS) begin
      $fatal(1, "valid RGBX frame failed error=%0b outputs=%0d",
             format_error, accepted_outputs);
    end

    reset_dut();
    m_axis_tready = 1'b1;
    send_beat(0, 8'h07, 1'b0);
    @(posedge aclk);
    if (!format_error) $fatal(1, "bad input TKEEP was not detected");

    reset_dut();
    m_axis_tready = 1'b1;
    send_beat(0, 8'hff, 1'b1);
    @(posedge aclk);
    if (!format_error) $fatal(1, "early TLAST was not detected");

    $display("ALEXNET_CAMERA_RGBX_AXIS_ADAPTER_TEST_PASSED clock_mhz=200");
    $finish;
  end

endmodule
