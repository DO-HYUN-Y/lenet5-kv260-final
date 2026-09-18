`timescale 1ns/1ps
module tb_alexnet_row_stationary_gather;
 logic clk=0,rst=1;always #2.5 clk=~clk;
 logic request_valid,request_ready;
 logic [3:0] request_layer,request_m_count;
 logic [12:0] request_m_base;
 logic [13:0] request_k_offset;
 logic [11:0] request_k_count;
 logic [63:0] request_source_base;
 logic read_valid,read_ready;
 logic [63:0] read_address;
 logic response_valid,response_ready;
 logic [63:0] response_values;
 logic response_error;
 logic axis_valid,axis_ready,axis_last;
 logic [127:0] axis_values;
 logic busy,fault;
 logic [63:0] raw_read_bytes;
 logic [31:0] completed_tiles;
 alexnet_row_stationary_gather dut(.*);
 task automatic reset();
   @(negedge clk);rst=1;request_valid=0;read_ready=0;response_valid=0;axis_ready=0;
   repeat(3)@(negedge clk);rst=0;
 endtask
 task automatic send();
   @(negedge clk);request_valid=1;
   do @(posedge clk);while(!request_ready);
   // The producer may change every request field immediately after acceptance.
   @(negedge clk);request_valid=0;request_layer=0;request_m_count=0;
   request_m_base=8191;request_k_offset=16383;request_k_count=0;request_source_base=3;
 endtask
 initial begin
   request_valid=0;read_ready=0;response_valid=0;response_error=0;axis_ready=0;
   response_values=64'h8877665544332211;
   reset();request_layer=7;request_m_count=1;request_m_base=0;
   request_k_offset=3;request_k_count=1;request_source_base=64'h1000;
   send();wait(read_valid);
   repeat(3) begin
     @(negedge clk);
     if(!read_valid || read_address!=64'h1000 || fault)$fatal(1,"latched request/read stall");
   end
   read_ready=1;@(negedge clk);read_ready=0;
   wait(response_ready);@(negedge clk);response_valid=1;
   @(negedge clk);response_valid=0;wait(axis_valid);
   repeat(3) begin
     @(negedge clk);
     if(axis_values!=128'h44 || !axis_last || fault)$fatal(1,"FC input lane or output stall");
   end
   axis_ready=1;@(negedge clk);axis_ready=0;
   if(!request_ready || completed_tiles!=1 || raw_read_bytes!=8)$fatal(1,"valid gather totals");
   for(int bad=0;bad<7;bad++)begin
     reset();request_layer=1;request_m_count=1;request_m_base=0;
     request_k_offset=0;request_k_count=11;request_source_base=64'h1000;
     case(bad)
       0:request_layer=0;
       1:request_m_count=9;
       2:request_source_base=64'h1003;
       3:request_k_count=3;
       4:begin request_m_base=54;request_m_count=2;end
       5:request_k_offset=363;
       6:begin request_layer=7;request_m_base=1;request_k_count=1;end
     endcase
     send();repeat(8)begin
       @(negedge clk);
       if(read_valid || axis_valid || raw_read_bytes!=0)$fatal(1,"invalid request caused DDR/axis traffic");
     end
     if(!fault || request_ready)$fatal(1,"malformed gather request not latched bad=%0d",bad);
   end
   $display("ALEXNET_RS_GATHER_TEST_PASSED valid=1 invalid=7 live_request_changes=1 stalls=1");$finish;
 end
 initial begin #10000;$fatal(1,"gather test timeout");end
endmodule
