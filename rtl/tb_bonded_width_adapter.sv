// SPDX-License-Identifier: BSD-2-Clause
`timescale 1ns/1ps
module tb_bonded_width_adapter;
    reg clk=0; always #5 clk=~clk;
    reg rst=1;
    reg in_valid=0, in_sop=0, in_eop=0, out_ready=0;
    reg [31:0] in_data=0;
    reg [3:0] in_keep=0;
    wire in_ready, out_valid, out_sop, out_eop;
    wire [63:0] out_data;
    wire [7:0] out_keep;

    bonded_width_adapter #(
        .IN_DATA_WIDTH(32), .OUT_DATA_WIDTH(64), .FIFO_BYTES(64)
    ) dut (
        .clk(clk), .rst(rst),
        .in_valid(in_valid), .in_ready(in_ready),
        .in_data(in_data), .in_keep(in_keep), .in_sop(in_sop), .in_eop(in_eop),
        .out_valid(out_valid), .out_ready(out_ready),
        .out_data(out_data), .out_keep(out_keep), .out_sop(out_sop), .out_eop(out_eop)
    );

    task send(input [31:0] data, input [3:0] keep, input sop, input eop);
    begin
        @(negedge clk);
        in_valid=1; in_data=data; in_keep=keep; in_sop=sop; in_eop=eop;
        while (!in_ready) @(negedge clk);
        @(posedge clk); #1;
        in_valid=0; in_sop=0; in_eop=0;
    end endtask

    task check_output(input [63:0] data, input [7:0] keep, input sop, input eop);
    begin
        while (!out_valid) @(negedge clk);
        #1;
        if (out_data !== data || out_keep !== keep ||
            out_sop !== sop || out_eop !== eop)
            $fatal(1,"adapter output mismatch data=%h keep=%h sop=%b eop=%b",
                   out_data,out_keep,out_sop,out_eop);
        @(posedge clk); #1;
    end endtask

    initial begin
        repeat(3) @(posedge clk);
        @(negedge clk); rst=0; out_ready=0;

        // Two 32-bit input beats become one 64-bit output beat.
        send(32'h44332211,4'hf,1,0);
        send(32'h88776655,4'hf,0,1);
        repeat(3) begin
            @(posedge clk); #1;
            if (!out_valid || out_data !== 64'h8877665544332211 ||
                out_keep !== 8'hff || !out_sop || !out_eop)
                $fatal(1,"adapter failed aggregation or stalled stability");
        end
        @(negedge clk); out_ready=1;
        check_output(64'h8877665544332211,8'hff,1,1);

        // A four-byte frame remains a partial 64-bit output beat.
        send(32'h000000aa,4'h1,1,1);
        expect(64'h00000000000000aa,8'h01,1,1);

        // Invalid zero KEEP is dropped; a new valid frame recovers.
        send(32'h00000000,4'h0,1,1);
        send(32'h000000bb,4'h1,1,1);
        expect(64'h00000000000000bb,8'h01,1,1);

        $display("PASS: 32-to-64 width conversion, KEEP, framing and backpressure");
        $finish;
    end

    initial begin
        #100000;
        $fatal(1,"width adapter test timeout");
    end
endmodule
