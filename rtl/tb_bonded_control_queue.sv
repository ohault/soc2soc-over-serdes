// SPDX-License-Identifier: BSD-2-Clause
module tb_bonded_control_queue;
 reg clk=0; always #5 clk=~clk;
 reg rst=1,in_valid=0,out_ready=0;
 reg [207:0] in_body=0;
 reg [5:0] in_length=13;
 wire in_ready,out_valid,full,empty;
 wire [207:0] out_body;
 wire [5:0] out_length;
 integer i;
 bonded_control_queue #(.DEPTH(4)) dut(
  .clk(clk),.rst(rst),.in_valid(in_valid),.in_ready(in_ready),
  .in_body(in_body),.in_length(in_length),.out_valid(out_valid),.out_ready(out_ready),
  .out_body(out_body),.out_length(out_length),.full(full),.empty(empty));
 task push(input [7:0] opcode);
 begin
  @(negedge clk);in_body=0;in_body[207:200]=opcode;in_valid=1;
  while(!in_ready) @(negedge clk);
  @(posedge clk);@(negedge clk);in_valid=0;
 end endtask
 initial begin
  repeat(2) @(posedge clk);@(negedge clk);rst=0;
  for(i=1;i<=4;i=i+1) push(i);
  if(!full || !out_valid || empty || in_ready) $fatal(1,"queue full status incorrect");
  @(negedge clk);out_ready=1;
  for(i=1;i<=4;i=i+1) begin
   if(!out_valid || out_body[207:200]!==i || out_length!=13)
     $fatal(1,"queue order/data mismatch at %0d",i);
   @(posedge clk);@(negedge clk);
  end
  out_ready=0;
  if(!empty || full || out_valid) $fatal(1,"queue empty status incorrect");
  $display("PASS: reserved CONTROL queue ordering, full backpressure and drain");
  $finish;
 end
endmodule
