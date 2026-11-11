// SPDX-License-Identifier: BSD-2-Clause
module tb_bonded_wire_rx_framer;
 reg clk=0; always #5 clk=~clk;
 reg rst=1,noise_mode=1,noise_valid=0,ctrl_valid=0;
 reg [7:0] noise_data=0;
 reg [207:0] body=0;
 wire ctrl_ready,tx_valid,tx_ready,tx_sop,tx_eop;
 wire [7:0] tx_data;
 wire [31:0] tx_seq;
 wire tx_error;
 wire raw_valid,raw_ready,raw_sop,raw_eop;
 wire [7:0] raw_data;
 wire out_valid,out_sop,out_eop,frame_error;
 wire [7:0] out_data;
 integer got=0;
 reg [7:0] captured[0:40];
 bonded_control_frame_tx #(.LANE_ID(0)) tx(
  .clk(clk),.rst(rst),.session_id(64'h0123456789abcdef),
  .frame_start_enable(1'b1),.frame_sequence_override(32'd0),
  .ctrl_valid(ctrl_valid),.ctrl_ready(ctrl_ready),.ctrl_body(body),.ctrl_body_length(6'd13),
  .out_valid(tx_valid),.out_ready(tx_ready),.out_data(tx_data),.out_sop(tx_sop),.out_eop(tx_eop),
  .next_frame_sequence(tx_seq),.frame_error(tx_error));
 assign raw_valid=noise_mode ? noise_valid : tx_valid;
 assign raw_data=noise_mode ? noise_data : tx_data;
 assign tx_ready=!noise_mode && raw_ready;
 assign raw_sop=1'b0;
 assign raw_eop=1'b0;
 bonded_wire_rx_framer #(.MAX_FRAME_BODY(64)) dut(
  .clk(clk),.rst(rst),.in_valid(raw_valid),.in_ready(raw_ready),.in_data(raw_data),
  .out_valid(out_valid),.out_ready(1'b1),.out_data(out_data),.out_sop(out_sop),
  .out_eop(out_eop),.frame_error(frame_error));
 always @(posedge clk) if(out_valid) begin
  if(got>=41) $fatal(1,"extra framed byte");
  captured[got]=out_data;
  if(out_sop !== (got==0)) $fatal(1,"SOP mismatch at %0d",got);
  if(out_eop !== (got==40)) $fatal(1,"EOP mismatch at %0d",got);
  got=got+1;
 end
 task send_noise(input [7:0] b);
 begin
  @(negedge clk);noise_data=b;noise_valid=1;
  while(!raw_ready) @(negedge clk);
  @(posedge clk);@(negedge clk);noise_valid=0;
 end endtask
 initial begin
  body=0;body[207:200]=8'h03;body[199:136]=64'h1000;body[135:104]=32'h20;
  repeat(3) @(posedge clk);@(negedge clk);rst=0;
  // False CONTROL prefix in the raw stream; the valid frame starts before
  // the candidate 24-byte header is complete and must be recovered by rescan.
  send_noise(8'h53);send_noise(8'h42);send_noise(8'h01);send_noise(8'h02);
  @(negedge clk);noise_mode=0;ctrl_valid=1;
  wait(ctrl_ready);@(posedge clk);@(negedge clk);ctrl_valid=0;
  wait(got==41);
  if(captured[0]!=8'h53 || captured[1]!=8'h42 || captured[2]!=8'h01 ||
     captured[3]!=8'h02 || captured[5]!=0 || captured[7]!=8'h18 ||
     captured[24]!=8'h03 || captured[32]!=8'h10 || captured[40]===8'hxx ||
     tx_error || !frame_error || tx_seq!=1)
    $fatal(1,"framer resynchronization or header/body output mismatch");
  $display("PASS: raw byte stream frame recovery, CRC-protected header length, SOP/EOP reconstruction");
  $finish;
 end
 initial begin #20000;$fatal(1,"timeout got=%0d",got);end
endmodule
