// SPDX-License-Identifier: BSD-2-Clause
`timescale 1ns/1ps
module tb_bonded_phy_word_gearbox;
 reg clk=0,rx_clk=0;
 always #5 clk=~clk;
 always #7 rx_clk=~rx_clk;
 reg rst=1;

 reg in_valid=0,in_sop=0,in_eop=0;
 reg [7:0] in_data=0;
 wire in_ready;
 wire tx_phy_valid,tx_phy_ready;
 wire [31:0] tx_phy_data;
 wire [3:0] tx_phy_ctrl;
 wire tx_error;
 wire rx_phy_valid,rx_phy_ready;
 wire [31:0] rx_phy_data;
 wire [3:0] rx_phy_ctrl;
 wire rx_byte_valid,rx_byte_sop,rx_fault;
 wire out_valid,out_sop;
 wire [7:0] out_data;
 reg [7:0] expected[0:12];
 integer received=0;
 integer cycles=0;

 bonded_phy_8b10b_lane_adapter #(.SYMBOLS_PER_WORD(4),.RX_FIFO_DEPTH(4),
  .RX_PHY_STALLABLE(1)) lane_adapter(
  .tx_clk(clk),.tx_rst(rst),
  .tx_byte_valid(in_valid),.tx_byte_ready(in_ready),.tx_byte_data(in_data),
  .tx_byte_sop(in_sop),.tx_byte_eop(in_eop),
  .tx_phy_valid(tx_phy_valid),.tx_phy_ready(tx_phy_ready),
  .tx_phy_data(tx_phy_data),.tx_phy_ctrl(tx_phy_ctrl),.tx_error(tx_error),
  .rx_clk(rx_clk),.rx_rst(rst),
  .rx_phy_valid(rx_phy_valid),.rx_phy_ready(rx_phy_ready),
  .rx_phy_data(rx_phy_data),.rx_phy_ctrl(rx_phy_ctrl),
  .rx_byte_valid(rx_byte_valid),.rx_byte_ready(out_ready),
  .rx_byte_data(out_data),.rx_byte_sop(rx_byte_sop),.rx_fault(rx_fault));

 assign out_valid=rx_byte_valid;
 assign out_sop=rx_byte_sop;

 // A dual-clock FIFO models the independent recovered RX clock domain
 // of a real SERDES. No TX READY signal is combinationally tied to RX READY.
 bonded_async_fifo #(.DATA_WIDTH(36),.DEPTH(8)) serdes_loopback(
  .wr_clk(clk),.wr_rst_n(!rst),.wr_valid(tx_phy_valid),.wr_ready(tx_phy_ready),
  .wr_data({tx_phy_ctrl,tx_phy_data}),
  .rd_clk(rx_clk),.rd_rst_n(!rst),.rd_valid(rx_phy_valid),.rd_ready(rx_phy_ready),
  .rd_data({rx_phy_ctrl,rx_phy_data}));


 reg out_ready=0;
 always @(posedge rx_clk) begin
  if(rst) begin received<=0;cycles<=0;end
  else begin
   cycles<=cycles+1;
   // Deterministic downstream stalls exercise both RX FIFO and gearbox.
   out_ready<=((cycles%7)!=2 && (cycles%7)!=3);
   if(out_valid && out_ready) begin
    if(received>=13 || out_data!==expected[received])
     $fatal(1,"byte stream mismatch at %0d: got %02x",received,out_data);
    if(out_sop !== (received==0))
     $fatal(1,"SOP mismatch at byte %0d",received);
    received<=received+1;
   end
  end
 end

 task send_byte(input [7:0] d,input s,input e);
 begin
  @(negedge clk);in_data=d;in_sop=s;in_eop=e;in_valid=1;
  while(!in_ready) @(negedge clk);
  @(posedge clk);
  @(negedge clk);in_valid=0;in_sop=0;in_eop=0;
 end endtask

 initial begin
  expected[0]=8'h53; expected[1]=8'h42; expected[2]=8'hbc;
  expected[3]=8'h1c; expected[4]=8'h00; expected[5]=8'hff;
  expected[6]=8'h10; expected[7]=8'h20; expected[8]=8'h30;
  expected[9]=8'h40; expected[10]=8'h50; expected[11]=8'h60;
  expected[12]=8'h7e;
  repeat(4) @(posedge clk); @(negedge clk); rst=0;

  send_byte(expected[0],1,0);
  send_byte(expected[1],0,0);
  send_byte(expected[2],0,0);
  send_byte(expected[3],0,0);
  send_byte(expected[4],0,0);
  send_byte(expected[5],0,0);
  send_byte(expected[6],0,0);
  send_byte(expected[7],0,0);
  send_byte(expected[8],0,0);
  send_byte(expected[9],0,0);
  send_byte(expected[10],0,0);
  send_byte(expected[11],0,0);
  send_byte(expected[12],0,1);

  wait(received==13);
  repeat(4) @(posedge rx_clk);
  if(tx_error || rx_fault || !in_ready)
   $fatal(1,"unexpected error/overflow in integrated gearbox loopback");
  $display("PASS: byte/word packing, PHY comma removal, control-valued payload bytes and backpressure");
  $finish;
 end
 initial begin #100000;$fatal(1,"timeout");end
endmodule
