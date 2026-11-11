// SPDX-License-Identifier: BSD-2-Clause
// Width-configurable framed ready/valid stream register.
// One beat per cycle; KEEP is a contiguous low-order byte mask.
module bonded_stream_tx #(
    parameter integer DATA_WIDTH = 32,
    parameter integer KEEP_WIDTH = DATA_WIDTH / 8
) (
    input wire clk, input wire rst,
    input wire in_valid, output wire in_ready,
    input wire [DATA_WIDTH-1:0] in_data,
    input wire [KEEP_WIDTH-1:0] in_keep,
    input wire in_sop, input wire in_eop,
    output reg out_valid, input wire out_ready,
    output reg [DATA_WIDTH-1:0] out_data,
    output reg [KEEP_WIDTH-1:0] out_keep,
    output reg out_sop, output reg out_eop
);
    reg frame_open;
    integer k;
    reg keep_contiguous;
    always @* begin
        keep_contiguous = (in_keep != 0) &&
                          ((in_keep & (in_keep + 1'b1)) == 0);
    end
    assign in_ready = !out_valid || out_ready;

    initial begin
        if (DATA_WIDTH < 8 || (DATA_WIDTH % 8) != 0)
            $error("DATA_WIDTH must be a positive multiple of 8");
        if (KEEP_WIDTH != DATA_WIDTH/8)
            $error("KEEP_WIDTH must equal DATA_WIDTH/8");
    end

    always @(posedge clk) begin
        if (rst) begin
            frame_open <= 0;
            out_valid <= 0;
            out_data <= 0;
            out_keep <= 0;
            out_sop <= 0;
            out_eop <= 0;
        end else if (in_ready) begin
            if (out_valid) out_valid <= 0;
            if (in_valid) begin
                if (!keep_contiguous ||
                    (!in_eop && in_keep != {KEEP_WIDTH{1'b1}}) ||
                    (in_sop && frame_open) ||
                    (!in_sop && !frame_open)) begin
                    // Drop malformed beat and abandon current frame.
                    frame_open <= 0;
                end else begin
                    out_data <= in_data;
                    out_keep <= in_keep;
                    out_sop <= in_sop;
                    out_eop <= in_eop;
                    out_valid <= 1;
                    if (in_sop) frame_open <= !in_eop;
                    else if (in_eop) frame_open <= 0;
                end
            end
        end
    end
endmodule
