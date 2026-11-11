// SPDX-License-Identifier: BSD-2-Clause
module tb_bonded_control_manager;
 reg clk=0; always #5 clk=~clk;
 reg rst=1;
 reg [1:0] lane_up=2'b11;
 reg rx_valid=0,rx_lane=0;
 reg [207:0] rx_body=0;
 reg [5:0] rx_len=0;
 reg [63:0] local_bytes=64'd100;
 reg [31:0] local_packets=32'd2;
 wire rx_ready,tx_valid,session_established,fault;
 wire [207:0] tx_body;
 wire [5:0] tx_len;
 wire [63:0] remote_bytes;
 wire [31:0] remote_packets;
 bonded_control_manager #(.LOCAL_PEER_ID(64'd1),.EXPECTED_PEER_ID(64'd2),
  .PROFILE_ID(16'd1),.MAX_PAYLOAD(16'd64),
  .PING_INTERVAL_CYCLES(32'd1000),.PONG_TIMEOUT_CYCLES(32'd5000)) dut(
  .clk(clk),.rst(rst),.lane_up(lane_up),
  .ctrl_rx_valid(rx_valid),.ctrl_rx_ready(rx_ready),.ctrl_rx_body(rx_body),
  .ctrl_rx_body_length(rx_len),.ctrl_rx_lane(rx_lane),
  .ctrl_tx_valid(tx_valid),.ctrl_tx_ready(1'b1),.ctrl_tx_body(tx_body),.ctrl_tx_body_length(tx_len),
  .local_byte_limit(local_bytes),.local_packet_limit(local_packets),
  .remote_byte_limit(remote_bytes),.remote_packet_limit(remote_packets),
  .session_established(session_established),.fault(fault));
 task send_rx(input [207:0] b,input [5:0] len,input bit lane);
 begin
  @(negedge clk);rx_body=b;rx_len=len;rx_lane=lane;rx_valid=1;
  @(posedge clk);@(negedge clk);rx_valid=0;
 end endtask
 task wait_tx(input [7:0] opcode);
 integer n;
 begin
  n=0;while((!tx_valid || tx_body[207:200]!=opcode) && n<10000) begin @(posedge clk);n=n+1;end
  if(!tx_valid || tx_body[207:200]!=opcode) $fatal(1,"timeout waiting TX opcode %h",opcode);
 end endtask
 task accept_tx;
 begin @(posedge clk);@(negedge clk);end
 endtask
 reg [207:0] msg;
 reg [31:0] nonce;
 initial begin
  repeat(3) @(posedge clk);@(negedge clk);rst=0;
  wait_tx(8'h01);
  if(tx_len!=26 || tx_body[199:136]!=64'd1 || tx_body[95:32]!=100 || tx_body[31:0]!=2)
    $fatal(1,"HELLO contents incorrect");
  accept_tx();
  msg=0;msg[207:200]=8'h01;msg[199:136]=64'd2;msg[135:128]=2;
  msg[127:112]=1;msg[111:96]=64;msg[95:32]=200;msg[31:0]=4;
  send_rx(msg,26,0);send_rx(msg,26,1);
  wait_tx(8'h02);
  if(tx_len!=12 || tx_body[199:136]!=64'd1 || tx_body[135:128]!=2 || tx_body[127:112]!=1)
    $fatal(1,"READY contents incorrect");
  accept_tx();
  msg=0;msg[207:200]=8'h02;msg[199:136]=64'd2;msg[135:128]=2;msg[127:112]=1;
  send_rx(msg,12,0);send_rx(msg,12,1);
  repeat(2) @(posedge clk);
  if(!session_established || fault || remote_bytes!=200 || remote_packets!=4)
    $fatal(1,"HELLO/READY session or initial credit negotiation failed");

  msg=0;msg[207:200]=8'h03;msg[199:136]=64'd300;msg[135:104]=32'd5;
  send_rx(msg,13,0);
  if(remote_bytes!=300 || remote_packets!=5) $fatal(1,"CREDIT update failed");
  msg[199:136]=64'd250;msg[135:104]=32'd3;
  send_rx(msg,13,1);
  if(remote_bytes!=300 || remote_packets!=5) $fatal(1,"stale CREDIT rolled back limits");

  local_bytes=150;local_packets=3;
  wait_tx(8'h03);
  if(tx_len!=13 || tx_body[199:136]!=150 || tx_body[135:104]!=3)
    $fatal(1,"local cumulative CREDIT generation failed");
  accept_tx();

  wait_tx(8'h04);
  nonce=tx_body[199:168];
  if(tx_len!=5) $fatal(1,"PING length incorrect");
  accept_tx();
  msg=0;msg[207:200]=8'h05;msg[199:168]=nonce;
  send_rx(msg,5,0);
  repeat(2) @(posedge clk);
  if(fault) $fatal(1,"matching PONG incorrectly faulted");

  msg=0;msg[207:200]=8'h04;msg[199:168]=32'h12345678;
  send_rx(msg,5,1);
  wait_tx(8'h05);
  if(tx_len!=5 || tx_body[199:168]!=32'h12345678)
    $fatal(1,"PONG response incorrect");
  accept_tx();
  if(fault || !session_established) $fatal(1,"unexpected manager fault");

  // Let the next periodic PING go unanswered and verify timeout supervision.
  wait_tx(8'h04);
  accept_tx();
  repeat(5005) @(posedge clk);
  if(!fault || session_established)
    $fatal(1,"missing PONG did not invalidate the session");
  $display("PASS: RTL HELLO/READY, cumulative CREDIT, PING/PONG and timeout fault");
  $finish;
 end
 initial begin #200000;$fatal(1,"timeout");end
endmodule
