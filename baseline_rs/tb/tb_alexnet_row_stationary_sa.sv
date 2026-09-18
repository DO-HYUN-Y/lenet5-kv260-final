`timescale 1ns/1ps
module tb_alexnet_row_stationary_sa;
 logic clk=0,rst=1,input_clear=0,input_load_valid=0,input_load_ready;
 logic [11:0] config_k_count,input_k;
 logic [3:0] config_m_count,config_row_width;
 logic [2:0] config_stride;
 logic signed[7:0] input_lo[0:3],input_hi[0:3];logic[1:0] input_mask[0:3];
 logic weight_load_valid=0,weight_load_ready;logic[6:0] weight_word;logic[127:0] weight_values;logic[15:0] weight_keep;
 logic source_valid=0,source_ready,result_valid,result_ready=0,idle;
 logic signed[31:0] source_psum[0:7],result_psum[0:7];logic[15:0] source_tag,result_tag;
 integer tests=0,extreme=0;integer widths[5]='{1,3,5,6,11};integer rows[4]='{1,33,64,128};integer ms[5]='{1,3,5,7,8};
 alexnet_sa_m8r128_row_stationary dut(.*);
 always #2.5 clk=~clk;
 function automatic integer activation(input integer r,x);
   return extreme!=0?-128:((r*19+x*23+37)%256)-128;
 endfunction
 function automatic integer weight_value(input integer k,n);
   return extreme==1?-128:extreme==2?127:((k*29+n*71+13)%256)-128;
 endfunction
 task automatic run_case(input integer w,r,mc);
   integer stride,kc;integer expected[8],snapshot[8];
   stride=w==11?4:1;kc=w*r;
   @(negedge clk);config_row_width=4'(w);config_stride=3'(stride);config_m_count=4'(mc);config_k_count=12'(kc);input_clear=1;
   @(negedge clk);input_clear=0;
   for(int k=0;k<kc;k++) begin
     input_load_valid=1;input_k=12'(k);
     for(int p=0;p<4;p++) begin
       input_lo[p]=8'(activation(k/w,2*p*stride+k%w));input_hi[p]=8'(activation(k/w,(2*p+1)*stride+k%w));
       input_mask[p]={2*p+1<mc,2*p<mc};
     end
     do @(posedge clk);while(!input_load_ready);
     @(negedge clk);input_load_valid=0;
     if(k%23==0) repeat(2) @(negedge clk);
   end
   for(int n=0;n<2;n++) begin
     for(int word_index=0;word_index<(kc+15)/16;word_index++) begin
       weight_word=7'(word_index);weight_values=0;weight_keep=0;
       for(int j=0;j<16;j++) if(word_index*16+j<kc) begin
         weight_values[j*8+:8]=8'(weight_value(word_index*16+j,n));weight_keep[j]=1;
       end
       weight_load_valid=1;
       do @(posedge clk);while(!weight_load_ready);
       @(negedge clk);weight_load_valid=0;
     end
     for(int m=0;m<8;m++) begin
       source_psum[m]=m<mc?((m+n)%2==0?1000000:-1000000):0;expected[m]=source_psum[m];
       if(m<mc) for(int k=0;k<kc;k++) expected[m]+=activation(k/w,m*stride+k%w)*weight_value(k,n);
     end
     source_tag=16'(tests*2+n);source_valid=1;
     do @(posedge clk);while(!source_ready);
     @(negedge clk);source_valid=0;
     wait(result_valid);@(negedge clk);
     if(result_tag!=source_tag) $fatal(1,"RS SA tag");
     for(int m=0;m<8;m++) begin
       if(result_psum[m]!==expected[m]) $fatal(1,"RS SA mismatch w=%d rows=%d M=%d n=%d lane=%d got=%d want=%d",w,r,mc,n,m,result_psum[m],expected[m]);
       snapshot[m]=result_psum[m];
     end
     repeat(7) begin @(negedge clk);
       if(!result_valid || result_tag!=source_tag) $fatal(1,"RS SA stalled valid/tag");
       for(int m=0;m<8;m++) if(result_psum[m]!==snapshot[m]) $fatal(1,"RS SA stalled result");
     end
     result_ready=1;@(posedge clk);@(negedge clk);result_ready=0;
     if(!idle) $fatal(1,"RS SA did not retire");
   end
   tests++;
 endtask
 initial begin
   config_k_count=0;config_m_count=0;config_row_width=1;config_stride=1;input_k=0;weight_word=0;weight_values=0;weight_keep=0;source_tag=0;
   for(int p=0;p<4;p++) begin input_lo[p]=0;input_hi[p]=0;input_mask[p]=0;end
   for(int m=0;m<8;m++) source_psum[m]=0;
   repeat(5) @(negedge clk);rst=0;
   for(int wi=0;wi<5;wi++) for(int ri=0;ri<4;ri++) run_case(widths[wi],rows[ri],ms[(wi+ri)%5]);
   extreme=1;run_case(11,128,8);extreme=2;run_case(11,128,8);
   $display("ALEXNET_ROW_STATIONARY_SA_TEST_PASSED contexts=%0d N_tokens=%0d",tests,tests*2);$finish;
 end
 initial begin #10000000;$fatal(1,"RS SA timeout");end
endmodule
