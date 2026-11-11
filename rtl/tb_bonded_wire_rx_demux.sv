// SPDX-License-Identifier: BSD-2-Clause
module tb_bonded_wire_rx_demux;
 reg clk=0; always #5 clk=~clk;
 reg rst=1,data_enable=1,in_valid=0,in_sop=0,in_eop=0;
 reg [7:0] in_data=0;
 wire in_ready,data_valid,ctrl_valid,data_sop,data_eop,ctrl_sop,ctrl_eop,frame_error;
 wire [7:0] data_data,ctrl_data;
 integer ctrl_count=0;
 bonded_wire_rx_demux dut(
  .clk(clk),.rst(rst),.data_enable(data_enable),
  .in_valid(in_valid),.in_ready(in_ready),.in_data(in_data),.in_sop(in_sop),.in_eop(in_eop),
  .data_valid(data_valid),.data_ready(1'b1),.data_data(data_data),.data_sop(data_sop),.data_eop(data_eop),
  .ctrl_valid(ctrl_valid),.ctrl_ready(1'b1),.ctrl_data(ctrl_data),.ctrl_sop(ctrl_sop),.ctrl_eop(ctrl_eop),
  .frame_error(frame_error));
 always @(posedge clk) if(ctrl_valid) ctrl_count=ctrl_count+1;
 task send(input [7:0] b,input bit sop,input bit eop);
 begin
  @(negedge clk);in_valid=1;in_data=b;in_sop=sop;in_eop=eop;
  while(!in_ready) @(negedge clk);
  @(posedge clk);@(negedge clk);in_valid=0;in_sop=0;in_eop=0;
 end endtask
 integer i;
 initial begin
  repeat(3) @(posedge clk);@(negedge clk);rst=0;
  // Begin a DATA frame, then simulate session abort before its payload/EOP.
  send(8'h53,1,0);send(8'h42,0,0);send(8'h01,0,0);send(8'h01,0,0);
  data_enable=0;
  repeat(6) @(posedge clk);
  send(8'haa,0,0);
  // A new CONTROL frame SOP must recover the demux without the old DATA EOP.
  send(8'h53,1,0);send(8'h42,0,0);send(8'h01,0,0);send(8'h02,0,0);
  for(i=4;i<31;i=i+1) send(i[7:0],0,(i==30));
  wait(ctrl_count==31);
  if(data_valid || frame_error) $fatal(1,"DATA abort recovery or CONTROL routing failed");

  // Also abort a CONTROL frame. A new SOP must restart demux header capture
  // so the following complete CONTROL frame reaches its decoder.
  send(8'h53,1,0);send(8'h42,0,0);send(8'h01,0,0);send(8'h02,0,0);
  send(8'h99,0,0);
  send(8'h53,1,0);send(8'h42,0,0);send(8'h01,0,0);send(8'h02,0,0);
  for(i=4;i<31;i=i+1) send(i[7:0],0,(i==30));
  wait(ctrl_count==67);
  if(data_valid || !frame_error) $fatal(1,"CONTROL abort did not resynchronize on new SOP");
  $display("PASS: RX demux recovers from aborted DATA and CONTROL frames");
  $finish;
 end
 initial begin #10000;$fatal(1,"timeout");end
endmodule
