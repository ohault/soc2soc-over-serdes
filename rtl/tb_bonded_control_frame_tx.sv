// SPDX-License-Identifier: BSD-2-Clause
module tb_bonded_control_frame_tx;
 reg clk=0; always #5 clk=~clk;
 reg rst=1, ctrl_valid=0, out_ready=1;
 reg [63:0] session_id=64'h0123456789abcdef;
 reg [207:0] body=0;
 reg [5:0] body_len=0;
 wire ctrl_ready,out_valid,out_sop,out_eop;
 wire [7:0] out_data;
 wire [31:0] next_seq;
 wire frame_error;
 reg [7:0] captured[0:63];
 integer count=0,i;
 reg [15:0] c16;
 reg [31:0] c32;
 bonded_control_frame_tx #(.LANE_ID(1)) dut(
 .clk(clk),.rst(rst),.session_id(session_id),.frame_start_enable(1'b1),.frame_sequence_override(32'd0),.ctrl_valid(ctrl_valid),.ctrl_ready(ctrl_ready),
 .ctrl_body(body),.ctrl_body_length(body_len),.out_valid(out_valid),.out_ready(out_ready),
 .out_data(out_data),.out_sop(out_sop),.out_eop(out_eop),
 .next_frame_sequence(next_seq),.frame_error(frame_error));
 function [15:0] crc16_byte(input [15:0] ci,input [7:0] d);
 integer k; reg [15:0] c; begin c=ci^{d,8'h00};for(k=0;k<8;k=k+1)c=c[15]?((c<<1)^16'h1021):(c<<1);crc16_byte=c;end endfunction
 function [31:0] crc32_byte(input [31:0] ci,input [7:0] d);
 integer k; reg [31:0] c; begin c=ci^d;for(k=0;k<8;k=k+1)c=c[0]?((c>>1)^32'h82f63b78):(c>>1);crc32_byte=c;end endfunction
 task send_credit;
 begin
   body=0; body[207:200]=8'h03;
   body[199:136]=64'h0000000000001000;
   body[135:104]=32'h00000020;
   body_len=13;
   @(negedge clk);ctrl_valid=1;
   @(posedge clk);
   @(negedge clk);ctrl_valid=0;
   count=0;
   while(count<41) begin
     @(posedge clk);
     if(out_valid && out_ready) begin
       captured[count]=out_data;
       if(out_sop !== (count==0)) $fatal(1,"SOP mismatch at %0d",count);
       if(out_eop !== (count==40)) $fatal(1,"EOP mismatch at %0d",count);
       count=count+1;
     end
   end
 end endtask
 initial begin
   repeat(3) @(posedge clk); rst=0;
   send_credit();
   if(captured[0]!=8'h53 || captured[1]!=8'h42 || captured[3]!=8'h02 ||
      captured[5]!=8'h01 || captured[7]!=8'h18)
      $fatal(1,"CONTROL header mismatch");
   if(captured[8]!=8'h01 || captured[15]!=8'hef ||
      captured[16]!=0 || captured[19]!=0)
      $fatal(1,"session/frame sequence mismatch");
   c16=16'hffff;
   for(i=0;i<22;i=i+1)c16=crc16_byte(c16,captured[i]);
   if(captured[22]!=(c16>>8) || captured[23]!=(c16&8'hff))
      $fatal(1,"header CRC16 mismatch");
   c32=32'hffffffff;
   for(i=0;i<37;i=i+1)c32=crc32_byte(c32,captured[i]);
   c32=~c32;
   if(captured[37]!=((c32>>24)&8'hff) || captured[38]!=((c32>>16)&8'hff) ||
      captured[39]!=((c32>>8)&8'hff) || captured[40]!=(c32&8'hff))
      $fatal(1,"frame CRC32C mismatch");
   if(captured[24]!=8'h03 || captured[25]!=0 || captured[32]!=8'h10 ||
      captured[33]!=0 || captured[34]!=0 || captured[35]!=0 || captured[36]!=8'h20)
      $fatal(1,"CREDIT body byte order/fields mismatch");
   if(next_seq!=1 || frame_error)$fatal(1,"sequence/error status mismatch");
   // Invalid opcode is accepted as an input transaction but never emitted.
   @(negedge clk); body=0;body[207:200]=8'hff;body_len=1;ctrl_valid=1;
   @(posedge clk); @(negedge clk);ctrl_valid=0;
   repeat(2) @(posedge clk);
   if(!frame_error || next_seq!=1)$fatal(1,"invalid control body not rejected");
   $display("PASS: CONTROL envelope, HELLO-independent CREDIT body, CRC16, CRC32C, sequence and invalid-opcode rejection");
   $finish;
 end
endmodule
