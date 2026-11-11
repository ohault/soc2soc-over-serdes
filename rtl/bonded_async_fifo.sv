// SPDX-License-Identifier: BSD-2-Clause
// Generic dual-clock asynchronous FIFO using binary local pointers and
// Gray-coded pointer synchronizers. DEPTH must be a power of two >= 4.
//
// Reset contract: assert wr_rst_n and rd_rst_n together to flush the FIFO.
// Deassertion may be asynchronous at the pins; each domain uses the reset
// synchronously in its own clocked process. The surrounding design must keep
// traffic disabled until both domains have left reset.
module bonded_async_fifo #(
    parameter integer DATA_WIDTH = 32,
    parameter integer DEPTH = 16,
    parameter integer ADDR_WIDTH = $clog2(DEPTH)
) (
    input  wire                  wr_clk,
    input  wire                  wr_rst_n,
    input  wire                  wr_valid,
    output wire                  wr_ready,
    input  wire [DATA_WIDTH-1:0] wr_data,

    input  wire                  rd_clk,
    input  wire                  rd_rst_n,
    output wire                  rd_valid,
    input  wire                  rd_ready,
    output wire [DATA_WIDTH-1:0] rd_data
);
    localparam integer PTR_WIDTH = ADDR_WIDTH + 1;

    reg [DATA_WIDTH-1:0] mem [0:DEPTH-1];
    reg [PTR_WIDTH-1:0] wr_bin, wr_gray;
    reg [PTR_WIDTH-1:0] rd_bin, rd_gray;

    (* async_reg = "true" *) reg [PTR_WIDTH-1:0] rd_gray_sync1, rd_gray_sync2;
    (* async_reg = "true" *) reg [PTR_WIDTH-1:0] wr_gray_sync1, wr_gray_sync2;

    wire [PTR_WIDTH-1:0] wr_bin_next = wr_bin + (wr_valid && wr_ready);
    wire [PTR_WIDTH-1:0] rd_bin_next = rd_bin + (rd_valid && rd_ready);
    wire [PTR_WIDTH-1:0] wr_gray_next = (wr_bin_next >> 1) ^ wr_bin_next;
    wire [PTR_WIDTH-1:0] rd_gray_next = (rd_bin_next >> 1) ^ rd_bin_next;

    // Full when the next write pointer equals the synchronized read pointer
    // with its two most-significant Gray bits inverted.
    wire [PTR_WIDTH-1:0] rd_gray_full_cmp =
        {~rd_gray_sync2[PTR_WIDTH-1:PTR_WIDTH-2],
          rd_gray_sync2[PTR_WIDTH-3:0]};
    reg full_reg, empty_reg;

    assign wr_ready = !full_reg;
    assign rd_valid = !empty_reg;
    // First-word-fall-through read. The memory is written only in wr_clk
    // domain and addressed by the stable read pointer in rd_clk domain.
    assign rd_data = mem[rd_bin[ADDR_WIDTH-1:0]];

    initial begin
        if (DEPTH < 4 || (DEPTH & (DEPTH-1)) != 0)
            $error("DEPTH must be a power of two and at least four");
        if (ADDR_WIDTH < 2)
            $error("ADDR_WIDTH must be at least two");
    end

    always @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n) begin
            wr_bin <= 0;
            wr_gray <= 0;
            rd_gray_sync1 <= 0;
            rd_gray_sync2 <= 0;
            full_reg <= 1'b0;
        end else begin
            rd_gray_sync1 <= rd_gray;
            rd_gray_sync2 <= rd_gray_sync1;
            if (wr_valid && wr_ready)
                mem[wr_bin[ADDR_WIDTH-1:0]] <= wr_data;
            wr_bin <= wr_bin_next;
            wr_gray <= wr_gray_next;
            full_reg <= (wr_gray_next == rd_gray_full_cmp);
        end
    end

    always @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n) begin
            rd_bin <= 0;
            rd_gray <= 0;
            wr_gray_sync1 <= 0;
            wr_gray_sync2 <= 0;
            empty_reg <= 1'b1;
        end else begin
            wr_gray_sync1 <= wr_gray;
            wr_gray_sync2 <= wr_gray_sync1;
            rd_bin <= rd_bin_next;
            rd_gray <= rd_gray_next;
            empty_reg <= (rd_gray_next == wr_gray_sync2);
        end
    end
endmodule
