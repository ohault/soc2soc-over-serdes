// SPDX-License-Identifier: BSD-2-Clause
// Unpacks little-endian lane words into a byte stream.
// The input beat is retained until every KEEP-selected byte is accepted.
module bonded_frame_rx #(
    parameter integer DATA_WIDTH = 32,
    parameter integer WORD_BYTES = DATA_WIDTH / 8
) (
    input  wire                  clk,
    input  wire                  rst,
    input  wire                  in_valid,
    output wire                  in_ready,
    input  wire [DATA_WIDTH-1:0] in_data,
    input  wire [WORD_BYTES-1:0] in_keep,
    input  wire                  in_sop,
    input  wire                  in_eop,
    output wire                  out_valid,
    input  wire                  out_ready,
    output wire [7:0]            out_data,
    output wire                  out_sop,
    output wire                  out_eop
);
    localparam integer INDEX_WIDTH = $clog2(WORD_BYTES + 1);
    reg [DATA_WIDTH-1:0] data_reg;
    reg [WORD_BYTES-1:0] keep_reg;
    reg sop_reg, eop_reg, beat_valid;
    reg [INDEX_WIDTH-1:0] index;
    reg [INDEX_WIDTH-1:0] last_index;
    reg frame_open;
    integer k;

    assign in_ready = !beat_valid;
    assign out_valid = beat_valid;
    assign out_data = data_reg[index*8 +: 8];
    assign out_sop = sop_reg && (index == 0);
    assign out_eop = eop_reg && (index == last_index);

    always @(posedge clk) begin
        if (rst) begin
            data_reg <= 0;
            keep_reg <= 0;
            sop_reg <= 0;
            eop_reg <= 0;
            beat_valid <= 0;
            index <= 0;
            last_index <= 0;
            frame_open <= 0;
        end else begin
            if (beat_valid && out_ready) begin
                if (out_eop)
                    frame_open <= 0;
                if (index == WORD_BYTES-1 || !keep_reg[index+1]) begin
                    beat_valid <= 0;
                    index <= 0;
                end else begin
                    index <= index + 1'b1;
                end
            end

            if (in_valid && in_ready) begin
                // Reject sparse KEEP and malformed frame boundaries.
                if (in_keep == 0 ||
                    (in_keep & (in_keep + 1'b1)) != 0 ||
                    (in_sop && frame_open) ||
                    (!in_sop && !frame_open)) begin
                    beat_valid <= 0;
                    frame_open <= 0;
                end else begin
                    data_reg <= in_data;
                    keep_reg <= in_keep;
                    sop_reg <= in_sop;
                    eop_reg <= in_eop;
                    beat_valid <= 1;
                    index <= 0;
                    last_index <= 0;
                    for (k = 0; k < WORD_BYTES; k = k + 1)
                        if (in_keep[k]) last_index <= k;
                    if (in_sop)
                        frame_open <= 1;
                    if (in_eop)
                        frame_open <= 0;
                end
            end
        end
    end
endmodule
