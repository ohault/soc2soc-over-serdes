// SPDX-License-Identifier: BSD-2-Clause
`timescale 1ns/1ps
module tb_bonded_frame_rx;
    reg clk=0; always #5 clk=~clk;
    reg rst=1, in_valid=0, in_sop=0, in_eop=0, out_ready=0;
    reg [31:0] in_data=0;
    reg [3:0] in_keep=0;
    wire in_ready, out_valid, out_sop, out_eop;
    wire [7:0] out_data;

    bonded_frame_rx dut(
        .clk(clk), .rst(rst), .in_valid(in_valid), .in_ready(in_ready),
        .in_data(in_data), .in_keep(in_keep), .in_sop(in_sop), .in_eop(in_eop),
        .out_valid(out_valid), .out_ready(out_ready), .out_data(out_data),
        .out_sop(out_sop), .out_eop(out_eop)
    );

    task send_beat(input [31:0] data, input [3:0] keep,
                   input sop, input eop);
    begin
        @(negedge clk);
        in_valid=1; in_data=data; in_keep=keep; in_sop=sop; in_eop=eop;
        while (!in_ready) @(negedge clk);
        @(posedge clk); #1;
        in_valid=0; in_sop=0; in_eop=0;
    end endtask

    task expect_byte(input [7:0] data, input sop, input eop);
    begin
        while (!out_valid) @(negedge clk);
        #1;
        if (out_data !== data || out_sop !== sop || out_eop !== eop)
            $fatal(1,"RX byte mismatch got=%02x sop=%b eop=%b expected=%02x/%b/%b",
                   out_data,out_sop,out_eop,data,sop,eop);
        @(posedge clk); #1;
    end endtask

    initial begin
        repeat(3) @(posedge clk);
        @(negedge clk); rst=0; out_ready=0;
        send_beat(32'h67452301,4'hf,1,0);
        repeat(3) begin
            @(posedge clk); #1;
            if (!out_valid || out_data !== 8'h01 || !out_sop || out_eop)
                $fatal(1,"RX first byte not held during stall");
        end
        @(negedge clk); out_ready=1;
        expect_byte(8'h01,1,0);
        expect_byte(8'h23,0,0);
        expect_byte(8'h45,0,0);
        expect_byte(8'h67,0,0);
        send_beat(32'h00000089,4'h1,0,1);
        expect_byte(8'h89,0,1);
        @(negedge clk);
        if (out_valid) $fatal(1,"RX output not empty");
        $display("PASS: RX byte order, partial KEEP, SOP/EOP and backpressure");
        $finish;
    end
endmodule
