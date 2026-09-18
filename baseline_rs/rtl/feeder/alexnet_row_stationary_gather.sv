`timescale 1ns/1ps
// Raw N8-tile-major DDR -> K-major M16 input-bank words (low M8 used).
// A 39-word (312-byte payload) input-row buffer reuses overlapping windows
// and all eight channels of each N8 word. FC6 reuses the 36-word pool5 plane.
// A single row/channel-group tag replaces the buffer on a row change.
(* use_dsp = "no" *) module alexnet_row_stationary_gather (
    input logic clk, rst,
    input logic request_valid,
    output logic request_ready,
    input logic [3:0] request_layer, request_m_count,
    input logic [12:0] request_m_base,
    input logic [13:0] request_k_offset,
    input logic [11:0] request_k_count,
    input logic [63:0] request_source_base,
    output logic read_valid,
    input logic read_ready,
    output logic [63:0] read_address,
    input logic response_valid,
    output logic response_ready,
    input logic [63:0] response_values,
    input logic response_error,
    output logic axis_valid,
    input logic axis_ready,
    output logic [127:0] axis_values,
    output logic axis_last,
    output logic busy, fault,
    output logic [63:0] raw_read_bytes,
    output logic [31:0] completed_tiles
);
    typedef enum logic [3:0] {IDLE, INDEX, DECODE, REMAINDER, COORDINATE, OFFSET, ADDRESS, LOOKUP, READ, RESPONSE, EMIT, FAILED} state_t;
    state_t state_q;
    logic [3:0] layer_q, mc_q;
    logic [12:0] mb_q;
    logic [13:0] ko_q;
    logic [11:0] kc_q, k_q;
    logic [2:0] m_q, lane_q;
    logic [63:0] base_q, address_q, values_q;
    logic [63:0] word_values_q [0:38];
    logic [38:0] word_valid_q;
    logic [22:0] word_key_q, lookup_key;
    logic [5:0] lookup_index;
    logic key_valid_q;
    logic fields_ok;
    // Registered fixed-geometry address stages. No generic divider/multiplier
    // is placed on the array enable path; all constants are layer-specific.
    logic [12:0] absolute_m_q, output_y_q, output_x_q;
    logic [13:0] absolute_k_q, kernel_position_q, channel_q;
    logic [3:0] kernel_y_q, kernel_x_q;
    logic signed [11:0] source_y_q, source_x_q;
    logic [19:0] channel_offset_q, spatial_offset_q;
    logic padding_q;
    function automatic integer layer_k(input logic [3:0] layer);
        case(layer)
            1: return 363; 2: return 1600; 3: return 1728;
            4: return 3456; 5: return 2304; 6: return 9216;
            7,8: return 4096; default: return 0;
        endcase
    endfunction
    function automatic integer layer_m(input logic [3:0] layer);
        case(layer)
            1: return 3025; 2: return 729; 3,4,5: return 169;
            6,7,8: return 1; default: return 0;
        endcase
    endfunction
    assign fields_ok=request_layer>=1 && request_layer<=8 &&
        request_m_count>=1 && request_m_count<=8 &&
        request_k_count>=1 && request_k_count<=128*row_width(request_layer) &&
        {1'b0,request_m_base}+request_m_count<=layer_m(request_layer) &&
        {1'b0,request_k_offset}+request_k_count<=layer_k(request_layer) &&
        request_source_base[2:0]==0 &&
        row_aligned(request_layer,request_k_offset) && row_aligned(request_layer,{2'd0,request_k_count}) &&
        same_output_row(request_layer,request_m_base,request_m_count);
    function automatic integer row_width(input logic [3:0] layer);
        case(layer)1:return 11;2:return 5;3,4,5:return 3;6:return 6;default:return 1;endcase
    endfunction
    function automatic logic row_aligned(input logic [3:0] layer,input logic [13:0] k);
        case(layer)1:return k%11==0;2:return k%5==0;3,4,5:return k%3==0;6:return k%6==0;default:return 1;endcase
    endfunction
    function automatic logic same_output_row(input logic[3:0] layer,input logic[12:0] m,input logic[3:0] count);
        case(layer)1:return m%55+count<=55;2:return m%27+count<=27;3,4,5:return m%13+count<=13;default:return count==1;endcase
    endfunction
    always_comb begin
        lookup_key={channel_q[13:3],source_y_q};
        lookup_index=6'(int'(m_q)*(layer_q==1?4:1)+int'(kernel_x_q));
        if(layer_q==6) begin lookup_key={channel_q[13:3],12'd0};lookup_index=6'(spatial_offset_q);end
        else if(layer_q>=7) begin lookup_key={channel_q[13:3],12'd0};lookup_index=0;end
    end
    assign request_ready=state_q==IDLE;
    assign read_valid=state_q==READ;
    assign read_address=address_q;
    assign response_ready=state_q==RESPONSE;
    assign axis_valid=state_q==EMIT;
    assign axis_values={64'd0,values_q};
    assign axis_last=k_q+1==kc_q;
    assign busy=state_q!=IDLE;
    assign fault=state_q==FAILED;
    task automatic advance_lane();
        if({1'b0,m_q}+1==mc_q) state_q<=EMIT;
        else begin m_q<=m_q+1'b1; state_q<=INDEX; end
    endtask
    always_ff @(posedge clk) begin
        if(rst) begin
            state_q<=IDLE; layer_q<=0; mc_q<=0; mb_q<=0; ko_q<=0; kc_q<=0;
            k_q<=0; m_q<=0; lane_q<=0; base_q<=0; address_q<=0; values_q<=0;
            absolute_m_q<=0; absolute_k_q<=0; output_y_q<=0; output_x_q<=0;
            kernel_position_q<=0; channel_q<=0; kernel_y_q<=0; kernel_x_q<=0;
            source_y_q<=0; source_x_q<=0; channel_offset_q<=0; spatial_offset_q<=0; padding_q<=0;
            word_valid_q<=0;word_key_q<=0;key_valid_q<=0; raw_read_bytes<=0; completed_tiles<=0;
            for(int i=0;i<39;i++) word_values_q[i]<=0;
        end else begin
            case(state_q)
                IDLE: if(request_valid) begin
                    if(!fields_ok) state_q<=FAILED;
                    else begin
                        layer_q<=request_layer; mc_q<=request_m_count; mb_q<=request_m_base;
                        ko_q<=request_k_offset; kc_q<=request_k_count; base_q<=request_source_base;
                        k_q<=0; m_q<=0; values_q<=0; word_valid_q<=0;key_valid_q<=0; state_q<=INDEX;
                    end
                end
                INDEX: begin
                    absolute_m_q<=mb_q+13'(m_q); absolute_k_q<=ko_q+14'(k_q); state_q<=DECODE;
                end
                DECODE: begin
                    case(layer_q)
                        1: begin kernel_position_q<=absolute_k_q/11;kernel_x_q<=4'(absolute_k_q%11);output_y_q<=absolute_m_q/55;end
                        2: begin kernel_position_q<=absolute_k_q/5;kernel_x_q<=4'(absolute_k_q%5);output_y_q<=absolute_m_q/27;end
                        3,4,5: begin kernel_position_q<=absolute_k_q/3;kernel_x_q<=4'(absolute_k_q%3);output_y_q<=absolute_m_q/13;end
                        6: channel_q<=absolute_k_q/36;
                        default:channel_q<=absolute_k_q;
                    endcase
                    state_q<=REMAINDER;
                end
                REMAINDER: begin
                    case(layer_q)
                        1:begin channel_q<=kernel_position_q%3;kernel_y_q<=4'(kernel_position_q/3);output_x_q<=absolute_m_q-output_y_q*55;end
                        2:begin channel_q<=kernel_position_q%64;kernel_y_q<=4'(kernel_position_q/64);output_x_q<=absolute_m_q-output_y_q*27;end
                        3:begin channel_q<=kernel_position_q%192;kernel_y_q<=4'(kernel_position_q/192);output_x_q<=absolute_m_q-output_y_q*13;end
                        4:begin channel_q<=kernel_position_q%384;kernel_y_q<=4'(kernel_position_q/384);output_x_q<=absolute_m_q-output_y_q*13;end
                        5:begin channel_q<=kernel_position_q%256;kernel_y_q<=4'(kernel_position_q/256);output_x_q<=absolute_m_q-output_y_q*13;end
                        6:spatial_offset_q<=20'(absolute_k_q-channel_q*36);
                        default:spatial_offset_q<=0;
                    endcase
                    state_q<=COORDINATE;
                end
                COORDINATE: begin
                    case(layer_q)
                        1: begin source_y_q<=12'(output_y_q*4+kernel_y_q)-2; source_x_q<=12'(output_x_q*4+kernel_x_q)-2; end
                        2: begin source_y_q<=12'(output_y_q+kernel_y_q)-2; source_x_q<=12'(output_x_q+kernel_x_q)-2; end
                        default: begin source_y_q<=12'(output_y_q+kernel_y_q)-1; source_x_q<=12'(output_x_q+kernel_x_q)-1; end
                    endcase
                    state_q<=OFFSET;
                end
                OFFSET: begin
                    lane_q<=channel_q[2:0]; padding_q<=0;
                    case(layer_q)
                        1: begin
                            channel_offset_q<=0; spatial_offset_q<=20'(source_y_q*224+source_x_q);
                            padding_q<=source_y_q<0 || source_x_q<0 || source_y_q>=224 || source_x_q>=224;
                        end
                        2: begin
                            channel_offset_q<=20'((channel_q>>3)*729); spatial_offset_q<=20'(source_y_q*27+source_x_q);
                            padding_q<=source_y_q<0 || source_x_q<0 || source_y_q>=27 || source_x_q>=27;
                        end
                        3,4,5: begin
                            channel_offset_q<=20'((channel_q>>3)*169); spatial_offset_q<=20'(source_y_q*13+source_x_q);
                            padding_q<=source_y_q<0 || source_x_q<0 || source_y_q>=13 || source_x_q>=13;
                        end
                        6: channel_offset_q<=20'((channel_q>>3)*36);
                        default: channel_offset_q<=20'(absolute_k_q>>3);
                    endcase
                    state_q<=ADDRESS;
                end
                ADDRESS: begin
                    address_q<=base_q+(64'(channel_offset_q+spatial_offset_q)<<3);
                    if(padding_q) begin values_q[m_q*8+:8]<=0; advance_lane(); end
                    else state_q<=LOOKUP;
                end
                LOOKUP: begin
                    if(key_valid_q && word_key_q==lookup_key && word_valid_q[lookup_index]) begin
                        values_q[m_q*8+:8]<=word_values_q[lookup_index][lane_q*8+:8]; advance_lane();
                    end else begin
                        if(!key_valid_q || word_key_q!=lookup_key) begin word_valid_q<=0;word_key_q<=lookup_key;key_valid_q<=1;end
                        state_q<=READ;
                    end
                end
                READ: if(read_ready) begin raw_read_bytes<=raw_read_bytes+8; state_q<=RESPONSE; end
                RESPONSE: if(response_valid) begin
                    if(response_error) state_q<=FAILED;
                    else begin
                        values_q[m_q*8+:8]<=response_values[lane_q*8+:8];
                        word_values_q[lookup_index]<=response_values;
                        word_valid_q[lookup_index]<=1; advance_lane();
                    end
                end
                EMIT: if(axis_ready) begin
                    if(axis_last) begin completed_tiles<=completed_tiles+1; state_q<=IDLE; end
                    else begin k_q<=k_q+1; m_q<=0; values_q<=0; state_q<=INDEX; end
                end
                default: ;
            endcase
        end
    end
`ifndef SYNTHESIS
    always_ff @(posedge clk) if(!rst && state_q==LOOKUP && lookup_index>=39) $fatal(1,"RS input row buffer index");
`endif
endmodule
