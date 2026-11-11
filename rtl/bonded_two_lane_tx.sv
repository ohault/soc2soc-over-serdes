// SPDX-License-Identifier: BSD-2-Clause
// Complete two-lane TX path: common-clock packet scheduler -> independent
// asynchronous lane FIFOs -> per-lane v0 wire encoders.
module bonded_two_lane_tx #(
    parameter integer DATA_WIDTH = 32,
    parameter integer KEEP_WIDTH = DATA_WIDTH/8,
    parameter integer FIFO_DEPTH = 64,
    parameter integer MAX_PACKET_BYTES = 4096,
    parameter integer LANE0_ID = 0,
    parameter integer LANE1_ID = 1
) (
    input wire bond_clk,
    input wire bond_rst_n,
    input wire [63:0] session_id,
    // Latest cumulative grants received from the peer's CONTROL/CREDIT frames.
    input wire [63:0] remote_byte_limit,
    input wire [31:0] remote_packet_limit,

    input wire tx_valid, output wire tx_ready,
    input wire [DATA_WIDTH-1:0] tx_data,
    input wire [KEEP_WIDTH-1:0] tx_keep,
    input wire tx_sop, input wire tx_eop,

    input wire lane0_clk, input wire lane0_rst_n,
    output wire lane0_valid, input wire lane0_ready,
    output wire [7:0] lane0_data, output wire lane0_sop, output wire lane0_eop,

    input wire lane1_clk, input wire lane1_rst_n,
    output wire lane1_valid, input wire lane1_ready,
    output wire [7:0] lane1_data, output wire lane1_sop, output wire lane1_eop,

    output wire packet_error,
    output wire lane0_frame_error, output wire lane1_frame_error,
    output wire [31:0] lane0_frame_sequence, output wire [31:0] lane1_frame_sequence
);
    localparam integer LANE_COUNT=2;
    localparam integer META_WIDTH=DATA_WIDTH+KEEP_WIDTH+2+32+16;
    wire [1:0] sched_valid, sched_ready, sched_sop, sched_eop;
    wire [2*DATA_WIDTH-1:0] sched_data;
    wire [2*KEEP_WIDTH-1:0] sched_keep;
    wire [63:0] sched_packet_sequence;
    wire [31:0] sched_packet_length;
    wire [META_WIDTH-1:0] fifo0_in, fifo1_in, fifo0_out, fifo1_out;
    wire fifo0_wr_ready, fifo1_wr_ready;
    wire fifo0_rd_valid, fifo1_rd_valid;
    wire enc0_in_ready, enc1_in_ready;
    wire credit_reserve_ready, credit_reserve_valid;
    wire [15:0] credit_reserve_bytes;
    wire [63:0] tx_reserved_bytes;
    wire [31:0] tx_reserved_packets;

    bonded_credit_manager credit_accounting (
        .clk(bond_clk), .rst(!bond_rst_n),
        .tx_reserve_valid(credit_reserve_valid),
        .tx_reserve_bytes(credit_reserve_bytes),
        .tx_reserve_ready(credit_reserve_ready),
        .remote_byte_limit(remote_byte_limit),
        .remote_packet_limit(remote_packet_limit),
        .tx_reserved_bytes(tx_reserved_bytes),
        .tx_reserved_packets(tx_reserved_packets),
        .rx_accept_valid(1'b0), .rx_accept_bytes(16'd0),
        .rx_accept_ready(), .rx_consume_valid(1'b0), .rx_consume_bytes(16'd0),
        .rx_accepted_bytes(), .rx_accepted_packets(),
        .rx_consumed_bytes(), .rx_consumed_packets(),
        .local_byte_limit(), .local_packet_limit(), .credit_error()
    );

    assign sched_ready={fifo1_wr_ready,fifo0_wr_ready};
    bonded_packet_tx #(
        .DATA_WIDTH(DATA_WIDTH),.LANE_COUNT(LANE_COUNT),
        .MAX_PACKET_BYTES(MAX_PACKET_BYTES)
    ) scheduler (
        .clk(bond_clk),.rst(!bond_rst_n),
        .tx_valid(tx_valid),.tx_ready(tx_ready),.tx_data(tx_data),
        .tx_keep(tx_keep),.tx_sop(tx_sop),.tx_eop(tx_eop),
        .credit_reserve_ready(credit_reserve_ready),
        .credit_reserve_valid(credit_reserve_valid),
        .credit_reserve_bytes(credit_reserve_bytes),
        .lane_valid(sched_valid),.lane_ready(sched_ready),
        .lane_data(sched_data),.lane_keep(sched_keep),
        .lane_sop(sched_sop),.lane_eop(sched_eop),
        .lane_packet_sequence(sched_packet_sequence),
        .lane_packet_length(sched_packet_length),
        .packet_error(packet_error)
    );

    assign fifo0_in={sched_packet_length[15:0],sched_packet_sequence[31:0],
                     sched_eop[0],sched_sop[0],sched_keep[0 +: KEEP_WIDTH],
                     sched_data[0 +: DATA_WIDTH]};
    assign fifo1_in={sched_packet_length[31:16],sched_packet_sequence[63:32],
                     sched_eop[1],sched_sop[1],sched_keep[KEEP_WIDTH +: KEEP_WIDTH],
                     sched_data[DATA_WIDTH +: DATA_WIDTH]};

    bonded_async_fifo #(.DATA_WIDTH(META_WIDTH),.DEPTH(FIFO_DEPTH)) lane0_fifo (
        .wr_clk(bond_clk),.wr_rst_n(bond_rst_n && lane0_rst_n),
        .wr_valid(sched_valid[0]),.wr_ready(fifo0_wr_ready),.wr_data(fifo0_in),
        .rd_clk(lane0_clk),.rd_rst_n(bond_rst_n && lane0_rst_n),
        .rd_valid(fifo0_rd_valid),.rd_ready(enc0_in_ready),.rd_data(fifo0_out)
    );
    bonded_async_fifo #(.DATA_WIDTH(META_WIDTH),.DEPTH(FIFO_DEPTH)) lane1_fifo (
        .wr_clk(bond_clk),.wr_rst_n(bond_rst_n && lane1_rst_n),
        .wr_valid(sched_valid[1]),.wr_ready(fifo1_wr_ready),.wr_data(fifo1_in),
        .rd_clk(lane1_clk),.rd_rst_n(bond_rst_n && lane1_rst_n),
        .rd_valid(fifo1_rd_valid),.rd_ready(enc1_in_ready),.rd_data(fifo1_out)
    );

    bonded_wire_tx_lane #(.DATA_WIDTH(DATA_WIDTH),.KEEP_WIDTH(KEEP_WIDTH),.LANE_ID(LANE0_ID)) encoder0 (
        .clk(lane0_clk),.rst(!bond_rst_n || !lane0_rst_n),.session_id(session_id),
        .in_valid(fifo0_rd_valid),.in_ready(enc0_in_ready),
        .in_data(fifo0_out[DATA_WIDTH-1:0]),
        .in_keep(fifo0_out[DATA_WIDTH +: KEEP_WIDTH]),
        .in_sop(fifo0_out[DATA_WIDTH+KEEP_WIDTH]),
        .in_eop(fifo0_out[DATA_WIDTH+KEEP_WIDTH+1]),
        .in_packet_sequence(fifo0_out[DATA_WIDTH+KEEP_WIDTH+2 +: 32]),
        .in_packet_length(fifo0_out[DATA_WIDTH+KEEP_WIDTH+34 +: 16]),
        .out_valid(lane0_valid),.out_ready(lane0_ready),.out_data(lane0_data),
        .out_sop(lane0_sop),.out_eop(lane0_eop),
        .next_frame_sequence(lane0_frame_sequence),.frame_error(lane0_frame_error)
    );
    bonded_wire_tx_lane #(.DATA_WIDTH(DATA_WIDTH),.KEEP_WIDTH(KEEP_WIDTH),.LANE_ID(LANE1_ID)) encoder1 (
        .clk(lane1_clk),.rst(!bond_rst_n || !lane1_rst_n),.session_id(session_id),
        .in_valid(fifo1_rd_valid),.in_ready(enc1_in_ready),
        .in_data(fifo1_out[DATA_WIDTH-1:0]),
        .in_keep(fifo1_out[DATA_WIDTH +: KEEP_WIDTH]),
        .in_sop(fifo1_out[DATA_WIDTH+KEEP_WIDTH]),
        .in_eop(fifo1_out[DATA_WIDTH+KEEP_WIDTH+1]),
        .in_packet_sequence(fifo1_out[DATA_WIDTH+KEEP_WIDTH+2 +: 32]),
        .in_packet_length(fifo1_out[DATA_WIDTH+KEEP_WIDTH+34 +: 16]),
        .out_valid(lane1_valid),.out_ready(lane1_ready),.out_data(lane1_data),
        .out_sop(lane1_sop),.out_eop(lane1_eop),
        .next_frame_sequence(lane1_frame_sequence),.frame_error(lane1_frame_error)
    );
endmodule
