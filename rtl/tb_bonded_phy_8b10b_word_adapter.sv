// SPDX-License-Identifier: BSD-2-Clause
`timescale 1ns/1ps
module tb_bonded_phy_8b10b_word_adapter;
 reg clk=0; always #5 clk=~clk;
 reg rst=1;

 // Four-symbol (40-bit encoded / 32-bit decoded) path.
 reg txv4=0,txsop4=0;reg [31:0] txd4=0;reg [3:0] txk4=0;
 wire txr4,txpv4;reg txpr4=1;wire [31:0] txpd4;wire [3:0] txpc4;wire txerr4;
 reg rxpv4=0;wire rxpr4;reg [31:0] rxpd4=0;reg [3:0] rxpc4=0;
 wire rxv4;reg rxr4=0;wire [31:0] rxd4;wire [3:0] rxk4;wire rxsop4;
 wire rxov4,rxerr4;

 bonded_phy_8b10b_word_adapter #(.SYMBOLS_PER_WORD(4),.RX_FIFO_DEPTH(2),
  .RX_PHY_STALLABLE(1)) dut4(
  .clk(clk),.rst(rst),
  .tx_valid(txv4),.tx_ready(txr4),.tx_data(txd4),.tx_keep(txk4),.tx_sop(txsop4),
  .tx_phy_valid(txpv4),.tx_phy_ready(txpr4),.tx_phy_data(txpd4),.tx_phy_ctrl(txpc4),.tx_error(txerr4),
  .rx_phy_valid(rxpv4),.rx_phy_ready(rxpr4),.rx_phy_data(rxpd4),.rx_phy_ctrl(rxpc4),
  .rx_valid(rxv4),.rx_ready(rxr4),.rx_data(rxd4),.rx_keep(rxk4),.rx_sop(rxsop4),
  .rx_overflow(rxov4),.rx_symbol_error(rxerr4));

 // Two-symbol (20-bit encoded / 16-bit decoded) path.
 reg txv2=0,txsop2=0;reg [15:0] txd2=0;reg [1:0] txk2=0;
 wire txr2,txpv2;reg txpr2=1;wire [15:0] txpd2;wire [1:0] txpc2;wire txerr2;
 reg rxpv2=0;wire rxpr2;reg [15:0] rxpd2=0;reg [1:0] rxpc2=0;
 wire rxv2;reg rxr2=0;wire [15:0] rxd2;wire [1:0] rxk2;wire rxsop2;
 wire rxov2,rxerr2;

 bonded_phy_8b10b_word_adapter #(.SYMBOLS_PER_WORD(2),.RX_FIFO_DEPTH(2),
  .RX_PHY_STALLABLE(0)) dut2(
  .clk(clk),.rst(rst),
  .tx_valid(txv2),.tx_ready(txr2),.tx_data(txd2),.tx_keep(txk2),.tx_sop(txsop2),
  .tx_phy_valid(txpv2),.tx_phy_ready(txpr2),.tx_phy_data(txpd2),.tx_phy_ctrl(txpc2),.tx_error(txerr2),
  .rx_phy_valid(rxpv2),.rx_phy_ready(rxpr2),.rx_phy_data(rxpd2),.rx_phy_ctrl(rxpc2),
  .rx_valid(rxv2),.rx_ready(rxr2),.rx_data(rxd2),.rx_keep(rxk2),.rx_sop(rxsop2),
  .rx_overflow(rxov2),.rx_symbol_error(rxerr2));

 task send4(input [31:0] d,input [3:0] c);
 begin
  @(negedge clk);rxpd4=d;rxpc4=c;rxpv4=1;
  while(!rxpr4) @(negedge clk);
  @(posedge clk);@(negedge clk);rxpv4=0;
 end endtask
 task send2(input [15:0] d,input [1:0] c);
 begin
  @(negedge clk);rxpd2=d;rxpc2=c;rxpv2=1;
  @(posedge clk);@(negedge clk);rxpv2=0;
 end endtask

 initial begin
  repeat(3) @(posedge clk);@(negedge clk);rst=0;

  // Four-symbol TX: idle, comma/SOP with 3 bytes, 4-byte continuation,
  // and a partial final word.
  #1;
  if(!txpv4 || !txr4 || txpd4!==32'h1c1c1cbc || txpc4!==4'b1111)
   $fatal(1,"four-symbol idle word incorrect");
  txv4=1;txsop4=1;txk4=4'b0111;txd4=32'h44332211;#1;
  if(txpd4!==32'h332211bc || txpc4!==4'b0001)
   $fatal(1,"four-symbol SOP packing incorrect");
  txsop4=0;txk4=4'b1111;txd4=32'h88776655;#1;
  if(txpd4!==32'h88776655 || txpc4!==4'b0000)
   $fatal(1,"four-symbol continuation packing incorrect");
  txk4=4'b0011;txd4=32'h0000bbaa;#1;
  if(txpd4!==32'h1c1c bbaa || txpc4!==4'b1100)
   $fatal(1,"four-symbol partial word packing incorrect");

  // PHY FIFO backpressure must hold the input word until it can be accepted.
  txpr4=0;#1;
  if(txpv4 || txr4) $fatal(1,"four-symbol TX did not backpressure");
  txpr4=1;#1;
  if(!txpv4 || !txr4) $fatal(1,"four-symbol TX did not resume");
  txv4=0;txsop4=0;txk4=0;

  // Two-symbol TX: first word has one byte, continuation has two.
  txv2=1;txsop2=1;txk2=2'b01;txd2=16'h005a;#1;
  if(txpd2!==16'h5abc || txpc2!==2'b01)
   $fatal(1,"two-symbol SOP packing incorrect");
  txsop2=0;txk2=2'b11;txd2=16'hbbaa;#1;
  if(txpd2!==16'hbbaa || txpc2!==2'b00)
   $fatal(1,"two-symbol continuation packing incorrect");
  txk2=2'b01;txd2=16'h00cc;#1;
  if(txpd2!==16'h1ccc || txpc2!==2'b10)
   $fatal(1,"two-symbol partial word packing incorrect");
  txv2=0;

  // RX: ignore idle comma, then decode SOP, continuation and partial words.
  send4(32'h1c1c1cbc,4'b1111);
  if(rxv4) $fatal(1,"idle comma word was exposed as application data");
  send4(32'h332211bc,4'b0001);
  if(!rxv4 || !rxsop4 || rxk4!==4'b0111 || rxd4!==32'h00332211)
   $fatal(1,"four-symbol RX SOP decode incorrect");
  send4(32'h77665544,4'b0000);
  @(negedge clk);rxpv4=1;rxpd4=32'h1c1c9988;rxpc4=4'b1100;#1;
  if(rxpr4) $fatal(1,"four-symbol RX FIFO did not backpressure when full");
  rxr4=1;
  @(posedge clk);@(negedge clk);rxpv4=0;
  if(!rxv4 || rxsop4 || rxk4!==4'b1111 || rxd4!==32'h77665544)
   $fatal(1,"four-symbol RX continuation decode/order incorrect");
  @(posedge clk);@(negedge clk);
  if(!rxv4 || rxsop4 || rxk4!==4'b0011 || rxd4!==32'h00009988)
   $fatal(1,"four-symbol RX partial decode incorrect");
  @(posedge clk);@(negedge clk);rxr4=0;
  if(rxv4 || rxov4 || rxerr4) $fatal(1,"unexpected four-symbol RX status");

  // Two-symbol RX: a non-stallable source overflows a full output FIFO.
  send2(16'h5abc,2'b01);
  send2(16'haabb,2'b00);
  send2(16'hccdd,2'b00);
  if(!rxov2 || !rxv2 || !rxsop2 || rxk2!==2'b01 || rxd2!==16'h005a || rxerr2)
   $fatal(1,"two-symbol RX overflow or SOP decode failed");
  rxr2=1;
  @(posedge clk);@(negedge clk);
  if(!rxv2 || rxsop2 || rxk2!==2'b11 || rxd2!==16'haabb)
   $fatal(1,"two-symbol RX continuation decode failed");

  // A data byte after an empty symbol is malformed (non-contiguous keep).
  @(negedge clk);rxpv4=1;rxpd4=32'h1cbb1caa;rxpc4=4'b1010;
  @(posedge clk);@(negedge clk);rxpv4=0;
  if(!rxerr4) $fatal(1,"non-contiguous RX word was not rejected");

  // SOP keep cannot use the comma-reserved final slot.
  txv4=1;txsop4=1;txk4=4'b1111;txd4=32'h12345678;#1;
  if(txpv4 || txr4) $fatal(1,"invalid SOP keep mask was accepted");
  @(posedge clk);@(negedge clk);
  if(!txerr4) $fatal(1,"invalid TX keep mask was not reported");

  $display("PASS: parallel 2/4-symbol PHY words, SOP comma, keep, backpressure and error detection");
  $finish;
 end
 initial begin #50000;$fatal(1,"timeout");end
endmodule
