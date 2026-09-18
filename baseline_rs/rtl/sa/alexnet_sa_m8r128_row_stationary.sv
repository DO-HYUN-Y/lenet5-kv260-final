`timescale 1ns/1ps
// M8 x 128 1D filter-row primitives, physical packed M4 x R128.
// Each column holds (kernel_y,channel), each local MAC scans kernel_x.
// Input union windows and filter rows are resident; completed row psums
// reduce spatially through seven registered levels then external continuation.
(* use_dsp="no" *) module alexnet_sa_m8r128_row_stationary #(parameter int ACC_W=27) (
    input logic clk,rst,input_clear,
    input logic [11:0] config_k_count,
    input logic [3:0] config_m_count,config_row_width,
    input logic [2:0] config_stride,
    input logic input_load_valid,
    output logic input_load_ready,
    input logic [11:0] input_k,
    input logic signed [7:0] input_lo[0:3],input_hi[0:3],
    input logic [1:0] input_mask[0:3],
    input logic weight_load_valid,
    output logic weight_load_ready,
    input logic [6:0] weight_word,
    input logic [127:0] weight_values,
    input logic [15:0] weight_keep,
    input logic source_valid,
    output logic source_ready,
    input logic signed [31:0] source_psum[0:7],
    input logic [15:0] source_tag,
    output logic result_valid,
    input logic result_ready,
    output logic signed [31:0] result_psum[0:7],
    output logic [15:0] result_tag,
    output logic idle
);
    typedef enum logic[1:0] {IDLE,PROCESS,RESULT} state_t;
    state_t state_q;
    logic [3:0] width_q,m_q,issued_tap_q;
    logic [2:0] stride_q;
    logic [7:0] rows_q,input_row;
    logic [3:0] mac_tap,mac_hi_tap,row_address;
    typedef enum logic[1:0] {W_EMPTY,W_DECODE,W_LO,W_HI} writer_t;
    writer_t writer_q;
    logic [11:0] load_k_q;
    logic [7:0] load_row_q;
    logic [3:0] load_tap_q;
    logic signed [7:0] load_lo_q[0:3],load_hi_q[0:3],write_value[0:3];
    logic [1:0] load_mask_q[0:3];
    logic write_mask[0:3];
    logic [87:0] weight_strobe[0:4];
    logic signed[7:0] shared_filter_values[0:15][0:10];
    logic shared_filter_keep[0:15][0:10];
    logic source_fire,mac_valid,ce;
    logic signed [7:0] weights[0:127];
    logic signed [ACC_W-1:0] lo[0:127][0:3],hi[0:127][0:3];
    logic row_done[0:127][0:3];
    logic [6:0] tree_valid_q;
    logic signed [ACC_W-1:0] initial_q[0:7],result_q[0:7],tree_result[0:7];
    logic [15:0] tag_q;
    function automatic logic [11:0] divide_row(input logic[11:0] k,input logic[3:0] w);
        case(w) 1:return k;3:return k/3;5:return k/5;6:return k/6;11:return k/11;default:return 0;endcase
    endfunction
    function automatic logic signed [ACC_W-1:0] checked_add(input logic signed[ACC_W-1:0] a,b);
        logic signed [ACC_W:0] sum;
        sum={a[ACC_W-1],a}+{b[ACC_W-1],b};
`ifndef SYNTHESIS
        if(sum[ACC_W]!=sum[ACC_W-1]) $fatal(1,"RS spatial/continuation reduction overflow");
`endif
        return sum[ACC_W-1:0];
    endfunction
    function automatic logic [3:0] mod_row(input logic[11:0] k,input logic[3:0] w);
        case(w)1:return 0;3:return 4'(k%3);5:return 4'(k%5);6:return 4'(k%6);11:return 4'(k%11);default:return 0;endcase
    endfunction
    assign input_row=load_row_q;
    assign row_address=writer_q==W_LO?load_tap_q:writer_q==W_HI?4'(load_tap_q+stride_q):mac_tap;
    assign mac_hi_tap=4'(mac_tap+stride_q);
    for(genvar r=0;r<4;r++) begin:g_writer_lanes
        assign write_mask[r]=writer_q==W_LO?load_mask_q[r][0]:writer_q==W_HI?load_mask_q[r][1]:1'b0;
        assign write_value[r]=writer_q==W_LO?load_lo_q[r]:load_hi_q[r];
    end
    always_ff @(posedge clk) begin
        if(rst) begin
            writer_q<=W_EMPTY;load_k_q<=0;load_row_q<=0;load_tap_q<=0;
            for(int r=0;r<4;r++) begin load_lo_q[r]<=0;load_hi_q[r]<=0;load_mask_q[r]<=0;end
        end else case(writer_q)
            W_EMPTY:if(input_load_valid&&input_load_ready) begin
                load_k_q<=input_k;writer_q<=W_DECODE;
                for(int r=0;r<4;r++) begin load_lo_q[r]<=input_lo[r];load_hi_q[r]<=input_hi[r];load_mask_q[r]<=input_mask[r];end
            end
            W_DECODE:begin load_row_q<=8'(divide_row(load_k_q,width_q));load_tap_q<=mod_row(load_k_q,width_q);writer_q<=W_LO;end
            W_LO:writer_q<=W_HI;
            W_HI:writer_q<=W_EMPTY;
        endcase
    end
    assign input_load_ready=state_q==IDLE&&writer_q==W_EMPTY&&!input_clear;
    assign weight_load_ready=state_q==IDLE;
    assign source_ready=state_q==IDLE&&writer_q==W_EMPTY;
    assign source_fire=source_valid&&source_ready;
    assign mac_valid=source_fire||(state_q==PROCESS&&issued_tap_q<width_q);
    assign mac_tap=source_fire?4'd0:issued_tap_q;
    assign ce=state_q!=RESULT||result_ready;
    assign idle=state_q==IDLE&&writer_q==W_EMPTY;
    assign result_valid=state_q==RESULT;
    assign result_tag=tag_q;
    for(genvar m=0;m<8;m++) assign result_psum[m]=32'($signed(result_q[m]));
    // Decode each stream word once. The 16 possible column residues
    // share byte/keep selectors instead of duplicating them in 128 RFs.
    for(genvar w=0;w<5;w++) begin:g_weight_width
        localparam int S=w==0?1:w==1?3:w==2?5:w==3?6:11;
        for(genvar word_index=0;word_index<88;word_index++)
            assign weight_strobe[w][word_index]=weight_load_valid&&weight_load_ready&&width_q==S&&weight_word==word_index;
    end
    for(genvar residue=0;residue<16;residue++) for(genvar t=0;t<11;t++) begin:g_filter_payload
        always_comb case(width_q)
            1:begin shared_filter_values[residue][t]=$signed(weight_values[((residue+t)%16)*8+:8]);shared_filter_keep[residue][t]=weight_keep[(residue+t)%16];end
            3:begin shared_filter_values[residue][t]=$signed(weight_values[((residue*3+t)%16)*8+:8]);shared_filter_keep[residue][t]=weight_keep[(residue*3+t)%16];end
            5:begin shared_filter_values[residue][t]=$signed(weight_values[((residue*5+t)%16)*8+:8]);shared_filter_keep[residue][t]=weight_keep[(residue*5+t)%16];end
            6:begin shared_filter_values[residue][t]=$signed(weight_values[((residue*6+t)%16)*8+:8]);shared_filter_keep[residue][t]=weight_keep[(residue*6+t)%16];end
            default:begin shared_filter_values[residue][t]=$signed(weight_values[((residue*11+t)%16)*8+:8]);shared_filter_keep[residue][t]=weight_keep[(residue*11+t)%16];end
        endcase
    end
    for(genvar c=0;c<128;c++) begin:g_column
        logic [10:0] filter_load_mask;
        logic signed[7:0] filter_load_values[0:10];
        for(genvar t=0;t<11;t++) begin:g_filter_load
            assign filter_load_values[t]=shared_filter_values[c%16][t];
            assign filter_load_mask[t]=shared_filter_keep[c%16][t] &&
                ((t<1 && weight_strobe[0][(c+t)/16]) || (t<3 && weight_strobe[1][(c*3+t)/16]) ||
                 (t<5 && weight_strobe[2][(c*5+t)/16]) || (t<6 && weight_strobe[3][(c*6+t)/16]) || weight_strobe[4][(c*11+t)/16]);
        end
        alexnet_rs_filter_row_rf u_filter_row (
            .clk,.rst,.load_mask(filter_load_mask),.load_values(filter_load_values),.tap(mac_tap),.read_active(mac_valid),.weight(weights[c]));
        for(genvar r=0;r<4;r++) begin:g_pair
            alexnet_row_stationary_pe #(.ACC_W(ACC_W)) u_pe (
                .clk,.rst,.ce(state_q==PROCESS||source_fire),
                .input_write_valid(write_mask[r]&&input_row==c),.row_address,.mac_hi_tap,.input_write_value(write_value[r]),
                .row_weight(weights[c]),.mac_mask({c<rows_q&&2*r+1<m_q,c<rows_q&&2*r<m_q}),
                .mac_valid,.mac_first(mac_valid&&mac_tap==0),.mac_last(mac_valid&&mac_tap==width_q-1),
                .row_done(row_done[c][r]),.row_lo(lo[c][r]),.row_hi(hi[c][r]));
        end
    end
    // Exact growing widths: two signed19 row sums need signed20, then
    // signed21..26 across 128 rows. Continuation remains signed27.
    for(genvar s=0;s<7;s++) begin:g_tree
        localparam int W=20+s;
        logic signed [W-1:0] sum_q[0:(64>>s)-1][0:7];
        for(genvar c=0;c<(64>>s);c++) for(genvar m=0;m<8;m++) begin:g_cell
            logic signed [W-1:0] lhs,rhs;
            if(s==0) begin
                if(m%2==0) begin
                    assign lhs=W'($signed(lo[2*c][m/2]));assign rhs=W'($signed(lo[2*c+1][m/2]));
                end else begin
                    assign lhs=W'($signed(hi[2*c][m/2]));assign rhs=W'($signed(hi[2*c+1][m/2]));
                end
            end else begin
                assign lhs=W'($signed(g_tree[s-1].sum_q[2*c][m]));assign rhs=W'($signed(g_tree[s-1].sum_q[2*c+1][m]));
            end
            always_ff @(posedge clk)
                if(rst) sum_q[c][m]<=0;
                else if(ce && (s==0?row_done[0][0]:tree_valid_q[s-1])) sum_q[c][m]<=lhs+rhs;
        end
    end
    for(genvar m=0;m<8;m++) assign tree_result[m]=ACC_W'($signed(g_tree[6].sum_q[0][m]));
    always_ff @(posedge clk) begin
        if(rst) begin
            state_q<=IDLE;width_q<=1;m_q<=0;stride_q<=1;rows_q<=0;issued_tap_q<=0;tag_q<=0;tree_valid_q<=0;
            for(int m=0;m<8;m++) begin initial_q[m]<=0;result_q[m]<=0;end

        end else if(ce) begin
            if(input_clear) begin
                width_q<=config_row_width;stride_q<=config_stride;m_q<=config_m_count;
                rows_q<=8'(divide_row(config_k_count,config_row_width));
            end
            if(source_fire) begin
                tag_q<=source_tag;issued_tap_q<=1;state_q<=PROCESS;
                for(int m=0;m<8;m++) initial_q[m]<=ACC_W'($signed(source_psum[m]));
            end else if(state_q==PROCESS&&issued_tap_q<width_q) issued_tap_q<=issued_tap_q+1'b1;
            tree_valid_q<={tree_valid_q[5:0],row_done[0][0]};
            if(tree_valid_q[6]) begin
                for(int m=0;m<8;m++) result_q[m]<=checked_add(tree_result[m],initial_q[m]);
                state_q<=RESULT;
            end else if(result_valid&&result_ready) state_q<=IDLE;
        end
    end
`ifndef SYNTHESIS
    always_ff @(posedge clk) if(!rst) begin
        if(input_load_valid&&input_load_ready&&weight_load_valid&&weight_load_ready) $fatal(1,"RS simultaneous input/filter row load");
        if(source_fire&&(input_clear || input_load_valid || weight_load_valid)) $fatal(1,"RS overlapping row load and compute");
        if(input_clear&&(input_load_valid || weight_load_valid || source_valid)) $fatal(1,"RS context and row operation overlap");
        if(input_clear&&!idle) $fatal(1,"RS row context changed in flight");
        if(source_fire) for(int m=0;m<8;m++)
            if(32'(ACC_W'($signed(source_psum[m])))!=source_psum[m]) $fatal(1,"RS incoming psum width");
    end
`endif
endmodule
