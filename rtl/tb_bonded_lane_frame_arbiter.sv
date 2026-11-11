// SPDX-License-Identifier: BSD-2-Clause
module tb_bonded_lane_frame_arbiter;
 reg clk=0; always #5 clk=~clk;
 reg rst=1, out_ready=0;
 reg [1:0] scenario=0;
 integer ci=0,di=0,seen=0;
 wire ctrl_ready,data_ready,out_valid,out_sop,out_eop,protocol_error;
 wire [7:0] out_data;
 wire ctrl_valid=(ci<2);
 wire [7:0] ctrl_data=(ci==0)?8'hC1:8'hC2;
 wire ctrl_sop=(ci==0), ctrl_eop=(ci==1);
 wire data_valid=(di<3);
 wire [7:0] data_data=(di==0)?8'hD1:(di==1)?8'hD2:8'hD3;
 wire data_sop=(di==0), data_eop=(di==2);
 bonded_lane_frame_arbiter dut(
  .clk(clk),.rst(rst),
  .ctrl_valid(ctrl_valid),.ctrl_ready(ctrl_ready),.ctrl_data(ctrl_data),.ctrl_sop(ctrl_sop),.ctrl_eop(ctrl_eop),
  .data_valid(data_valid),.data_ready(data_ready),.data_data(data_data),.data_sop(data_sop),.data_eop(data_eop),
  .out_valid(out_valid),.out_ready(out_ready),.frame_idle(),.out_data(out_data),.out_sop(out_sop),.out_eop(out_eop),
  .protocol_error(protocol_error));
 always @(posedge clk) begin
  if(rst) begin ci<=0;di<=0;seen<=0; end
  else begin
   if(ctrl_valid && ctrl_ready) ci<=ci+1;
   if(data_valid && data_ready) di<=di+1;
   if(out_valid && out_ready) begin
    case(seen)
     0: if(out_data!==8'hC1 || !out_sop || out_eop) $fatal(1,"expected CONTROL byte 0");
     1: if(out_data!==8'hC2 || out_sop || !out_eop) $fatal(1,"expected CONTROL byte 1");
     2: if(out_data!==8'hD1 || !out_sop || out_eop) $fatal(1,"expected DATA byte 0");
     3: if(out_data!==8'hD2 || out_sop || out_eop) $fatal(1,"expected DATA byte 1");
     4: if(out_data!==8'hD3 || out_sop || !out_eop) $fatal(1,"expected DATA byte 2");
     default: $fatal(1,"unexpected output");
    endcase
    seen<=seen+1;
   end
  end
 end
 initial begin
  repeat(3) @(posedge clk); @(negedge clk); rst=0;
  repeat(4) @(posedge clk);
  if(seen!=0 || ci!=0 || di!=0) $fatal(1,"arbiter did not hold output under backpressure");
  @(negedge clk); out_ready=1;
  wait(seen==5);
  repeat(2) @(posedge clk);
  if(ci!=2 || di!=3 || protocol_error) $fatal(1,"handshake or protocol error");
  $display("PASS: CONTROL priority at frame boundary, DATA follows, stable under backpressure");
  $finish;
 end
endmodule
