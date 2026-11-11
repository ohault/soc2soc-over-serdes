// SPDX-License-Identifier: BSD-2-Clause
module tb_bonded_lane_tx_mux;
 reg clk=0; always #5 clk=~clk;
 reg rst=1, ctrl_valid=0, data_valid=0, out_ready=1;
 reg [207:0] ctrl_body=0;
 reg [5:0] ctrl_len=13;
 reg [31:0] data=32'h00ccbbaa;
 reg [3:0] keep=4'h7;
 wire ctrl_ready,data_ready,out_valid,out_sop,out_eop;
 wire [7:0] out_data;
 wire [31:0] data_seq,ctrl_seq;
 wire data_err,ctrl_err,arb_err;
 integer got=0, cycles=0;
 reg [7:0] captured[0:75];
 bonded_lane_tx_mux #(.DATA_WIDTH(32),.LANE_ID(0)) dut(
  .clk(clk),.rst(rst),.data_rst(1'b0),.session_id(64'h1122334455667788),
  .ctrl_valid(ctrl_valid),.ctrl_ready(ctrl_ready),.ctrl_body(ctrl_body),.ctrl_body_length(ctrl_len),
  .data_valid(data_valid),.data_ready(data_ready),.data_data(data),.data_keep(keep),
  .data_sop(1'b1),.data_eop(1'b1),.data_packet_sequence(32'h1234),.data_packet_length(16'd3),
  .out_valid(out_valid),.out_ready(out_ready),.out_data(out_data),.out_sop(out_sop),.out_eop(out_eop),
  .data_frame_sequence(data_seq),.control_frame_sequence(ctrl_seq),
  .data_frame_error(data_err),.control_frame_error(ctrl_err),.arbiter_protocol_error(arb_err));
 always @(posedge clk) begin
  if(!rst && out_valid && out_ready) begin
   if(got>=76) $fatal(1,"too many bytes");
   captured[got]=out_data;
   got=got+1;
  end
 end
 initial begin
  ctrl_body=0; ctrl_body[207:200]=8'h03;
  ctrl_body[199:136]=64'h1000; ctrl_body[135:104]=32'd32;
  repeat(3) @(posedge clk); @(negedge clk); rst=0; ctrl_valid=1; data_valid=1;
  #1; // Allow frame-start gating to settle before observing READY.
  fork
   begin wait(ctrl_ready); @(posedge clk); @(negedge clk); ctrl_valid=0; end
   begin wait(data_ready); @(posedge clk); @(negedge clk); data_valid=0; end
  join
  wait(got==76);
  repeat(2) @(posedge clk);
  if(captured[3]!=8'h02 || captured[16]!=0 || captured[19]!=0)
    $fatal(1,"CONTROL frame did not win sequence zero");
  if(captured[41+3]!=8'h01 || captured[41+16]!=0 || captured[41+19]!=1)
    $fatal(1,"DATA frame did not follow with sequence one");
  if(data_seq!=2 || ctrl_seq!=2 || data_err || ctrl_err || arb_err)
    $fatal(1,"sequence/error status");
  $display("PASS: composed lane TX, CONTROL priority and shared frame sequence");
  $finish;
 end
 initial begin
  #20000; $fatal(1,"timeout got=%0d",got);
 end
endmodule
