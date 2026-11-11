// SPDX-License-Identifier: BSD-2-Clause
module tb_bonded_lane_frame_arbiter_atomic;
 reg clk=0; always #5 clk=~clk;
 reg rst=1,out_ready=1;
 reg data_valid=0,ctrl_valid=0;
 reg [7:0] data_byte=8'hD1,ctrl_byte=8'hC1;
 reg [1:0] data_index=0,ctrl_index=0;
 wire data_ready,ctrl_ready,out_valid,out_sop,out_eop,frame_idle,protocol_error;
 wire [7:0] out_data;
 integer seen=0;
 bonded_lane_frame_arbiter dut(
  .clk(clk),.rst(rst),.data_abort(1'b0),
  .ctrl_valid(ctrl_valid),.ctrl_ready(ctrl_ready),.ctrl_data(ctrl_byte),
  .ctrl_sop(ctrl_index==0),.ctrl_eop(ctrl_index==1),
  .data_valid(data_valid),.data_ready(data_ready),.data_data(data_byte),
  .data_sop(data_index==0),.data_eop(data_index==2),
  .out_valid(out_valid),.out_ready(out_ready),.out_data(out_data),
  .out_sop(out_sop),.out_eop(out_eop),.frame_idle(frame_idle),.protocol_error(protocol_error));
 always @(posedge clk) begin
  if(!rst && out_valid && out_ready) begin
   case(seen)
    0: if(out_data!=8'hD1 || !out_sop || out_eop) $fatal(1,"DATA start");
    1: if(out_data!=8'hD2 || out_sop || out_eop) $fatal(1,"DATA middle");
    2: if(out_data!=8'hD3 || out_sop || !out_eop) $fatal(1,"DATA end");
    3: if(out_data!=8'hC1 || !out_sop || out_eop) $fatal(1,"CONTROL start");
    4: if(out_data!=8'hC2 || out_sop || !out_eop) $fatal(1,"CONTROL end");
    default: $fatal(1,"extra byte");
   endcase
   seen=seen+1;
   if(data_ready) begin data_index<=data_index+1'b1; data_byte<=data_byte+1'b1; if(data_index==2)data_valid<=0; end
   if(ctrl_ready) begin ctrl_index<=ctrl_index+1'b1; ctrl_byte<=ctrl_byte+1'b1; if(ctrl_index==1)ctrl_valid<=0; end
  end
 end
 initial begin
  repeat(3) @(posedge clk);@(negedge clk);rst=0;out_ready=0;data_valid=1;
  repeat(3) @(posedge clk);
  if(!frame_idle || protocol_error || seen!=0)
   $fatal(1,"arbiter did not hold an unaccepted SOP while stalled");
  @(negedge clk);out_ready=1;
  wait(seen==1);@(negedge clk);ctrl_valid=1;
  wait(seen==5);repeat(2)@(posedge clk);
  if(protocol_error || !frame_idle) $fatal(1,"arbiter state/error");
  $display("PASS: CONTROL cannot interrupt an in-progress DATA frame");
  $finish;
 end
 initial begin #2000;$fatal(1,"timeout");end
endmodule
