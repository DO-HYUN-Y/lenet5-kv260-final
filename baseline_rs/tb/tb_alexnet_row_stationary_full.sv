`timescale 1ns/1ps
module tb_alexnet_row_stationary_full;
    logic clk, rst;
    logic start_valid;
    logic start_ready;
    logic [15:0] start_tag;
    logic [63:0] input_base, activation_a_base, activation_b_base;
    logic [63:0] weights_base, parameters_base, final_output_base;
    logic main_command_valid;
    logic main_command_ready;
    logic main_command_s2mm;
    logic [63:0] main_command_address;
    logic [25:0] main_command_length;
    logic main_dma_armed, main_dma_done, main_dma_error;
    logic [127:0] main_read_data;
    logic [15:0] main_read_keep;
    logic main_read_valid, main_read_last;
    logic main_read_ready;
    logic [127:0] main_write_data;
    logic [15:0] main_write_keep;
    logic main_write_valid, main_write_last;
    logic main_write_ready;
    logic weight_dma_command_valid;
    logic weight_dma_command_ready;
    logic [63:0] weight_dma_command_address;
    logic [25:0] weight_dma_command_length;
    logic weight_dma_done, weight_dma_error;
    logic weight_axis_valid;
    logic weight_axis_ready;
    logic [127:0] weight_axis_values;
    logic [15:0] weight_axis_keep;
    logic weight_axis_last;
    logic inference_done, busy, fault;
    logic [3:0] active_layer;
    logic [31:0] completed_commands, completed_input_tiles;
    logic [63:0] useful_mac_count;
    logic [63:0] main_read_axis_bytes, main_write_axis_bytes;
    logic [63:0] weight_service_bytes, gather_requested_bytes;
    logic [31:0] main_completed_transfers, stored_packets;
    logic [31:0] result_signature;

 byte unsigned gold_conv1 [0:193599];
 byte unsigned gold_conv2 [0:139967];
 byte unsigned gold_conv3 [0:64895];
 byte unsigned gold_conv4 [0:43263];
 byte unsigned gold_conv5 [0:43263];
 byte unsigned gold_fc6 [0:4095];
 byte unsigned gold_fc7 [0:4095];
 byte unsigned gold_fc8 [0:999];
 byte unsigned gold_pool1 [0:46655];
 byte unsigned gold_pool2 [0:32447];
 byte unsigned gold_pool5 [0:9215];
 byte unsigned input_mem[0:401407],act_a[0:193663],act_b[0:140031],final_mem[0:1023];
 byte unsigned weights_mem[0:61090495],parameters_mem[0:165503];
 string vector_root,model_root,report_path;
 integer main_descriptors=0,weight_descriptors=0,raw_written=0,pooled_written=0;
 longint unsigned cycles=0;
 alexnet_row_stationary_ddr_engine dut(.*);
 always #2.5 clk=~clk;
 always @(posedge clk) if(!rst) begin
   cycles++;
   if(fault) $fatal(1,"full RS RTL fault layer=%d service=%d command=%d",active_layer,dut.state_q,completed_commands);
   if(dut.layer_complete_valid && dut.layer_complete_ready) begin
     $display("FULL_RS_LAYER_DONE layer=%0d commands=%0d cycle=%0d",dut.layer_complete_id,completed_commands,cycles);
     $fflush();
   end
 end
 function automatic byte unsigned read_byte(input longint unsigned address);
   if(address>=input_base && address<input_base+401408) return input_mem[address-input_base];
   if(address>=activation_a_base && address<activation_a_base+193664) return act_a[address-activation_a_base];
   if(address>=activation_b_base && address<activation_b_base+140032) return act_b[address-activation_b_base];
   if(address>=parameters_base && address<parameters_base+165504) return parameters_mem[address-parameters_base];
   $fatal(1,"full unmapped read %h",address);return 0;
 endfunction
 function automatic byte unsigned expected_byte(input integer layer,offset,input logic pooled);
   if(pooled) begin
     case(layer) 1:return gold_pool1[offset];2:return gold_pool2[offset];5:return gold_pool5[offset];default:$fatal(1,"bad pool layer");endcase
   end else case(layer)
 1:return gold_conv1[offset];
 2:return gold_conv2[offset];
 3:return gold_conv3[offset];
 4:return gold_conv4[offset];
 5:return gold_conv5[offset];
 6:return gold_fc6[offset];
 7:return gold_fc7[offset];
 8:return gold_fc8[offset];
     default:$fatal(1,"bad output layer");
   endcase
   return 0;
 endfunction
 task automatic load_gold(input string file_name,input integer index);
   integer fd,size;
   fd=$fopen({vector_root,"/",file_name},"rb");if(!fd) $fatal(1,"missing golden %s",file_name);
   case(index)
 0:size=$fread(gold_conv1,fd);
 1:size=$fread(gold_conv2,fd);
 2:size=$fread(gold_conv3,fd);
 3:size=$fread(gold_conv4,fd);
 4:size=$fread(gold_conv5,fd);
 5:size=$fread(gold_fc6,fd);
 6:size=$fread(gold_fc7,fd);
 7:size=$fread(gold_fc8,fd);
 8:size=$fread(gold_pool1,fd);
 9:size=$fread(gold_pool2,fd);
 10:size=$fread(gold_pool5,fd);
   endcase
   $fclose(fd);if(size<=0) $fatal(1,"empty golden");
 endtask
 task automatic write_byte(input longint unsigned address,input byte unsigned value);
   if(address>=activation_a_base && address<activation_a_base+193664) act_a[address-activation_a_base]=value;
   else if(address>=activation_b_base && address<activation_b_base+140032) act_b[address-activation_b_base]=value;
   else if(address>=final_output_base && address<final_output_base+1024) final_mem[address-final_output_base]=value;
   else $fatal(1,"full unmapped write %h",address);
 endtask
 task automatic serve_main;
   longint unsigned address,base;integer length,layer,offset,serial;logic writing,pooled,early;
   forever begin
     @(negedge clk);main_command_ready=1;
     do @(posedge clk);while(!(main_command_valid && main_command_ready));
     address=main_command_address;length=int'(main_command_length);writing=main_command_s2mm;
     pooled=dut.pool_busy;layer=pooled?int'(dut.layer_complete_id):int'(dut.packet_layer_q);
     serial=main_descriptors;main_descriptors++;
     @(negedge clk);main_command_ready=0;main_dma_armed=1;
     @(negedge clk);main_dma_armed=0;
     early=serial%17==0;
     if(early) begin main_dma_done=1;@(negedge clk);main_dma_done=0;end
     for(int index=0;index<length;index+=16) begin
       if(writing) begin
         main_write_ready=1;
         do @(posedge clk);while(!main_write_valid);
         if(main_write_keep!==(length-index>=16?16'hffff:16'hffff>>(16-(length-index))) ||
            main_write_last!=(index+16>=length)) $fatal(1,"full write frame");
         base=layer==8?final_output_base:layer%2==1?activation_a_base:activation_b_base;
         for(int j=0;j<16 && index+j<length;j++) begin
           offset=int'(address-base)+index+j;
           if(main_write_data[j*8+:8]!==expected_byte(layer,offset,pooled))
             $fatal(1,"full output mismatch layer=%d pooled=%d byte=%d got=%h expected=%h",layer,pooled,offset,main_write_data[j*8+:8],expected_byte(layer,offset,pooled));
           write_byte(address+index+j,main_write_data[j*8+:8]);
           if(pooled) pooled_written++;else raw_written++;
         end
         @(negedge clk);main_write_ready=0;
       end else begin
         main_read_data=0;
         for(int j=0;j<16 && index+j<length;j++) main_read_data[j*8+:8]=read_byte(address+index+j);
         main_read_keep=length-index>=16?16'hffff:16'hffff>>(16-(length-index));
         main_read_last=index+16>=length;main_read_valid=1;
         do @(posedge clk);while(!main_read_ready);
         @(negedge clk);main_read_valid=0;
       end
     end
     if(!early) begin
       repeat(2) @(negedge clk);main_dma_done=1;@(negedge clk);main_dma_done=0;
     end
   end
 endtask
 task automatic serve_weights;
   longint unsigned address;integer length,serial;logic early;
   forever begin
     @(negedge clk);weight_dma_command_ready=1;
     do @(posedge clk);while(!(weight_dma_command_valid && weight_dma_command_ready));
     address=weight_dma_command_address;length=int'(weight_dma_command_length);serial=weight_descriptors;weight_descriptors++;
     if(address<weights_base || address+64'(length)>weights_base+61090496 || length<1 || length>1408) $fatal(1,"full weight bounds");
     @(negedge clk);weight_dma_command_ready=0;
     early=serial%19==0;
     if(early) begin weight_dma_done=1;@(negedge clk);weight_dma_done=0;end
     for(int index=0;index<length;index+=16) begin
       weight_axis_values=0;
       for(int j=0;j<16 && index+j<length;j++) weight_axis_values[j*8+:8]=weights_mem[address-weights_base+64'(index+j)];
       weight_axis_keep=length-index>=16?16'hffff:16'hffff>>(16-(length-index));
       weight_axis_last=index+16>=length;weight_axis_valid=1;
       do @(posedge clk);while(!weight_axis_ready);
       @(negedge clk);weight_axis_valid=0;
     end
     if(!early) begin repeat(2) @(negedge clk);weight_dma_done=1;@(negedge clk);weight_dma_done=0;end
   end
 endtask
 initial begin
   integer fd,size;
   if(!$value$plusargs("vector_root=%s",vector_root) || !$value$plusargs("model_root=%s",model_root) || !$value$plusargs("report=%s",report_path)) $fatal(1,"paths required");
   fd=$fopen({model_root,"/weights_rs.bin"},"rb");if(!fd)$fatal(1,"weights missing");size=$fread(weights_mem,fd);$fclose(fd);if(size!=61090496)$fatal(1,"weight length");
   fd=$fopen({model_root,"/parameters_board.bin"},"rb");if(!fd)$fatal(1,"parameters missing");size=$fread(parameters_mem,fd);$fclose(fd);if(size!=165504)$fatal(1,"parameter length");
   fd=$fopen({vector_root,"/input_n8.bin"},"rb");if(!fd)$fatal(1,"input missing");size=$fread(input_mem,fd);$fclose(fd);if(size!=401408)$fatal(1,"input length");
 load_gold("conv1_n8.bin",0);
 load_gold("conv2_n8.bin",1);
 load_gold("conv3_n8.bin",2);
 load_gold("conv4_n8.bin",3);
 load_gold("conv5_n8.bin",4);
 load_gold("fc6_n8.bin",5);
 load_gold("fc7_n8.bin",6);
 load_gold("fc8_n8.bin",7);
 load_gold("pool1_n8.bin",8);
 load_gold("pool2_n8.bin",9);
 load_gold("pool5_n8.bin",10);
   for(int i=0;i<193664;i++) act_a[i]=8'h5b;
   for(int i=0;i<140032;i++) act_b[i]=8'h9c;
   for(int i=0;i<1024;i++) final_mem[i]=8'h66;
   clk=0;rst=1;start_valid=0;start_tag=16'h1234;
   input_base='h100000;activation_a_base='h200000;activation_b_base='h300000;
   weights_base='h400000;parameters_base='h5000000;final_output_base='h5100000;
   main_command_ready=0;main_dma_armed=0;main_dma_done=0;main_dma_error=0;
   main_read_data=0;main_read_keep=0;main_read_valid=0;main_read_last=0;main_write_ready=0;
   weight_dma_command_ready=0;weight_dma_done=0;weight_dma_error=0;
   weight_axis_valid=0;weight_axis_values=0;weight_axis_keep=0;weight_axis_last=0;
   repeat(8) @(negedge clk);rst=0;start_valid=1;
   do @(posedge clk);while(!start_ready);
   @(negedge clk);start_valid=0;
   fork serve_main();serve_weights();join_none
   wait(inference_done);@(negedge clk);
   if(fault || completed_commands!=56104 || completed_input_tiles!=1305 || useful_mac_count!=714188480 ||
      weight_service_bytes!=156334784 || main_write_axis_bytes!=582504 ||
      raw_written!=494184 || pooled_written!=88320)
      $fatal(1,"full RS totals: cmds=%d inputs=%d MAC=%d weights=%d read=%d write=%d gather=%d raw=%d pool=%d",completed_commands,completed_input_tiles,useful_mac_count,weight_service_bytes,main_read_axis_bytes,main_write_axis_bytes,gather_requested_bytes,raw_written,pooled_written);
   for(int n=0;n<1000;n++) if(final_mem[n]!==gold_fc8[n]) $fatal(1,"FC8 final mismatch");
   fd=$fopen(report_path,"w");
   $fdisplay(fd,"{\"scope\":\"full trained-model RTL with behavioral DMA/DDR services\",\"physical_ddr_measured\":false,\"all_raw_and_pooled_output_bytes_match\":true,\"commands\":%0d,\"input_tiles\":%0d,\"useful_macs\":%0d,\"cycles\":%0d,\"main_read_axis_bytes\":%0d,\"main_write_axis_bytes\":%0d,\"weight_axis_bytes\":%0d,\"gather_requested_bytes\":%0d,\"main_dma_descriptors\":%0d,\"weight_dma_descriptors\":%0d}",completed_commands,completed_input_tiles,useful_mac_count,cycles,main_read_axis_bytes,main_write_axis_bytes,weight_service_bytes,gather_requested_bytes,main_descriptors,weight_descriptors);
   $fclose(fd);
   $display("ALEXNET_ROW_STATIONARY_FULL_RTL_TEST_PASSED commands=%0d inputs=%0d MAC=%0d cycles=%0d",completed_commands,completed_input_tiles,useful_mac_count,cycles);
   $finish;
 end
 initial begin #2000000000;$fatal(1,"full RS timeout layer=%d command=%d",active_layer,completed_commands);end
endmodule
