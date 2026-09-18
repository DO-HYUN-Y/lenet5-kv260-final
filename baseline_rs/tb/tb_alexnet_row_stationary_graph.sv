`timescale 1ns/1ps
module tb_alexnet_row_stationary_graph;
    logic clk, rst;
    logic start_valid;
    logic start_ready;
    logic [15:0] start_tag;
    logic input_request_valid;
    logic input_request_ready;
    logic [3:0] layer_id;
    logic [12:0] m_base;
    logic [3:0] m_count;
    logic [13:0] k_offset;
    logic [11:0] k_count;
    logic input_done, input_error;
    logic command_valid;
    logic command_ready;
    logic [15:0] n_base;
    logic [3:0] n_count;
    logic first_k, final_k;
    logic [15:0] command_tag;
    logic command_done, command_error;
    logic layer_complete_valid;
    logic layer_complete_ready;
    logic layer_requires_pool;
    logic inference_done, fault, busy;
    logic [31:0] completed_commands;
    logic [31:0] completed_input_tiles;
  alexnet_row_stationary_graph_scheduler dut (.*);
  int fd, input_pending, command_pending, barriers, input_requests;
  longint unsigned macs, weights, inputs, psum_reads, psum_writes, outputs;
  int expected_layer, expected_m, expected_k, expected_n;
  int mt,nt,kt,ow,rw,block,mc;
  logic[3:0] row_width;logic[2:0] window_stride;
  always #2.5 clk=~clk;
  task automatic geometry(input int l);
    case(l)
      1: begin mt=3025;nt=64;kt=363;end
      2: begin mt=729;nt=192;kt=1600;end
      3: begin mt=169;nt=384;kt=1728;end
      4: begin mt=169;nt=256;kt=3456;end
      5: begin mt=169;nt=256;kt=2304;end
      6: begin mt=1;nt=4096;kt=9216;end
      7: begin mt=1;nt=4096;kt=4096;end
      8: begin mt=1;nt=1000;kt=4096;end
    endcase
    case(l)1:begin ow=55;rw=11;end 2:begin ow=27;rw=5;end 3,4,5:begin ow=13;rw=3;end 6:begin ow=1;rw=6;end default:begin ow=1;rw=1;end endcase
    block=128*rw;mc=ow-expected_m%ow>8?8:ow-expected_m%ow;
  endtask
  always @(negedge clk) begin
    input_request_ready=!rst && input_pending==0 && $urandom_range(0,3)!=0;
    command_ready=!rst && command_pending==0 && $urandom_range(0,3)!=0;
    input_done=0; command_done=0;
    layer_complete_ready=!rst && $urandom_range(0,3)!=0;
    if(input_pending>0) begin
      input_pending--;
      if(input_pending==0) input_done=1;
    end
    if(command_pending>0) begin
      command_pending--;
      if(command_pending==0) command_done=1;
    end
  end
  always @(posedge clk) if(!rst) begin
    if(input_request_valid && input_request_ready) begin
      if(n_base!=0) $fatal(1,"RS input reloaded before all N");
      input_pending=$urandom_range(1,4);
      input_requests++;
      inputs+=longint'(m_count)*k_count;
    end
    if(layer_complete_valid && layer_complete_ready) begin
      barriers++;
      if(layer_requires_pool!=(layer_id==1 || layer_id==2 || layer_id==5))
        $fatal(1,"RS pool barrier mismatch");
    end
    if(command_valid && command_ready) begin
      geometry(expected_layer);
      if(layer_id!=expected_layer || m_base!=expected_m || k_offset!=expected_k || n_base!=expected_n ||
          m_count!=mc ||
          n_count!=(nt-expected_n>8?8:nt-expected_n) ||
          k_count!=(kt-expected_k>block?block:kt-expected_k) ||
          first_k!=(expected_k==0) || final_k!=(expected_k+block>=kt))
        $fatal(1,"RS graph descriptor mismatch");
      if(row_width!=rw || window_stride!=(layer_id==1?4:1) || k_offset%rw || k_count%rw || m_base%ow+m_count>ow)
        $fatal(1,"RS primitive row boundary/alignment mismatch");
      command_pending=$urandom_range(1,4);
      macs+=longint'(m_count)*n_count*k_count;
      weights+=longint'(n_count)*k_count;
      if(!first_k) psum_reads+=longint'(m_count)*n_count*4;
      if(!final_k) psum_writes+=longint'(m_count)*n_count*4;
      else outputs+=longint'(m_count)*n_count;
      $fdisplay(fd,"%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d",
          layer_id,m_base,m_count,k_offset,k_count,n_base,n_count,first_k,final_k);
      if(expected_n+8<nt) expected_n+=8;
      else begin
        expected_n=0;
        if(expected_k+block<kt) expected_k+=block;
        else begin
          expected_k=0;
          if(expected_m+mc<mt) expected_m+=mc;
          else begin expected_m=0;expected_layer++;end
        end
      end
    end
  end
  initial begin
    int seed_sink;
    seed_sink=$urandom(32'h1500_8128);
    clk=0;rst=1;start_valid=0;start_tag=16'h1580;input_error=0;command_error=0;
    input_done=0;command_done=0;input_pending=0;command_pending=0;
    barriers=0; input_requests=0;macs=0;weights=0;inputs=0;psum_reads=0;psum_writes=0;outputs=0;
    expected_layer=1;expected_m=0;expected_k=0;expected_n=0;
    fd=$fopen("pure_rs_schedule.csv","w");
    if(!fd) $fatal(1,"cannot create RS graph trace");
    $fwrite(fd,"layer,m_base,m_count,k_offset,k_count,n_base,n_count,first_k,final_k\n");
    repeat(8) @(negedge clk);rst=0;
    @(negedge clk);start_valid=1;
    do @(posedge clk);while(!start_ready);
    @(negedge clk);start_valid=0;
    wait(inference_done);
    if(fault || completed_commands!=56104 || completed_input_tiles!=1305 ||
        input_requests!=1305 || barriers!=7 || expected_layer!=9 || macs!=714188480)
      $fatal(1,"RS full graph totals mismatch commands=%0d inputs=%0d macs=%0d",
          completed_commands,completed_input_tiles,macs);
    $fclose(fd);
    $display("ALEXNET_ROW_STATIONARY_GRAPH_TEST_PASSED commands=%0d input_tiles=%0d macs=%0d weights=%0d inputs=%0d psum_reads=%0d psum_writes=%0d outputs=%0d",
        completed_commands,completed_input_tiles,macs,weights,inputs,psum_reads,psum_writes,outputs);
    $finish;
  end
  initial begin #20000000; $fatal(1,"RS graph test timeout");end
endmodule
