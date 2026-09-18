`timescale 1ns/1ps

// True-RS compute/service boundary. No URAM or weight replay is instantiated.
// The existing input banks supply input_load; a 128-bit DMA stream supplies
// one K-major weight vector for each N token, consumed once. External psums
// provide K-block continuation. Only final K results enter the unchanged
// M8/N8 64-DSP postprocessor, serializer and 64-entry N8 output router.
// External psum/input service bytes must not be called DRAM bytes unless
// those services actually issue DDR transactions.
(* use_dsp="no" *) module alexnet_m8r128_row_stationary_core (
    input logic clk, rst,
    input logic input_begin_valid,
    output logic input_begin_ready,
    input logic [11:0] input_begin_k_count,
    input logic [3:0] input_begin_m_count,
    input logic [3:0] input_begin_row_width,
    input logic [2:0] input_begin_stride,
    input logic input_load_valid,
    output logic input_load_ready,
    input logic [11:0] input_load_k,
    input logic [63:0] input_load_values,

    input logic command_valid,
    output logic command_ready,
    input logic [3:0] command_m_count, command_n_count,
    input logic [11:0] command_k_count,
    input logic [12:0] command_m_base,
    input logic [15:0] command_n_base, command_tag,
    input logic command_first_k, command_final_k,
    input logic [1:0] command_destination,
    input logic signed [31:0] command_bias [0:7],
    input logic signed [17:0] command_multiplier [0:7],
    input logic [5:0] command_right_shift [0:7],
    input logic [7:0] command_relu,

    input logic weight_axis_valid,
    output logic weight_axis_ready,
    input logic [127:0] weight_axis_values,
    input logic [15:0] weight_axis_keep,
    input logic weight_axis_last,
    // One M8 vector per N, in ascending N order. A first-K command takes zero
    // as its incoming psum and never consumes this interface.
    input logic psum_in_valid,
    output logic psum_in_ready,
    input logic signed [31:0] psum_in_values [0:7],
    output logic psum_out_valid,
    input logic psum_out_ready,
    output logic signed [31:0] psum_out_values [0:7],
    output logic [3:0] psum_out_m_count,
    output logic [12:0] psum_out_m_base,
    output logic [15:0] psum_out_n, psum_out_tag,

    output logic output_valid,
    input logic output_ready,
    output logic [63:0] output_values,
    output logic [7:0] output_lane_mask,
    output logic [12:0] output_m,
    output logic [15:0] output_n_base, output_tag,
    output logic [1:0] output_destination,
    output logic command_done, busy, fault,
    output logic [63:0] input_service_bytes, weight_service_bytes,
    output logic [63:0] psum_read_service_bytes, psum_write_service_bytes,
    output logic [63:0] output_service_bytes, useful_mac_count
);
  typedef enum logic [2:0] {IDLE, CFG, RUN, POST, DRAIN, FAILED} state_t;
  state_t state_q;
  logic [11:0] resident_k_q, k_count_q;
  logic [3:0] resident_m_q, m_count_q, n_count_q;
  logic [1407:0] loaded_q;
  logic [11:0] loaded_count_q;
  logic inputs_complete_q;
  logic [12:0] m_base_q;
  logic [15:0] n_base_q, tag_q;
  logic first_q, final_q;
  logic [1:0] destination_q;
  logic signed [31:0] bias_q [0:7];
  logic signed [17:0] multiplier_q [0:7];
  logic [5:0] right_shift_q [0:7];
  logic [7:0] relu_q;
  logic configure_post;
  logic [3:0] issued_n_q, returned_n_q;
  logic [6:0] weight_beat_q;
  logic assembled_q;
  logic [7:0] weight_word_count;
  logic [15:0] expected_keep;
  logic sa_weight_ready;
  logic sa_load_ready, sa_source_valid, sa_source_ready, sa_result_valid;
  logic sa_result_ready, sa_idle, begin_fire, load_fire, command_fire, issue_fire;
  logic signed [7:0] sa_input_lo [0:3], sa_input_hi [0:3];
  logic [1:0] sa_input_mask [0:3];
  logic signed [31:0] sa_in_psum [0:7], sa_out_psum [0:7];
  logic [15:0] sa_result_tag;
  logic signed [31:0] final_group_q [0:7][0:7];
  logic post_cfg_ready, post_in_ready, post_valid, post_ready, post_idle;
  logic [63:0] post_values;
  logic [7:0] post_mask, n_mask;
  logic [4:0] post_m, router_m;
  logic [15:0] post_tag;
  logic router_cfg_ready, router_idle;
  logic [2:0] router_slice;
  logic [6:0] router_count;
  logic descriptor_ok,input_begin_fields_ok;

  function automatic logic [4:0] popcount16(input logic [15:0] mask);
    popcount16=0;
    for (int bit_index=0;bit_index<16;bit_index++)
      popcount16=popcount16+{4'd0,mask[bit_index]};
  endfunction

  function automatic logic row_aligned(input logic[11:0] k,input logic[3:0] w);
    case(w)1:return 1;3:return k%3==0;5:return k%5==0;6:return k%6==0;11:return k%11==0;default:return 0;endcase
  endfunction
  assign busy=state_q!=IDLE;
  assign input_begin_ready=state_q==IDLE && sa_idle && !command_valid;
  assign input_begin_fields_ok=input_begin_k_count>=1 && input_begin_k_count<=1408 &&
      (input_begin_row_width==1 || input_begin_row_width==3 || input_begin_row_width==5 ||
       input_begin_row_width==6 || input_begin_row_width==11) &&
      row_aligned(input_begin_k_count,input_begin_row_width) &&
      input_begin_k_count<=128*input_begin_row_width &&
      (input_begin_stride==1 || input_begin_stride==4) &&
      input_begin_m_count>=1 && input_begin_m_count<=8;
  assign begin_fire=input_begin_valid && input_begin_ready;
  assign input_load_ready=state_q==IDLE && sa_load_ready && resident_k_q!=0 &&
      input_load_k<resident_k_q && !input_begin_valid && !command_valid;
  assign load_fire=input_load_valid && input_load_ready;
  assign descriptor_ok=command_m_count==resident_m_q && command_k_count==resident_k_q &&
      command_n_count>=1 && command_n_count<=8 && command_n_base[2:0]==0 &&
      command_destination<=2;
  assign command_ready=state_q==IDLE && sa_idle && post_idle && router_idle &&
      post_cfg_ready && router_cfg_ready && inputs_complete_q && descriptor_ok &&
      !input_begin_valid && !input_load_valid;
  assign command_fire=command_valid && command_ready;
  assign configure_post=state_q==CFG && post_cfg_ready && router_cfg_ready;
  assign weight_word_count=(k_count_q+12'd15)>>4;
  assign expected_keep=16'hffff >> (16 -
      ((int'(k_count_q)-int'(weight_beat_q)*16)>=16 ? 16 :
        int'(k_count_q)-int'(weight_beat_q)*16));
  assign weight_axis_ready=state_q==RUN && !assembled_q && issued_n_q<n_count_q && sa_weight_ready;
  assign sa_source_valid=state_q==RUN && assembled_q && (first_q || psum_in_valid);
  assign psum_in_ready=state_q==RUN && assembled_q && !first_q && sa_source_ready;
  assign issue_fire=sa_source_valid && sa_source_ready;
  assign psum_out_valid=state_q==RUN && !final_q && sa_result_valid;
  assign sa_result_ready=state_q==RUN && (final_q || psum_out_ready);
  assign psum_out_m_count=m_count_q;
  assign psum_out_m_base=m_base_q;
  assign psum_out_n=n_base_q+sa_result_tag;
  assign psum_out_tag=tag_q;
  assign n_mask=8'hff >> (8-n_count_q);
  assign output_m=m_base_q+13'(router_m);

  always_comb begin
    for (int r=0;r<4;r++) begin
      sa_input_lo[r]=$signed(input_load_values[2*r*8 +: 8]);
      sa_input_hi[r]=$signed(input_load_values[(2*r+1)*8 +: 8]);
      sa_input_mask[r]={2*r+1<resident_m_q,2*r<resident_m_q};
    end
    for (int m=0;m<8;m++) begin
      sa_in_psum[m]=!first_q && m<m_count_q ? psum_in_values[m] : 32'sd0;
      psum_out_values[m]=sa_out_psum[m];
    end
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      state_q<=IDLE; resident_k_q<=0; resident_m_q<=0; loaded_q<=0;
      loaded_count_q<=0; inputs_complete_q<=0;
      k_count_q<=0; m_count_q<=0; n_count_q<=0; m_base_q<=0; n_base_q<=0; tag_q<=0;
      first_q<=0; final_q<=0; issued_n_q<=0; returned_n_q<=0;
      destination_q<=0; relu_q<=0;
      weight_beat_q<=0; assembled_q<=0; command_done<=0; fault<=0;
      input_service_bytes<=0; weight_service_bytes<=0;
      psum_read_service_bytes<=0; psum_write_service_bytes<=0;
      output_service_bytes<=0; useful_mac_count<=0;
      for (int n=0;n<8;n++) begin bias_q[n]<=0; multiplier_q[n]<=0; right_shift_q[n]<=0; end
      for (int m=0;m<8;m++) for (int n=0;n<8;n++) final_group_q[m][n]<=0;
    end else begin
      command_done<=0;
      if (begin_fire) begin
        resident_k_q<=input_begin_k_count; resident_m_q<=input_begin_m_count;
        loaded_q<=0;
        loaded_count_q<=0; inputs_complete_q<=0;
      end
      if (load_fire) begin
        loaded_q[input_load_k]<=1;
        input_service_bytes<=input_service_bytes+resident_m_q;
        if (!loaded_q[input_load_k]) begin
          loaded_count_q<=loaded_count_q+1'b1;
          if (loaded_count_q+1'b1==resident_k_q) inputs_complete_q<=1;
        end
      end
      if (command_fire) begin
        state_q<=command_final_k ? CFG : RUN; k_count_q<=command_k_count;
        m_count_q<=command_m_count; n_count_q<=command_n_count;
        m_base_q<=command_m_base; n_base_q<=command_n_base; tag_q<=command_tag;
        first_q<=command_first_k; final_q<=command_final_k;
        destination_q<=command_destination; relu_q<=command_relu;
        for (int n=0;n<8;n++) begin
          bias_q[n]<=command_bias[n]; multiplier_q[n]<=command_multiplier[n];
          right_shift_q[n]<=command_right_shift[n];
        end
        issued_n_q<=0; returned_n_q<=0; weight_beat_q<=0; assembled_q<=0;
          for (int m=0;m<8;m++) for (int n=0;n<8;n++) final_group_q[m][n]<=0;
      end
      if (configure_post) state_q<=RUN;
      if (weight_axis_valid && weight_axis_ready) begin
        weight_service_bytes<=weight_service_bytes+popcount16(weight_axis_keep);
        if (weight_axis_keep!=expected_keep || weight_axis_last!=(int'(weight_beat_q)+1==weight_word_count)) begin
          fault<=1; state_q<=FAILED;
        end else begin
          if (weight_axis_last) begin assembled_q<=1; weight_beat_q<=0; end
          else weight_beat_q<=weight_beat_q+1'b1;
        end
      end
      if (issue_fire) begin
        assembled_q<=0; issued_n_q<=issued_n_q+1'b1;
          useful_mac_count<=useful_mac_count+64'(m_count_q)*64'(k_count_q);
        if (!first_q) psum_read_service_bytes<=psum_read_service_bytes+64'(m_count_q)*4;
      end
      if (sa_result_valid && sa_result_ready) begin
        returned_n_q<=returned_n_q+1'b1;
        if (final_q) for (int m=0;m<8;m++) final_group_q[m][sa_result_tag[2:0]]<=sa_out_psum[m];
        else psum_write_service_bytes<=psum_write_service_bytes+64'(m_count_q)*4;
        if (returned_n_q+1'b1==n_count_q) begin
          if (final_q) state_q<=POST;
          else begin command_done<=1; state_q<=IDLE; end
        end
      end
      if (state_q==POST && post_in_ready) state_q<=DRAIN;
      if (state_q==DRAIN && post_idle && router_idle) begin command_done<=1; state_q<=IDLE; end
      if (output_valid && output_ready) output_service_bytes<=output_service_bytes+popcount16({8'd0,output_lane_mask});
      if(begin_fire && !input_begin_fields_ok) begin fault<=1;state_q<=FAILED;end
      // A packet fault wins even if a preceding result retires on this edge.
      if (weight_axis_valid && weight_axis_ready &&
          (weight_axis_keep!=expected_keep ||
           weight_axis_last!=(int'(weight_beat_q)+1==weight_word_count))) begin
        state_q<=FAILED;
        command_done<=0;
      end
    end
  end

  alexnet_sa_m8r128_row_stationary u_sa (
      .clk, .rst, .input_clear(begin_fire),
      .config_k_count(input_begin_k_count),.config_m_count(input_begin_m_count),
      .config_row_width(input_begin_row_width),.config_stride(input_begin_stride),
      .input_load_valid(load_fire), .input_load_ready(sa_load_ready),
      .input_k(input_load_k), .input_lo(sa_input_lo), .input_hi(sa_input_hi), .input_mask(sa_input_mask),
      .weight_load_valid(weight_axis_valid&&weight_axis_ready),.weight_load_ready(sa_weight_ready),
      .weight_word(weight_beat_q),.weight_values(weight_axis_values),.weight_keep(weight_axis_keep),
      .source_valid(sa_source_valid), .source_ready(sa_source_ready),
      .source_psum(sa_in_psum), .source_tag(16'(issued_n_q)), .result_valid(sa_result_valid),
      .result_ready(sa_result_ready), .result_psum(sa_out_psum), .result_tag(sa_result_tag), .idle(sa_idle)
  );
  alexnet_m8n8_requant_serializer u_postprocessor (
      .clk, .rst, .cfg_valid(configure_post), .cfg_ready(post_cfg_ready),
      .cfg_bias(bias_q), .cfg_multiplier(multiplier_q),
      .cfg_right_shift(right_shift_q), .cfg_relu(relu_q),
      .ingress_valid(state_q==POST), .ingress_ready(post_in_ready),
      .ingress_m_count(m_count_q), .ingress_accumulator(final_group_q),
      .ingress_lane_mask(n_mask), .ingress_tile_tag(tag_q),
      .egress_valid(post_valid), .egress_ready(post_ready), .egress_values(post_values),
      .egress_lane_mask(post_mask), .egress_m(post_m), .egress_tile_tag(post_tag), .idle(post_idle)
  );
  alexnet_n8_output_router #(.RUNTIME_SLICE_INDEX(1)) u_output_router (
      .clk, .rst, .cfg_valid(configure_post), .cfg_ready(router_cfg_ready),
      .cfg_destination(destination_q), .cfg_n64_tile_base({n_base_q[15:6],6'd0}),
      .cfg_slice_index(n_base_q[5:3]), .cfg_lane_mask(n_mask),
      .ingress_valid(post_valid), .ingress_ready(post_ready), .ingress_values(post_values),
      .ingress_lane_mask(post_mask), .ingress_m(post_m), .ingress_tile_tag(post_tag),
      .egress_valid(output_valid), .egress_ready(output_ready), .egress_values(output_values),
      .egress_lane_mask(output_lane_mask), .egress_destination(output_destination),
      .egress_slice(router_slice), .egress_m(router_m), .egress_n_base(output_n_base),
      .egress_tile_tag(output_tag), .idle(router_idle), .queued_count(router_count)
  );
`ifndef SYNTHESIS
  always_ff @(posedge clk) if (!rst && issue_fire && issued_n_q>=n_count_q)
    $fatal(1,"RS issued excess N tokens");
`endif
endmodule
