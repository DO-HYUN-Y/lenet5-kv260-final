`timescale 1ns/1ps

module tb_alexnet_n8_maxpool3x3;

  localparam int MAX_INPUT_WIDTH = 55;
  localparam int MAX_PIXELS = MAX_INPUT_WIDTH * MAX_INPUT_WIDTH;

  import "DPI-C" function int alexnet_golden_maxpool3x3_n8(
      input longint unsigned p00,
      input longint unsigned p01,
      input longint unsigned p02,
      input longint unsigned p10,
      input longint unsigned p11,
      input longint unsigned p12,
      input longint unsigned p20,
      input longint unsigned p21,
      input longint unsigned p22,
      input byte lane_mask,
      output longint unsigned output_values);

  logic clk = 1'b0;
  logic rst;
  logic frame_valid;
  logic frame_ready;
  logic [5:0] frame_input_h;
  logic [5:0] frame_input_w;
  logic [7:0] frame_lane_mask;
  logic [15:0] frame_n_base;
  logic [15:0] frame_tag;
  logic s_valid;
  logic s_ready;
  logic [63:0] s_values;
  logic [7:0] s_lane_mask;
  logic m_valid;
  logic m_ready;
  logic [63:0] m_values;
  logic [7:0] m_lane_mask;
  logic [5:0] m_y;
  logic [5:0] m_x;
  logic [15:0] m_n_base;
  logic [15:0] m_frame_tag;
  logic frame_active;
  logic frame_done;
  logic idle;

  logic [63:0] pixels [0:MAX_PIXELS-1];

  int current_h;
  int current_w;
  int current_out_h;
  int current_out_w;
  int current_n_base;
  int current_tag;
  logic [7:0] current_mask;
  int expected_oy;
  int expected_ox;
  int frame_outputs;
  int total_outputs;
  int total_inputs;
  int tested_frames;
  int max_output_stall;
  int output_stall_run;

  logic hold_active;
  logic [63:0] hold_values;
  logic [7:0] hold_mask;
  logic [5:0] hold_y;
  logic [5:0] hold_x;
  logic [15:0] hold_n_base;
  logic [15:0] hold_tag;

  alexnet_n8_maxpool3x3 #(
      .MAX_INPUT_WIDTH(MAX_INPUT_WIDTH)
  ) dut (.*);

  always #2.5 clk = ~clk;

  task automatic fill_frame(
      input int frame_index,
      input int height,
      input int width);
    int value;
    logic [63:0] pixel_word;
    begin
      for (int y = 0; y < height; y++) begin
        for (int x = 0; x < width; x++) begin
          pixel_word = '0;
          for (int lane = 0; lane < 8; lane++) begin
            if (frame_index == 0) begin
              value = ((y * width + x) * 29 + lane * 37) & 8'hff;
              value = value - 128;
              if (y == 1 && x == 1 && lane == 0)
                value = 127;
              if (y == 2 && x == 2 && lane == 1)
                value = -128;
            end else begin
              value = $urandom_range(0, 255) - 128;
            end
            pixel_word[lane*8 +: 8] = value[7:0];
          end
          pixels[y * width + x] = pixel_word;
        end
      end
    end
  endtask

  task automatic check_output;
    longint unsigned golden_values;
    int origin_y;
    int origin_x;
    int status;
    begin
      if (hold_active) begin
        if (!m_valid || m_values != hold_values || m_lane_mask != hold_mask ||
            m_y != hold_y || m_x != hold_x || m_n_base != hold_n_base ||
            m_frame_tag != hold_tag)
          $fatal(1, "maxpool output changed while backpressured");
      end

      if (m_valid) begin
        if (m_y != expected_oy || m_x != expected_ox ||
            m_lane_mask != current_mask || m_n_base != current_n_base ||
            m_frame_tag != current_tag)
          $fatal(1,
                 "maxpool metadata mismatch y=%0d/%0d x=%0d/%0d mask=%02x/%02x n=%0d/%0d tag=%0d/%0d",
                 m_y, expected_oy, m_x, expected_ox, m_lane_mask,
                 current_mask, m_n_base, current_n_base, m_frame_tag,
                 current_tag);

        origin_y = expected_oy * 2;
        origin_x = expected_ox * 2;
        status = alexnet_golden_maxpool3x3_n8(
            pixels[(origin_y + 0) * current_w + origin_x + 0],
            pixels[(origin_y + 0) * current_w + origin_x + 1],
            pixels[(origin_y + 0) * current_w + origin_x + 2],
            pixels[(origin_y + 1) * current_w + origin_x + 0],
            pixels[(origin_y + 1) * current_w + origin_x + 1],
            pixels[(origin_y + 1) * current_w + origin_x + 2],
            pixels[(origin_y + 2) * current_w + origin_x + 0],
            pixels[(origin_y + 2) * current_w + origin_x + 1],
            pixels[(origin_y + 2) * current_w + origin_x + 2],
            current_mask, golden_values);
        if (status != 0 || m_values != golden_values)
          $fatal(1,
                 "maxpool data mismatch y=%0d x=%0d rtl=%016x golden=%016x status=%0d",
                 m_y, m_x, m_values, golden_values, status);
      end

      if (m_valid && !m_ready) begin
        hold_active = 1'b1;
        hold_values = m_values;
        hold_mask = m_lane_mask;
        hold_y = m_y;
        hold_x = m_x;
        hold_n_base = m_n_base;
        hold_tag = m_frame_tag;
        output_stall_run = output_stall_run + 1;
        if (output_stall_run > max_output_stall)
          max_output_stall = output_stall_run;
      end else begin
        hold_active = 1'b0;
        output_stall_run = 0;
      end
    end
  endtask

  task automatic run_frame(
      input int frame_index,
      input int height,
      input int width,
      input logic [7:0] lane_mask,
      input int n_base,
      input int tag);
    int input_index;
    int frame_cycles;
    int expected_outputs;
    logic pending_input;
    logic input_fire;
    logic output_fire;
    logic done_seen;
    begin
      current_h = height;
      current_w = width;
      current_out_h = ((height - 3) / 2) + 1;
      current_out_w = ((width - 3) / 2) + 1;
      current_mask = lane_mask;
      current_n_base = n_base;
      current_tag = tag;
      expected_oy = 0;
      expected_ox = 0;
      frame_outputs = 0;
      expected_outputs = current_out_h * current_out_w;
      input_index = 0;
      frame_cycles = 0;
      pending_input = 1'b0;
      done_seen = 1'b0;
      hold_active = 1'b0;
      output_stall_run = 0;
      fill_frame(frame_index, height, width);

      frame_valid = 1'b1;
      frame_input_h = height;
      frame_input_w = width;
      frame_lane_mask = lane_mask;
      frame_n_base = n_base;
      frame_tag = tag;
      s_valid = 1'b0;
      m_ready = 1'b0;
      #1;
      if (!frame_ready)
        $fatal(1, "maxpool frame descriptor was not accepted at idle");
      @(posedge clk);
      @(negedge clk);
      frame_valid = 1'b0;

      while (!done_seen) begin
        if (!pending_input && input_index < height * width &&
            ($urandom_range(0, 4) != 0))
          pending_input = 1'b1;

        s_valid = pending_input;
        s_values = pixels[input_index];
        s_lane_mask = lane_mask;
        if (frame_index == 0 && frame_cycles < 30)
          m_ready = 1'b0;
        else if ((frame_cycles % 47) < 6)
          m_ready = 1'b0;
        else
          m_ready = ($urandom_range(0, 4) != 0);

        #1;
        input_fire = s_valid && s_ready;
        output_fire = m_valid && m_ready;
        check_output();

        @(posedge clk);
        if (input_fire) begin
          input_index = input_index + 1;
          pending_input = 1'b0;
          total_inputs = total_inputs + 1;
        end
        if (output_fire) begin
          frame_outputs = frame_outputs + 1;
          total_outputs = total_outputs + 1;
          if (expected_ox == current_out_w - 1) begin
            expected_ox = 0;
            expected_oy = expected_oy + 1;
          end else begin
            expected_ox = expected_ox + 1;
          end
        end
        @(negedge clk);

        if (frame_done)
          done_seen = 1'b1;
        frame_cycles = frame_cycles + 1;
        if (frame_cycles > 200000)
          $fatal(1, "maxpool frame timeout height=%0d width=%0d", height,
                 width);
      end

      s_valid = 1'b0;
      m_ready = 1'b0;
      if (input_index != height * width || frame_outputs != expected_outputs ||
          expected_oy != current_out_h || expected_ox != 0 || !idle)
        $fatal(1,
               "maxpool frame completion mismatch in=%0d/%0d out=%0d/%0d coord=%0d,%0d idle=%0b",
               input_index, height * width, frame_outputs, expected_outputs,
               expected_oy, expected_ox, idle);
      tested_frames = tested_frames + 1;
    end
  endtask

  initial begin
    int seed;
    int seed_sink;
    seed = 32'h5a17_3c91;
    seed_sink = $urandom(seed);

    rst = 1'b1;
    frame_valid = 1'b0;
    frame_input_h = '0;
    frame_input_w = '0;
    frame_lane_mask = '0;
    frame_n_base = '0;
    frame_tag = '0;
    s_valid = 1'b0;
    s_values = '0;
    s_lane_mask = '0;
    m_ready = 1'b0;
    tested_frames = 0;
    total_inputs = 0;
    total_outputs = 0;
    max_output_stall = 0;
    output_stall_run = 0;
    hold_active = 1'b0;

    repeat (5) @(negedge clk);
    rst = 1'b0;
    @(negedge clk);

    run_frame(0, 5, 5, 8'hff, 0, 11);
    run_frame(1, 55, 55, 8'hff, 64, 21);
    run_frame(2, 27, 27, 8'h0f, 128, 22);
    run_frame(3, 13, 13, 8'h01, 192, 23);
    run_frame(4, 4, 6, 8'h81, 256, 24);

    $display(
        "ALEXNET_N8_MAXPOOL3X3_TEST_PASSED frames=%0d inputs=%0d outputs=%0d maxstall=%0d seed=%0d",
        tested_frames, total_inputs, total_outputs, max_output_stall, seed);
    $finish;
  end

endmodule
