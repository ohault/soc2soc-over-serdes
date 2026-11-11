// SPDX-License-Identifier: BSD-2-Clause
`timescale 1ns/1ps
module tb_bonded_phy_8b10b_adapter;
 reg clk=0; always #5 clk=~clk;
 reg rst=1;

 reg txv2=0;reg [7:0] txd2=0;wire txr2,txpv2;reg txpr2=1;
 wire [15:0] txpd2;wire [1:0] txpc2;
 reg rxpv2=0;wire rxpr2;reg [15:0] rxpd2=0;reg [1:0] rxpc2=0;
 wire rxv2;reg rxr2=0;wire [7:0] rxd2;wire ov2,err2;

 bonded_phy_8b10b_adapter #(.SYMBOLS_PER_WORD(2),.RX_FIFO_DEPTH(2),
  .RX_PHY_STALLABLE(1)) dut2(
  .clk(clk),.rst(rst),
  .tx_byte_valid(txv2),.tx_byte_ready(txr2),.tx_byte_data(txd2),
  .tx_phy_valid(txpv2),.tx_phy_ready(txpr2),.tx_phy_data(txpd2),.tx_phy_ctrl(txpc2),
  .rx_phy_valid(rxpv2),.rx_phy_ready(rxpr2),.rx_phy_data(rxpd2),.rx_phy_ctrl(rxpc2),
  .rx_byte_valid(rxv2),.rx_byte_ready(rxr2),.rx_byte_data(rxd2),
  .rx_overflow(ov2),.rx_symbol_error(err2));

 reg txv4=0;reg [7:0] txd4=0;wire txr4,txpv4;reg txpr4=1;
 wire [31:0] txpd4;wire [3:0] txpc4;
 reg rxpv4=0;wire rxpr4;reg [31:0] rxpd4=0;reg [3:0] rxpc4=0;
 wire rxv4;reg rxr4=0;wire [7:0] rxd4;wire ov4,err4;

 bonded_phy_8b10b_adapter #(.SYMBOLS_PER_WORD(4),.RX_FIFO_DEPTH(2),
  .RX_PHY_STALLABLE(0)) dut4(
  .clk(clk),.rst(rst),
  .tx_byte_valid(txv4),.tx_byte_ready(txr4),.tx_byte_data(txd4),
  .tx_phy_valid(txpv4),.tx_phy_ready(txpr4),.tx_phy_data(txpd4),.tx_phy_ctrl(txpc4),
  .rx_phy_valid(rxpv4),.rx_phy_ready(rxpr4),.rx_phy_data(rxpd4),.rx_phy_ctrl(rxpc4),
  .rx_byte_valid(rxv4),.rx_byte_ready(rxr4),.rx_byte_data(rxd4),
  .rx_overflow(ov4),.rx_symbol_error(err4));

 task send2(input [7:0] b);
 begin
  @(negedge clk);rxpd2={b,8'hbc};rxpc2=2'b01;rxpv2=1;
  while(!rxpr2) @(negedge clk);
  @(posedge clk);@(negedge clk);rxpv2=0;
 end endtask
 task send4(input [7:0] b);
 begin
  @(negedge clk);rxpd4={8'h00,8'h00,b,8'hbc};rxpc4=4'b0001;rxpv4=1;
  @(posedge clk);@(negedge clk);rxpv4=0;
 end endtask

 initial begin
  repeat(3) @(posedge clk);@(negedge clk);rst=0;

  // TX inserts K28.5 into every unused symbol position.
  txv2=1;txd2=8'ha5;#1;
  if(!txpv2 || !txr2 || txpd2!==16'ha5bc || txpc2!==2'b01)
   $fatal(1,"two-symbol TX packing failed");
  txv2=0;#1;
  if(txpd2!==16'h1cbc || txpc2!==2'b11)
   $fatal(1,"two-symbol TX idle insertion failed");
  txpr2=0;txv2=1;txd2=8'h33;#1;
  if(txpv2 || txr2) $fatal(1,"TX valid/ready did not stall with full PHY FIFO");
  txpr2=1;#1;
  if(!txpv2 || !txr2 || txpd2!==16'h33bc)
   $fatal(1,"TX did not resume with held application byte");
  txv2=0;

  txv4=1;txd4=8'h5a;#1;
  if(!txpv4 || !txr4 || txpd4!==32'h00005abc || txpc4!==4'b0001)
   $fatal(1,"four-symbol TX packing failed");
  txv4=0;

  // Stallable RX FIFO: fill, apply backpressure, then push/pop together.
  send2(8'h11);send2(8'h22);
  @(negedge clk);rxpv2=1;rxpd2={8'h33,8'hbc};rxpc2=2'b01;#1;
  if(rxpr2) $fatal(1,"stallable RX did not backpressure when full");
  rxr2=1;
  @(posedge clk);@(negedge clk);rxpv2=0;
  if(!rxv2 || rxd2!==8'h22) $fatal(1,"RX FIFO simultaneous pop/push ordering failed");
  @(posedge clk);@(negedge clk);
  if(!rxv2 || rxd2!==8'h33) $fatal(1,"RX FIFO final byte ordering failed");
  @(posedge clk);@(negedge clk);rxr2=0;
  if(rxv2 || ov2 || err2) $fatal(1,"unexpected two-symbol RX status");

  // Non-stallable PHY source: data arriving while full is reported as overflow.
  send4(8'h41);send4(8'h42);send4(8'h43);
  if(!ov4 || !rxv4 || rxd4!==8'h41 || err4)
   $fatal(1,"non-stallable RX overflow reporting failed");
  rxr4=1;
  @(posedge clk);@(negedge clk);
  if(!rxv4 || rxd4!==8'h42) $fatal(1,"four-symbol RX FIFO ordering failed");

  // A non-idle control character or data in an unused symbol slot is invalid.
  @(negedge clk);rxpv2=1;rxpd2={8'h22,8'h11};rxpc2=2'b00;
  @(posedge clk);@(negedge clk);rxpv2=0;
  if(!err2) $fatal(1,"malformed 8b10b symbol word was not reported");

  $display("PASS: 2/4-symbol 8b10b packing, K28.5 idles, RX backpressure and overflow");
  $finish;
 end
 initial begin #50000;$fatal(1,"timeout");end
endmodule
