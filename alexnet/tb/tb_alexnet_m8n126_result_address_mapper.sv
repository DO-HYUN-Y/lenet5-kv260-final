`timescale 1ns/1ps

module tb_alexnet_m8n126_result_address_mapper;
  localparam logic [31:0] BASE = 32'h1800_0000;

  logic [31:0] result_base;
  logic [3:0] layer_id;
  logic [12:0] result_m_base;
  logic [15:0] result_n_base;
  logic [3:0] result_m_count;
  logic [31:0] result_address;
  logic [25:0] result_byte_count;
  logic [12:0] layer_spatial_count;
  logic descriptor_error;

  alexnet_m8n126_result_address_mapper dut (.*);

  function automatic int channels(input int layer);
    case (layer)
      1: channels = 64;
      2: channels = 192;
      3: channels = 384;
      4, 5: channels = 256;
      6, 7: channels = 4096;
      8: channels = 1000;
      default: channels = 0;
    endcase
  endfunction

  function automatic int spatial(input int layer);
    case (layer)
      1: spatial = 3025;
      2: spatial = 729;
      3, 4, 5: spatial = 169;
      6, 7, 8: spatial = 1;
      default: spatial = 0;
    endcase
  endfunction

  task automatic check_valid(
      input int layer,
      input int m_base,
      input int n_base,
      input int m_count);
    logic [31:0] expected_address;
    begin
      result_base = BASE;
      layer_id = layer;
      result_m_base = m_base;
      result_n_base = n_base;
      result_m_count = m_count;
      #1;
      expected_address = BASE + ((n_base / 8) * spatial(layer) + m_base) * 8;
      if (descriptor_error || result_address != expected_address ||
          result_byte_count != m_count * 8 ||
          layer_spatial_count != spatial(layer))
        $fatal(1,
               "valid map mismatch layer=%0d m=%0d+%0d n=%0d address=%h/%h bytes=%0d spatial=%0d",
               layer, m_base, m_count, n_base, result_address,
               expected_address, result_byte_count, layer_spatial_count);
    end
  endtask

  task automatic check_error(
      input int layer,
      input int m_base,
      input int n_base,
      input int m_count);
    begin
      result_base = BASE;
      layer_id = layer;
      result_m_base = m_base;
      result_n_base = n_base;
      result_m_count = m_count;
      #1;
      if (!descriptor_error)
        $fatal(1, "invalid map accepted layer=%0d m=%0d+%0d n=%0d",
               layer, m_base, m_count, n_base);
    end
  endtask

  initial begin
    result_base = BASE;
    layer_id = 0;
    result_m_base = 0;
    result_n_base = 0;
    result_m_count = 0;

    // Cover every N8 tile and both ends of each layer's spatial raster.
    for (int layer = 1; layer <= 8; layer++) begin
      for (int n_base = 0; n_base < channels(layer); n_base += 8) begin
        if (spatial(layer) == 1) begin
          check_valid(layer, 0, n_base, 1);
        end else begin
          check_valid(layer, 0, n_base, 8);
          check_valid(layer, spatial(layer) - 8, n_base, 8);
          check_valid(layer, spatial(layer) - 1, n_base, 1);
        end
      end
    end

    // Conv1/2 split-N64 upper M group must map exactly eight words later.
    check_valid(1, 8, 0, 8);
    check_valid(1, 16, 56, 8);
    check_valid(2, 8, 64, 8);
    check_valid(2, 720, 184, 8);

    check_error(0, 0, 0, 1);
    check_error(9, 0, 0, 1);
    check_error(1, 0, 1, 1);
    check_error(1, 0, 64, 1);
    check_error(1, 3025, 0, 1);
    check_error(2, 725, 0, 8);
    check_error(6, 1, 0, 1);
    check_error(8, 0, 1000, 1);
    check_error(8, 0, 992, 0);
    check_error(8, 0, 992, 9);

    result_base = 32'hffff_ff80;
    layer_id = 1;
    result_m_base = 0;
    result_n_base = 8;
    result_m_count = 8;
    #1;
    if (!descriptor_error)
      $fatal(1, "32-bit address overflow was not rejected");

    result_base = BASE + 1;
    layer_id = 1;
    result_m_base = 0;
    result_n_base = 0;
    result_m_count = 8;
    #1;
    if (!descriptor_error)
      $fatal(1, "unaligned base was not rejected");

    $display("ALEXNET_M8N126_RESULT_ADDRESS_MAPPER_TEST_PASSED");
    $finish;
  end
endmodule
