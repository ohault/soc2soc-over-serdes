// SPDX-License-Identifier: BSD-2-Clause
module tb_bonded_control_frame_loopback;
 reg clk=0; always #5 clk=~clk;
 reg rst=1,ctrl_valid=0,ctrl_ready=1;
 reg [207:0] body=0;
 reg [5:0] body_len=13;
 wire tx_ready,stream_valid,stream_ready,stream_sop,stream_eop;
 wire [7:0] stream_data;
 wire [31:0] tx_next,rx_seq,rx_next;
 wire tx_error,rx_error,rx_valid;
 wire [207:0] rx_body;
 wire [5:0] rx_length;
 bonded_control_frame_tx #(.LANE_ID(1)) tx(
  .clk(clk),.rst(rst),.session_id(64'h0123456789abcdef),
  .frame_start_enable(1'b1),.frame_sequence_override(32'd0),
  .ctrl_valid(ctrl_valid),.ctrl_ready(tx_ready),.ctrl_body(body),.ctrl_body_length(body_len),
  .out_valid(stream_valid),.out_ready(stream_ready),.out_data(stream_data),
  .out_sop(stream_sop),.out_eop(stream_eop),.next_frame_sequence(tx_next),.frame_error(tx_error));
 bonded_control_frame_rx #(.LANE_ID(1)) rx(
  .clk(clk),.rst(rst),.expected_session_id(64'h0123456789abcdef),.expected_frame_sequence_override(32'd0),
  .in_valid(stream_valid),.in_ready(stream_ready),.in_data(stream_data),
  .in_sop(stream_sop),.in_eop(stream_eop),
  .ctrl_valid(rx_valid),.ctrl_ready(ctrl_ready),.ctrl_body(rx_body),
  .ctrl_body_length(rx_length),.received_frame_sequence(rx_seq),
  .expected_frame_sequence(rx_next),.frame_error(rx_error));
 initial begin
  body=0;body[207:200]=8'h03;
  body[199:136]=64'h0000000000001000;
  body[135:104]=32'h00000020;
  repeat(3) @(posedge clk); @(negedge clk);rst=0;ctrl_valid=1;
  wait(tx_ready); @(posedge clk); @(negedge clk);ctrl_valid=0;
  wait(rx_valid);
  if(rx_body!==body || rx_length!=13 || rx_seq!=0 || rx_next!=1 || tx_error || rx_error)
    $fatal(1,"CONTROL loopback mismatch length=%0d seq=%0d error=%b",rx_length,rx_seq,rx_error);
  @(posedge clk);
  $display("PASS: CONTROL encoder/decoder interoperability, CRC, session, sequence and CREDIT fields");
  $finish;
 end
 initial begin #10000;$fatal(1,"timeout");end
endmodule
