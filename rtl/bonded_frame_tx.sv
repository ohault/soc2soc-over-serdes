// SPDX-License-Identifier: BSD-2-Clause
// Packs a byte stream into little-endian lane words.
// One byte is accepted per cycle. SOP/EOP delimit the complete wire frame.
module bonded_frame_tx #(
    parameter integer DATA_WIDTH = 32,
    parameter integer WORD_BYTES = DATA_WIDTH / 8
) (
    input  wire                  clk,
    input  wire                  rst,
    input  wire                  in_valid,
    output wire                  in_ready,
    input  wire [7:0]            in_data,
    input  wire                  in_sop,
    input  wire                  in_eop,
    output reg                   out_valid,
    input  wire                  out_ready,
    output reg  [DATA_WIDTH-1:0] out_data,
    output reg  [WORD_BYTES-1:0] out_keep,
    output reg                   out_sop,
    output reg                   out_eop
);
    localparam integer COUNT_WIDTH = $clog2(WORD_BYTES + 1);
    reg [DATA_WIDTH-1:0] assembly;
    reg [COUNT_WIDTH-1:0] count;
    reg frame_open;
    reg word_sop;

    assign in_ready = !out_valid || out_ready;

    initial begin
        if (DATA_WIDTH < 8 || (DATA_WIDTH % 8) != 0)
            $error("DATA_WIDTH must be a positive multiple of 8");
        if (WORD_BYTES < 1)
            $error("WORD_BYTES must be positive");
    end

    always @(posedge clk) begin
        if (rst) begin
            assembly <= {DATA_WIDTH{1'b0}};
            count <= 0;
            frame_open <= 1'b0;
            word_sop <= 1'b0;
            out_valid <= 1'b0;
            out_data <= {DATA_WIDTH{1'b0}};
            out_keep <= {WORD_BYTES{1'b0}};
            out_sop <= 1'b0;
            out_eop <= 1'b0;
        end else if (in_ready) begin
            if (out_valid)
                out_valid <= 1'b0;

            if (in_valid && in_ready) begin
                if ((!frame_open && !in_sop) || (frame_open && in_sop)) begin
                    // Malformed framing: discard the partial frame.
                    count <= 0;
                    frame_open <= 1'b0;
                    assembly <= {DATA_WIDTH{1'b0}};
                end else begin
                    assembly[count*8 +: 8] <= in_data;
                    if (count == 0) begin
                        frame_open <= 1'b1;
                        word_sop <= in_sop;
                    end

                    if ((count == WORD_BYTES-1) || in_eop) begin
                        out_data <= assembly;
                        out_data[count*8 +: 8] <= in_data;
                        out_keep <= ({WORD_BYTES{1'b1}} >> (WORD_BYTES - count - 1));
                        out_valid <= 1'b1;
                        out_sop <= (count == 0) ? in_sop : word_sop;
                        out_eop <= in_eop;
                        count <= 0;
                        word_sop <= 1'b0;
                        if (in_eop)
                            frame_open <= 1'b0;
                    end else begin
                        count <= count + 1'b1;
                    end
                end
            end
        end
    end
endmodule
