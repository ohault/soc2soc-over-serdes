// SPDX-License-Identifier: BSD-2-Clause
// Same-clock, byte-preserving framed stream width converter.
// Input and output widths are independent multiples of eight.
// Frames are never merged: SOP/EOP are attached to the first/last byte.
module bonded_width_adapter #(
    parameter integer IN_DATA_WIDTH = 32,
    parameter integer OUT_DATA_WIDTH = 64,
    parameter integer IN_KEEP_WIDTH = IN_DATA_WIDTH/8,
    parameter integer OUT_KEEP_WIDTH = OUT_DATA_WIDTH/8,
    parameter integer FIFO_BYTES = 256,
    parameter integer PTR_WIDTH = $clog2(FIFO_BYTES),
    parameter integer COUNT_WIDTH = $clog2(FIFO_BYTES+1)
) (
    input wire clk, input wire rst,
    input wire in_valid, output wire in_ready,
    input wire [IN_DATA_WIDTH-1:0] in_data,
    input wire [IN_KEEP_WIDTH-1:0] in_keep,
    input wire in_sop, input wire in_eop,
    output reg out_valid, input wire out_ready,
    output reg [OUT_DATA_WIDTH-1:0] out_data,
    output reg [OUT_KEEP_WIDTH-1:0] out_keep,
    output reg out_sop, output reg out_eop
);
    localparam integer IN_BYTES = IN_DATA_WIDTH/8;
    localparam integer OUT_BYTES = OUT_DATA_WIDTH/8;

    reg [7:0] byte_mem [0:FIFO_BYTES-1];
    reg sop_mem [0:FIFO_BYTES-1];
    reg eop_mem [0:FIFO_BYTES-1];
    reg [PTR_WIDTH-1:0] rd_ptr, wr_ptr;
    reg [COUNT_WIDTH-1:0] used;
    reg frame_open;

    integer in_count;
    integer out_count;
    integer i, idx, wr_next, rd_next;
    reg keep_contiguous;
    reg end_found;
    reg input_good;

    function integer bump;
        input integer ptr;
        begin
            if (ptr == FIFO_BYTES-1) bump = 0;
            else bump = ptr + 1;
        end
    endfunction

    always @* begin
        keep_contiguous = (in_keep != 0) &&
                          ((in_keep & (in_keep + 1'b1)) == 0);
        in_count = 0;
        for (i=0; i<IN_BYTES; i=i+1)
            if (in_keep[i]) in_count = in_count + 1;

        input_good = keep_contiguous &&
                     (in_eop || in_keep == {IN_KEEP_WIDTH{1'b1}}) &&
                     !(in_sop && frame_open) &&
                     !(!in_sop && !frame_open);

        out_data = {OUT_DATA_WIDTH{1'b0}};
        out_keep = {OUT_KEEP_WIDTH{1'b0}};
        out_sop = 1'b0;
        out_eop = 1'b0;
        out_count = 0;
        end_found = 1'b0;
        for (i=0; i<OUT_BYTES; i=i+1) begin
            if ((i < used) && !end_found) begin
                idx = rd_ptr + i;
                if (idx >= FIFO_BYTES) idx = idx - FIFO_BYTES;
                out_data[i*8 +: 8] = byte_mem[idx];
                out_count = out_count + 1;
                if (eop_mem[idx]) end_found = 1'b1;
            end
        end
        out_valid = (out_count == OUT_BYTES) || end_found;
        if (out_count != 0) begin
            out_keep = {OUT_KEEP_WIDTH{1'b1}} >> (OUT_BYTES-out_count);
            idx = rd_ptr;
            out_sop = sop_mem[idx];
            idx = rd_ptr + out_count - 1;
            if (idx >= FIFO_BYTES) idx = idx - FIFO_BYTES;
            out_eop = eop_mem[idx];
        end
    end

    assign in_ready = (used <= FIFO_BYTES-IN_BYTES);

    initial begin
        if (IN_DATA_WIDTH < 8 || (IN_DATA_WIDTH % 8) != 0)
            $error("IN_DATA_WIDTH must be a positive multiple of 8");
        if (OUT_DATA_WIDTH < 8 || (OUT_DATA_WIDTH % 8) != 0)
            $error("OUT_DATA_WIDTH must be a positive multiple of 8");
        if (IN_KEEP_WIDTH != IN_BYTES || OUT_KEEP_WIDTH != OUT_BYTES)
            $error("KEEP widths must equal their data widths divided by 8");
        if (FIFO_BYTES < IN_BYTES || FIFO_BYTES < OUT_BYTES ||
            (FIFO_BYTES & (FIFO_BYTES-1)) != 0)
            $error("FIFO_BYTES must be a power of two and fit both stream widths");
    end

    always @(posedge clk) begin
        if (rst) begin
            rd_ptr <= 0;
            wr_ptr <= 0;
            used <= 0;
            frame_open <= 0;
        end else begin
            if (in_valid && in_ready) begin
                if (!input_good) begin
                    frame_open <= 0;
                end else begin
                    wr_next = wr_ptr;
                    for (i=0; i<IN_BYTES; i=i+1) begin
                        if (i < in_count) begin
                            byte_mem[wr_next] <= in_data[i*8 +: 8];
                            sop_mem[wr_next] <= in_sop && (i == 0);
                            eop_mem[wr_next] <= in_eop && (i == in_count-1);
                            wr_next = bump(wr_next);
                        end
                    end
                    wr_ptr <= wr_next[PTR_WIDTH-1:0];
                    if (in_sop) frame_open <= !in_eop;
                    else if (in_eop) frame_open <= 0;
                end
            end

            if (out_valid && out_ready) begin
                rd_next = rd_ptr;
                for (i=0; i<OUT_BYTES; i=i+1)
                    if (i < out_count) rd_next = bump(rd_next);
                rd_ptr <= rd_next[PTR_WIDTH-1:0];
            end

            case ({(in_valid && in_ready && input_good),
                   (out_valid && out_ready)})
                2'b10: used <= used + in_count;
                2'b01: used <= used - out_count;
                2'b11: used <= used + in_count - out_count;
                default: used <= used;
            endcase
        end
    end
endmodule
