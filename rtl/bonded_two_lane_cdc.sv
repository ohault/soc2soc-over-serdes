// SPDX-License-Identifier: BSD-2-Clause
// Two-lane CDC ingress/egress wrapper.
// Each lane has its own recovered write clock and asynchronous FIFO. Both
// FIFOs are read in the common bonding clock domain. This module deliberately
// does not merge, reorder, arbitrate or bond packets: those are responsibilities
// of the protocol-independent bonding core above this boundary.
module bonded_two_lane_cdc #(
    parameter integer DATA_WIDTH = 32,
    parameter integer FIFO_DEPTH = 16
) (
    input  wire                  bond_rst_n,

    input  wire                  lane0_clk,
    input  wire                  lane0_rst_n,
    input  wire                  lane0_valid,
    output wire                  lane0_ready,
    input  wire [DATA_WIDTH-1:0] lane0_data,

    input  wire                  lane1_clk,
    input  wire                  lane1_rst_n,
    input  wire                  lane1_valid,
    output wire                  lane1_ready,
    input  wire [DATA_WIDTH-1:0] lane1_data,

    input  wire                  bond_clk,
    output wire                  bond_lane0_valid,
    input  wire                  bond_lane0_ready,
    output wire [DATA_WIDTH-1:0] bond_lane0_data,

    output wire                  bond_lane1_valid,
    input  wire                  bond_lane1_ready,
    output wire [DATA_WIDTH-1:0] bond_lane1_data
);
    wire lane0_fifo_rst_n = bond_rst_n && lane0_rst_n;
    wire lane1_fifo_rst_n = bond_rst_n && lane1_rst_n;

    bonded_async_fifo #(
        .DATA_WIDTH(DATA_WIDTH),
        .DEPTH(FIFO_DEPTH)
    ) lane0_fifo (
        .wr_clk(lane0_clk),
        .wr_rst_n(lane0_fifo_rst_n),
        .wr_valid(lane0_valid),
        .wr_ready(lane0_ready),
        .wr_data(lane0_data),
        .rd_clk(bond_clk),
        .rd_rst_n(lane0_fifo_rst_n),
        .rd_valid(bond_lane0_valid),
        .rd_ready(bond_lane0_ready),
        .rd_data(bond_lane0_data)
    );

    bonded_async_fifo #(
        .DATA_WIDTH(DATA_WIDTH),
        .DEPTH(FIFO_DEPTH)
    ) lane1_fifo (
        .wr_clk(lane1_clk),
        .wr_rst_n(lane1_fifo_rst_n),
        .wr_valid(lane1_valid),
        .wr_ready(lane1_ready),
        .wr_data(lane1_data),
        .rd_clk(bond_clk),
        .rd_rst_n(lane1_fifo_rst_n),
        .rd_valid(bond_lane1_valid),
        .rd_ready(bond_lane1_ready),
        .rd_data(bond_lane1_data)
    );
endmodule
