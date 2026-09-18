`timescale 1ns/1ps

// Batch-one torchvision AlexNet pure-RS work schedule: row-bounded M8 -> 128 filter rows -> N8.
// An input request installs one M8x(128*S) row tile in PE registers, then ALL output
// channels stream through it before any input is replaced. Continuation psums
// cross the explicit external psum service; no OS or WS PE is selected.
(* use_dsp="no" *) module alexnet_row_stationary_graph_scheduler (
    input logic clk, rst,
    input logic start_valid,
    output logic start_ready,
    input logic [15:0] start_tag,
    output logic input_request_valid,
    input logic input_request_ready,
    output logic [3:0] layer_id,
    output logic [3:0] row_width,
    output logic [2:0] window_stride,
    output logic [12:0] m_base,
    output logic [3:0] m_count,
    output logic [13:0] k_offset,
    output logic [11:0] k_count,
    input logic input_done, input_error,
    output logic command_valid,
    input logic command_ready,
    output logic [15:0] n_base,
    output logic [3:0] n_count,
    output logic first_k, final_k,
    output logic [15:0] command_tag,
    input logic command_done, command_error,
    output logic layer_complete_valid,
    input logic layer_complete_ready,
    output logic layer_requires_pool,
    output logic inference_done, fault, busy,
    output logic [31:0] completed_commands,
    output logic [31:0] completed_input_tiles
);
  typedef enum logic [3:0] {IDLE, PREPARE, INPUT_REQ, INPUT_WAIT, ISSUE, WAIT_DONE, ADVANCE,
                           LAYER_WAIT, COMPLETE, FAILED} state_t;
  state_t state_q;
  logic [3:0] layer_q;
  logic [12:0] m_q;
  logic [13:0] k_q;
  logic [15:0] n_q, tag_q;
  int m_total, n_total, k_total, width, row_remaining, block_words;
  logic last_m,last_k,last_n;
  logic prepare_input_q;
  logic [12:0] remaining_m;
  logic [15:0] remaining_n;
  logic [13:0] remaining_k;
  assign start_ready=state_q==IDLE;
  assign busy=state_q!=IDLE;
  assign fault=state_q==FAILED;
  assign input_request_valid=state_q==INPUT_REQ;
  assign command_valid=state_q==ISSUE;
  assign layer_complete_valid=state_q==LAYER_WAIT;
  assign layer_requires_pool=layer_q==1 || layer_q==2 || layer_q==5;
  assign layer_id=layer_q;
  assign m_base=m_q; assign k_offset=k_q; assign n_base=n_q;
  assign command_tag=tag_q;
  assign remaining_m=13'(m_total)-m_q;
  assign remaining_n=16'(n_total)-n_q;
  assign remaining_k=14'(k_total)-k_q;
  assign last_k=final_k;
  always_comb begin
    m_total=0; n_total=0; k_total=0;
    case(layer_q)
      1: begin m_total=3025; n_total=64; k_total=363; end
      2: begin m_total=729; n_total=192; k_total=1600; end
      3: begin m_total=169; n_total=384; k_total=1728; end
      4: begin m_total=169; n_total=256; k_total=3456; end
      5: begin m_total=169; n_total=256; k_total=2304; end
      6: begin m_total=1; n_total=4096; k_total=9216; end
      7: begin m_total=1; n_total=4096; k_total=4096; end
      8: begin m_total=1; n_total=1000; k_total=4096; end
      default: ;
    endcase
  end
  always_comb begin
    case(layer_q)
      1:begin row_width=11;window_stride=4;width=55;row_remaining=55-m_q%55;end
      2:begin row_width=5;window_stride=1;width=27;row_remaining=27-m_q%27;end
      3,4,5:begin row_width=3;window_stride=1;width=13;row_remaining=13-m_q%13;end
      6:begin row_width=6;window_stride=1;width=1;row_remaining=1;end
      default:begin row_width=1;window_stride=1;width=1;row_remaining=1;end
    endcase
    block_words=128*int'(row_width);
  end
  always_ff @(posedge clk) begin
    if(rst) begin
      state_q<=IDLE; layer_q<=0; m_q<=0; k_q<=0; n_q<=0; tag_q<=0;
      inference_done<=0; completed_commands<=0; completed_input_tiles<=0;
      prepare_input_q<=0; m_count<=0; n_count<=0; k_count<=0;
      first_k<=0; final_k<=0; last_m<=0; last_n<=0;
    end else begin
      inference_done<=0;
      case(state_q)
        IDLE: if(start_valid && start_ready) begin
          layer_q<=1; m_q<=0; k_q<=0; n_q<=0; tag_q<=start_tag;
          completed_commands<=0; completed_input_tiles<=0; prepare_input_q<=1; state_q<=PREPARE;
        end
        // Coordinate changes settle before metadata enters the core's
        // high-fanout launch/clear logic. The reduction order is unchanged.
        PREPARE: begin
          m_count<=4'(row_remaining<8 ? row_remaining : remaining_m>8 ? 8 : remaining_m);
          n_count<=remaining_n>8 ? 4'd8 : 4'(remaining_n);
          k_count<=12'(remaining_k>block_words ? block_words : remaining_k);
          first_k<=k_q==0; final_k<=remaining_k<=block_words;
          last_m<=remaining_m<=8 && remaining_m<=row_remaining; last_n<=remaining_n<=8;
          state_q<=prepare_input_q ? INPUT_REQ : ISSUE;
        end
        INPUT_REQ: if(input_request_valid && input_request_ready) state_q<=INPUT_WAIT;
        INPUT_WAIT: if(input_done) begin
          if(input_error) state_q<=FAILED;
          else begin completed_input_tiles<=completed_input_tiles+1'b1; state_q<=ISSUE; end
        end
        ISSUE: if(command_valid && command_ready) state_q<=WAIT_DONE;
        WAIT_DONE: if(command_done) begin
          if(command_error) state_q<=FAILED;
          else begin completed_commands<=completed_commands+1'b1; state_q<=ADVANCE; end
        end
        ADVANCE: begin
          tag_q<=tag_q+1'b1;
          if(!last_n) begin n_q<=n_q+16'd8; prepare_input_q<=0; state_q<=PREPARE; end
          else if(!last_k) begin n_q<=0; k_q<=k_q+14'(block_words); prepare_input_q<=1; state_q<=PREPARE; end
          else if(!last_m) begin n_q<=0; k_q<=0; m_q<=m_q+13'(m_count); prepare_input_q<=1; state_q<=PREPARE; end
          else if(layer_q==8) state_q<=COMPLETE;
          else state_q<=LAYER_WAIT;
        end
        LAYER_WAIT: if(layer_complete_ready) begin
          layer_q<=layer_q+1'b1; n_q<=0; m_q<=0; k_q<=0; prepare_input_q<=1; state_q<=PREPARE;
        end
        COMPLETE: begin inference_done<=1; state_q<=IDLE; end
        FAILED: state_q<=FAILED;
        default: state_q<=FAILED;
      endcase
    end
  end
`ifndef SYNTHESIS
  always_ff @(posedge clk) if(!rst) begin
    if(input_done && state_q!=INPUT_WAIT) $fatal(1,"stray RS input completion");
    if(command_done && state_q!=WAIT_DONE) $fatal(1,"stray RS command completion");
  end
`endif
endmodule
