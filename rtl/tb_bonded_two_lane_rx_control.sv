// SPDX-License-Identifier: BSD-2-Clause
module tb_bonded_two_lane_rx_control;
 reg lane0_clk=0,lane1_clk=0,bond_clk=0;
 always #5 lane0_clk=~lane0_clk;
 always #7 lane1_clk=~lane1_clk;
 always #4 bond_clk=~bond_clk;
 reg rst_n=0,tx_valid=0;
 reg [207:0] body=0;
 wire tx_ready,tx_out_valid,tx_out_ready,tx_sop,tx_eop;
 wire [7:0] tx_data;
 wire [31:0] tx_seq;
 wire tx_error;
 wire lane0_ready,lane1_ready;
 wire ctrl_rx_valid,ctrl_rx_lane,credit_error,packet_error;
 wire [207:0] ctrl_rx_body;
 wire [5:0] ctrl_rx_length;
 wire [63:0] local_bytes;
 wire [31:0] local_packets;
 wire rx_valid,lane0_error,lane1_error;
 wire [7:0] rx_data;
 wire rx_sop,rx_eop;
 wire [31:0] rx_seq;
 bonded_control_frame_tx #(.LANE_ID(0)) tx(
  .clk(lane0_clk),.rst(!rst_n),.session_id(64'h0123456789abcdef),
  .frame_start_enable(1'b1),.frame_sequence_override(32'd0),
  .ctrl_valid(tx_valid),.ctrl_ready(tx_ready),.ctrl_body(body),.ctrl_body_length(6'd13),
  .out_valid(tx_out_valid),.out_ready(tx_out_ready),.out_data(tx_data),
  .out_sop(tx_sop),.out_eop(tx_eop),.next_frame_sequence(tx_seq),.frame_error(tx_error));
 assign tx_out_ready=lane0_ready;
 bonded_two_lane_rx #(.FIFO_DEPTH(16),.REORDER_WINDOW(4),.MAX_PACKET_BYTES(64)) dut(
  .bond_rst_n(rst_n),.control_rst_n(rst_n),.expected_session_id(64'h0123456789abcdef),.session_rx_reset_toggle(1'b0),.session_rx_flush_toggle(1'b0),
  .lane0_clk(lane0_clk),.lane0_rst_n(rst_n),.lane0_valid(tx_out_valid),.lane0_ready(lane0_ready),
  .lane0_data(tx_data),.lane0_sop(tx_sop),.lane0_eop(tx_eop),
  .lane1_clk(lane1_clk),.lane1_rst_n(rst_n),.lane1_valid(1'b0),.lane1_ready(lane1_ready),
  .lane1_data(8'd0),.lane1_sop(1'b0),.lane1_eop(1'b0),
  .bond_clk(bond_clk),.ctrl_rx_valid(ctrl_rx_valid),.ctrl_rx_ready(1'b1),
  .ctrl_rx_body(ctrl_rx_body),.ctrl_rx_body_length(ctrl_rx_length),.ctrl_rx_session_id(),.ctrl_rx_lane(ctrl_rx_lane),
  .local_byte_limit(local_bytes),.local_packet_limit(local_packets),.credit_error(credit_error),
  .out_valid(rx_valid),.out_ready(1'b1),.out_data(rx_data),.out_sop(rx_sop),.out_eop(rx_eop),
  .out_packet_sequence(rx_seq),.lane0_frame_error(lane0_error),.lane1_frame_error(lane1_error),
  .packet_error(packet_error));
 initial begin
  body=0;body[207:200]=8'h03;
  body[199:136]=64'h0000000000001000;
  body[135:104]=32'h00000020;
  repeat(4) @(posedge bond_clk);@(negedge bond_clk);rst_n=1;
  @(negedge lane0_clk);tx_valid=1;
  wait(tx_ready);@(posedge lane0_clk);@(negedge lane0_clk);tx_valid=0;
  wait(ctrl_rx_valid);
  if(ctrl_rx_body!==body || ctrl_rx_length!=13 || ctrl_rx_lane!=0 ||
     tx_error || lane0_error || lane1_error || credit_error || packet_error)
    $fatal(1,"integrated CONTROL RX mismatch length=%0d lane=%0d",ctrl_rx_length,ctrl_rx_lane);
  $display("PASS: two-lane RX demux, CONTROL CRC decode and asynchronous message delivery");
  $finish;
 end
 initial begin #20000;$fatal(1,"timeout");end
endmodule
