// SPDX-License-Identifier: BSD-2-Clause
// HELLO/READY retransmission: frames sent before the peer's receiver is up
// are lost, and the session must still come up.
module tb_bonded_control_manager_retry;
 reg clk=0; always #5 clk=~clk;
 reg rst=1;
 reg [1:0] lane_up=2'b11;
 reg rx_valid=0,rx_lane=0;
 reg [207:0] rx_body=0;
 reg [5:0] rx_len=0;
 wire rx_ready,tx_valid,session_established,fault;
 wire [207:0] tx_body;
 wire [5:0] tx_len;
 wire [63:0] remote_bytes;
 wire [31:0] remote_packets;
 bonded_control_manager #(.LOCAL_PEER_ID(64'd1),.EXPECTED_PEER_ID(64'd2),
  .PROFILE_ID(16'd1),.MAX_PAYLOAD(16'd64),.INITIAL_SESSION_ID(64'd1),.RESTART_BACKOFF_CYCLES(32'd100000),
  .PING_INTERVAL_CYCLES(32'd1000000),.PONG_TIMEOUT_CYCLES(32'd5000000),
  .HELLO_RETRY_CYCLES(32'd200)) dut(
  .clk(clk),.rst(rst),.lane_up(lane_up),
  .ctrl_rx_valid(rx_valid),.ctrl_rx_ready(rx_ready),.ctrl_rx_body(rx_body),
  .ctrl_rx_body_length(rx_len),.ctrl_rx_lane(rx_lane),.ctrl_rx_session_id(64'd1),
  .ctrl_tx_valid(tx_valid),.ctrl_tx_ready(1'b1),.ctrl_tx_body(tx_body),.ctrl_tx_body_length(tx_len),
  .local_byte_limit(64'd100),.local_packet_limit(32'd2),
  .remote_byte_limit(remote_bytes),.remote_packet_limit(remote_packets),
  .session_established(session_established),.fault(fault));

 // Every transmitted control frame is accepted on the next edge
 // (ctrl_tx_ready=1); record the opcodes sent.
 integer hello_count=0,ready_count=0;
 always @(posedge clk) if(tx_valid) begin
  if(tx_body[207:200]==8'h01) hello_count<=hello_count+1;
  if(tx_body[207:200]==8'h02) ready_count<=ready_count+1;
 end

 task send_rx(input [207:0] b,input [5:0] len,input bit lane);
 begin
  @(negedge clk);rx_body=b;rx_len=len;rx_lane=lane;rx_valid=1;
  @(posedge clk);@(negedge clk);rx_valid=0;
 end endtask
 task wait_count(inout integer unused, input integer target, input bit is_hello, input integer limit);
 integer n;
 begin
  n=0;
  while(((is_hello ? hello_count : ready_count) < target) && n<limit) begin @(posedge clk);n=n+1;end
  if((is_hello ? hello_count : ready_count) < target)
   $fatal(1,"timeout waiting for %s #%0d",is_hello ? "HELLO" : "READY",target);
 end endtask
 reg [207:0] hello,ready;
 integer dummy=0,h,r;
 initial begin
  hello=0;hello[207:200]=8'h01;hello[199:136]=64'd2;hello[135:128]=2;
  hello[127:112]=1;hello[111:96]=64;hello[95:32]=200;hello[31:0]=4;
  ready=0;ready[207:200]=8'h02;ready[199:136]=64'd2;ready[135:128]=2;ready[127:112]=1;
  repeat(3) @(posedge clk);@(negedge clk);rst=0;

  // First HELLO is lost (peer receiver not up yet).
  wait_count(dummy,1,1,1000);
  // A READY that arrives before the peer's HELLO is ignored, not a fault.
  send_rx(ready,12,0);
  repeat(2) @(posedge clk);
  if(fault) $fatal(1,"READY before HELLO faulted the session");
  // HELLO is resent after the retry interval.
  wait_count(dummy,2,1,400);
  if(session_established) $fatal(1,"session established without peer frames");

  // Peer HELLOs arrive; our READY is sent but lost.
  send_rx(hello,26,0);send_rx(hello,26,1);
  wait_count(dummy,1,0,100);
  // Retry: HELLO then READY are resent.
  h=hello_count;r=ready_count;
  wait_count(dummy,h+1,1,400);
  wait_count(dummy,r+1,0,100);
  if(fault) $fatal(1,"unexpected fault during retries");

  // Peer READYs arrive: session up.
  send_rx(ready,12,0);send_rx(ready,12,1);
  repeat(2) @(posedge clk);
  if(!session_established || fault || remote_bytes!=200 || remote_packets!=4)
   $fatal(1,"session not established after retries");

  // No more retries once established.
  h=hello_count;r=ready_count;
  repeat(1000) @(posedge clk);
  if(hello_count!=h || ready_count!=r) $fatal(1,"HELLO/READY resent after establishment");

  // The peer missed our READY and keeps sending HELLO: answer with READY
  // only, never HELLO, and stay established.
  send_rx(hello,26,0);
  wait_count(dummy,r+1,0,100);
  repeat(1000) @(posedge clk);
  if(hello_count!=h) $fatal(1,"HELLO resent by the established side");
  if(!session_established || fault) $fatal(1,"established session disturbed by a peer HELLO");

  $display("PASS: HELLO/READY retransmission, early READY ignored, READY-only reply when established");
  $finish;
 end
 initial begin #1000000;$fatal(1,"timeout");end
endmodule
