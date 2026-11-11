// SPDX-License-Identifier: BSD-2-Clause
`timescale 1ns/1ps
module tb_bonded_stream_width;
    reg clk=0; always #5 clk=~clk;
    reg rst=1;
    reg in_valid=0, in_sop=0, in_eop=0, out_ready=0;
    reg [63:0] in_data=0;
    reg [7:0] in_keep=0;
    wire in_ready, out_valid, out_sop, out_eop;
    wire [63:0] out_data;
    wire [7:0] out_keep;

    bonded_stream_tx #(.DATA_WIDTH(64),.KEEP_WIDTH(8)) dut(
        .clk(clk),.rst(rst),.in_valid(in_valid),.in_ready(in_ready),
        .in_data(in_data),.in_keep(in_keep),.in_sop(in_sop),.in_eop(in_eop),
        .out_valid(out_valid),.out_ready(out_ready),.out_data(out_data),
        .out_keep(out_keep),.out_sop(out_sop),.out_eop(out_eop)
    );

    task send(input [63:0] data,input [7:0] keep,input sop,input eop);
    begin
      @(negedge clk); in_valid=1; in_data=data; in_keep=keep; in_sop=sop; in_eop=eop;
      while(!in_ready) @(negedge clk);
      @(posedge clk); #1; in_valid=0; in_sop=0; in_eop=0;
    end endtask

    initial begin
      repeat(2) @(posedge clk);
      @(negedge clk); rst=0; out_ready=0;
      send(64'h0706050403020100,8'hff,1,0);
      repeat(3) begin
        @(posedge clk); #1;
        if(!out_valid || out_data!==64'h0706050403020100 ||
           out_keep!==8'hff || !out_sop || out_eop)
          $fatal(1,"64-bit beat changed under stall");
      end
      @(negedge clk); out_ready=1;
      @(posedge clk); #1;
      if(out_valid) $fatal(1,"stalled beat not consumed");
      send(64'h0000000000000908,8'h03,0,1);
      @(posedge clk); #1;
      if(!out_valid || out_data!==64'h0000000000000908 ||
         out_keep!==8'h03 || out_sop || !out_eop)
        $fatal(1,"partial final beat incorrect");
      // malformed sparse keep must be discarded and next SOP accepted.
      @(negedge clk); out_ready=1;
      send(64'h11,8'h05,1,1);
      @(negedge clk);
      if(out_valid) $fatal(1,"sparse KEEP was accepted");
      send(64'hcc,8'h01,1,1);
      @(posedge clk); #1;
      if(!out_valid || out_data!==64'hcc || !out_sop || !out_eop)
        $fatal(1,"stream did not recover after malformed beat");
      $display("PASS: configurable 64-bit stream, partial KEEP, stall and recovery");
      $finish;
    end
endmodule
