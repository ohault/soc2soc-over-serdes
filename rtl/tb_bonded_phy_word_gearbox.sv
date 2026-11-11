// SPDX-License-Identifier: BSD-2-Clause
`timescale 1ns/1ps
module tb_bonded_phy_word_gearbox;
 reg clk=0; always #5 clk=~clk;
 reg rst=1;

 reg in_valid=0,in_sop=0,in_eop=0;
 reg [7:0] in_data=0;
 wire in_ready;
 wire packed_valid,packed_ready,packed_sop;
 wire [31:0] packed_data;
 wire [3:0] packed_keep;
 wire tx_phy_valid,tx_phy_ready;
 wire [31:0] tx_phy_data;
 wire [3:0] tx_phy_ctrl;
 wire tx_error;
 wire rx_phy_valid,rx_phy_ready;
 wire [31:0] rx_phy_data;
 wire [3:0] rx_phy_ctrl;
 wire rx_word_valid,rx_word_ready,rx_word_sop;
 wire [31:0] rx_word_data;
 wire [3:0] rx_word_keep;
 wire rx_overflow,rx_symbol_error;
 wire out_valid,out_sop,out_error;
 wire [7:0] out_data;
 reg [7:0] expected[0:12];
 integer received=0;
 integer cycles=0;

 bonded_byte_to_phy_word #(.SYMBOLS_PER_WORD(4)) packer(
  .clk(clk),.rst(rst),.byte_valid(in_valid),.byte_ready(in_ready),
  .byte_data(in_data),.byte_sop(in_sop),.byte_eop(in_eop),
  .word_valid(packed_valid),.word_ready(packed_ready),
  .word_data(packed_data),.word_keep(packed_keep),.word_sop(packed_sop),
  .packet_error(out_error));

 bonded_phy_8b10b_word_adapter #(.SYMBOLS_PER_WORD(4),.RX_FIFO_DEPTH(4),
  .RX_PHY_STALLABLE(1)) phy(
  .tx_clk(clk),.tx_rst(rst),.rx_clk(clk),.rx_rst(rst),
  .tx_valid(packed_valid),.tx_ready(packed_ready),.tx_data(packed_data),
  .tx_keep(packed_keep),.tx_sop(packed_sop),
  .tx_phy_valid(tx_phy_valid),.tx_phy_ready(tx_phy_ready),
  .tx_phy_data(tx_phy_data),.tx_phy_ctrl(tx_phy_ctrl),.tx_error(tx_error),
  .rx_phy_valid(rx_phy_valid),.rx_phy_ready(rx_phy_ready),
  .rx_phy_data(rx_phy_data),.rx_phy_ctrl(rx_phy_ctrl),
  .rx_valid(rx_word_valid),.rx_ready(rx_word_ready),
  .rx_data(rx_word_data),.rx_keep(rx_word_keep),.rx_sop(rx_word_sop),
  .rx_overflow(rx_overflow),.rx_symbol_error(rx_symbol_error));

 assign tx_phy_ready=rx_phy_ready;
 assign rx_phy_valid=tx_phy_valid;
 assign rx_phy_data=tx_phy_data;
 assign rx_phy_ctrl=tx_phy_ctrl;

 bonded_phy_word_to_byte #(.SYMBOLS_PER_WORD(4)) unpacker(
  .clk(clk),.rst(rst),
  .word_valid(rx_word_valid),.word_ready(rx_word_ready),
  .word_data(rx_word_data),.word_keep(rx_word_keep),.word_sop(rx_word_sop),
  .byte_valid(out_valid),.byte_ready(out_ready),.byte_data(out_data),
  .byte_sop(out_sop),.word_error());

 reg out_ready=0;
 always @(posedge clk) begin
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
  repeat(4) @(posedge clk);
  if(out_error || tx_error || rx_overflow || rx_symbol_error || !in_ready)
   $fatal(1,"unexpected error/overflow in integrated gearbox loopback");
  $display("PASS: byte/word packing, PHY comma removal, control-valued payload bytes and backpressure");
  $finish;
 end
 initial begin #100000;$fatal(1,"timeout");end
endmodule
