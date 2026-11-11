// SPDX-License-Identifier: BSD-2-Clause
`timescale 1ns/1ps

module stream_width_case #(
    parameter integer DATA_WIDTH = 32,
    parameter integer KEEP_WIDTH = DATA_WIDTH/8,
    parameter integer CASE_ID = 0
) (
    input wire clk,
    output reg done = 0
);
    reg rst = 1;
    reg in_valid = 0, in_sop = 0, in_eop = 0;
    reg [DATA_WIDTH-1:0] in_data = 0;
    reg [KEEP_WIDTH-1:0] in_keep = 0;
    wire in_ready;
    wire tx_valid, tx_ready, tx_sop, tx_eop;
    wire [DATA_WIDTH-1:0] tx_data;
    wire [KEEP_WIDTH-1:0] tx_keep;
    wire rx_in_ready, rx_valid, rx_sop, rx_eop;
    wire [DATA_WIDTH-1:0] rx_data;
    wire [KEEP_WIDTH-1:0] rx_keep;
    reg rx_ready = 0;

    bonded_stream_tx #(.DATA_WIDTH(DATA_WIDTH), .KEEP_WIDTH(KEEP_WIDTH)) tx (
        .clk(clk), .rst(rst),
        .in_valid(in_valid), .in_ready(in_ready),
        .in_data(in_data), .in_keep(in_keep), .in_sop(in_sop), .in_eop(in_eop),
        .out_valid(tx_valid), .out_ready(tx_ready),
        .out_data(tx_data), .out_keep(tx_keep), .out_sop(tx_sop), .out_eop(tx_eop)
    );

    bonded_stream_rx #(.DATA_WIDTH(DATA_WIDTH), .KEEP_WIDTH(KEEP_WIDTH)) rx (
        .clk(clk), .rst(rst),
        .in_valid(tx_valid), .in_ready(tx_ready),
        .in_data(tx_data), .in_keep(tx_keep), .in_sop(tx_sop), .in_eop(tx_eop),
        .out_valid(rx_valid), .out_ready(rx_ready),
        .out_data(rx_data), .out_keep(rx_keep), .out_sop(rx_sop), .out_eop(rx_eop)
    );

    task send_beat;
        input [DATA_WIDTH-1:0] data;
        input [KEEP_WIDTH-1:0] keep;
        input sop;
        input eop;
        begin
            @(negedge clk);
            in_valid = 1; in_data = data; in_keep = keep;
            in_sop = sop; in_eop = eop;
            while (!in_ready) @(negedge clk);
            @(posedge clk); #1;
            in_valid = 0; in_sop = 0; in_eop = 0;
        end
    endtask

    task expect_beat;
        input [DATA_WIDTH-1:0] data;
        input [KEEP_WIDTH-1:0] keep;
        input sop;
        input eop;
        begin
            while (!rx_valid) @(negedge clk);
            #1;
            if (rx_data !== data || rx_keep !== keep ||
                rx_sop !== sop || rx_eop !== eop)
                $fatal(1, "width %0d case %0d mismatch", DATA_WIDTH, CASE_ID);
            @(posedge clk); #1;
        end
    endtask

    initial begin
        repeat (3) @(posedge clk);
        @(negedge clk); rst = 0; rx_ready = 0;

        // Stall the receive side while the first full-width beat is buffered.
        send_beat({DATA_WIDTH{1'b1}}, {KEEP_WIDTH{1'b1}}, 1, 0);
        repeat (3) begin
            @(posedge clk); #1;
            if (!rx_valid || rx_data !== {DATA_WIDTH{1'b1}} ||
                rx_keep !== {KEEP_WIDTH{1'b1}} || !rx_sop || rx_eop)
                $fatal(1, "width %0d case %0d failed stall stability", DATA_WIDTH, CASE_ID);
        end

        // Queue a short final beat while downstream is stalled.
        send_beat({DATA_WIDTH{1'b0}} | {{(DATA_WIDTH-8){1'b0}}, 8'hA5},
                  {{(KEEP_WIDTH-1){1'b0}}, 1'b1}, 0, 1);
        @(negedge clk); rx_ready = 1;
        expect_beat({DATA_WIDTH{1'b1}}, {KEEP_WIDTH{1'b1}}, 1, 0);
        expect_beat({{(DATA_WIDTH-8){1'b0}}, 8'hA5},
                    {{(KEEP_WIDTH-1){1'b0}}, 1'b1}, 0, 1);

        // Sparse KEEP is malformed; the following single-beat frame recovers.
        send_beat({DATA_WIDTH{1'b0}}, {{(KEEP_WIDTH-2){1'b0}}, 2'b01} << 1,
                  1, 1);
        send_beat({{(DATA_WIDTH-8){1'b0}}, 8'h5A},
                  {{(KEEP_WIDTH-1){1'b0}}, 1'b1}, 1, 1);
        expect_beat({{(DATA_WIDTH-8){1'b0}}, 8'h5A},
                    {{(KEEP_WIDTH-1){1'b0}}, 1'b1}, 1, 1);

        done = 1;
        $display("PASS: stream width %0d", DATA_WIDTH);
    end
endmodule

module tb_bonded_stream_width;
    reg clk = 0;
    always #5 clk = ~clk;
    wire done8, done32, done64, done128;

    stream_width_case #(.DATA_WIDTH(8), .KEEP_WIDTH(1), .CASE_ID(8)) c8(clk, done8);
    stream_width_case #(.DATA_WIDTH(32), .KEEP_WIDTH(4), .CASE_ID(32)) c32(clk, done32);
    stream_width_case #(.DATA_WIDTH(64), .KEEP_WIDTH(8), .CASE_ID(64)) c64(clk, done64);
    stream_width_case #(.DATA_WIDTH(128), .KEEP_WIDTH(16), .CASE_ID(128)) c128(clk, done128);

    initial begin
        wait(done8 && done32 && done64 && done128);
        $display("PASS: 8/32/64/128-bit framed stream round-trip");
        $finish;
    end

    initial begin
        #100000;
        $fatal(1, "stream width test timeout");
    end
endmodule
