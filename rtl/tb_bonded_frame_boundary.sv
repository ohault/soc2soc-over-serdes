// SPDX-License-Identifier: BSD-2-Clause
`timescale 1ns/1ps
module tb_bonded_frame_boundary;
    reg clk=0; always #5 clk=~clk;
    reg rst=1;
    reg in_valid=0, in_sop=0, in_eop=0, out_ready=0;
    reg [7:0] in_data=0;
    wire in_ready, out_valid, out_sop, out_eop;
    wire [31:0] out_data;
    wire [3:0] out_keep;

    bonded_frame_tx tx(
        .clk(clk), .rst(rst), .in_valid(in_valid), .in_ready(in_ready),
        .in_data(in_data), .in_sop(in_sop), .in_eop(in_eop),
        .out_valid(out_valid), .out_ready(out_ready), .out_data(out_data),
        .out_keep(out_keep), .out_sop(out_sop), .out_eop(out_eop)
    );

    task send_byte(input [7:0] value, input sop, input eop);
    begin
        @(negedge clk); in_valid=1; in_data=value; in_sop=sop; in_eop=eop;
        while (!in_ready) @(negedge clk);
        @(posedge clk); #1; in_valid=0; in_sop=0; in_eop=0;
    end endtask

    initial begin
        repeat(3) @(posedge clk);
        @(negedge clk); rst=0; out_ready=0;
        send_byte(8'h01,1,0);
        send_byte(8'h23,0,0);
        send_byte(8'h45,0,0);
        send_byte(8'h67,0,0);
        repeat(3) begin
            @(posedge clk); #1;
            if (!out_valid || out_data !== 32'h67452301 ||
                out_keep !== 4'hf || !out_sop || out_eop)
                $fatal(1,"first beat incorrect or not held during stall");
        end
        @(negedge clk); out_ready=1;
        @(posedge clk); #1;
        if (out_valid) $fatal(1,"TX did not retire first beat");
        @(negedge clk); out_ready=0;
        send_byte(8'h89,0,1);
        @(posedge clk); #1;
        if (!out_valid || out_data !== 32'h00000089 ||
            out_keep !== 4'h1 || out_sop || !out_eop)
            $fatal(1,"partial final beat incorrect");
        @(negedge clk); out_ready=1;
        @(posedge clk); #1;
        if (out_valid) $fatal(1,"TX did not retire final beat");
        $display("PASS: TX packing, partial KEEP, SOP/EOP and backpressure");
        $finish;
    end
endmodule
