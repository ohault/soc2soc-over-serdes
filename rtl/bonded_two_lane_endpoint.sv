// SPDX-License-Identifier: BSD-2-Clause
// Board- and SoC-neutral full-duplex bonded endpoint.
// TX and RX use independent lane clocks; a physical adapter connects each
// TX byte stream to its peer's corresponding RX byte stream.
module bonded_two_lane_endpoint #(
    parameter integer DATA_WIDTH = 32,
    parameter integer KEEP_WIDTH = DATA_WIDTH/8,
    parameter integer TX_FIFO_DEPTH = 64,
    parameter integer RX_FIFO_DEPTH = 64,
    parameter integer REORDER_WINDOW = 4,
    parameter integer MAX_PACKET_BYTES = 4096,
    parameter integer LANE0_ID = 0,
    parameter integer LANE1_ID = 1
) (
    input wire bond_clk,
    input wire bond_rst_n,
    input wire [63:0] tx_session_id,
    input wire [63:0] rx_expected_session_id,
    input wire [63:0] remote_byte_limit,
    input wire [31:0] remote_packet_limit,
    input wire session_established,
    output wire session_active,
    // Cumulative receive grants to advertise to the peer in CREDIT frames.
    output wire [63:0] local_byte_limit,
    output wire [31:0] local_packet_limit,
    output wire rx_credit_error,

    // Logical application transmit interface (packet stream).
    input wire tx_valid, output wire tx_ready,
    input wire [DATA_WIDTH-1:0] tx_data,
    input wire [KEEP_WIDTH-1:0] tx_keep,
    input wire tx_sop, input wire tx_eop,

    // Logical application receive interface (ordered byte stream).
    output wire rx_valid, input wire rx_ready,
    output wire [7:0] rx_data,
    output wire rx_sop, output wire rx_eop,
    output wire [31:0] rx_packet_sequence,

    // Physical lane 0 transmit byte stream.
    input wire lane0_tx_clk, input wire lane0_tx_rst_n,
    output wire lane0_tx_valid, input wire lane0_tx_ready,
    output wire [7:0] lane0_tx_data,
    output wire lane0_tx_sop, output wire lane0_tx_eop,

    // Physical lane 1 transmit byte stream.
    input wire lane1_tx_clk, input wire lane1_tx_rst_n,
    output wire lane1_tx_valid, input wire lane1_tx_ready,
    output wire [7:0] lane1_tx_data,
    output wire lane1_tx_sop, output wire lane1_tx_eop,

    // Physical lane 0 receive byte stream.
    input wire lane0_rx_clk, input wire lane0_rx_rst_n,
    input wire lane0_rx_valid, output wire lane0_rx_ready,
    input wire [7:0] lane0_rx_data,
    input wire lane0_rx_sop, input wire lane0_rx_eop,

    // Physical lane 1 receive byte stream.
    input wire lane1_rx_clk, input wire lane1_rx_rst_n,
    input wire lane1_rx_valid, output wire lane1_rx_ready,
    input wire [7:0] lane1_rx_data,
    input wire lane1_rx_sop, input wire lane1_rx_eop,

    // Diagnostics. These are sticky/error indications from the datapaths.
    output wire tx_packet_error,
    output wire lane0_tx_frame_error, output wire lane1_tx_frame_error,
    output wire lane0_rx_frame_error, output wire lane1_rx_frame_error,
    output wire rx_packet_error,
    output wire [31:0] lane0_tx_frame_sequence,
    output wire [31:0] lane1_tx_frame_sequence
);
    bonded_session_gate session_gate (
        .bond_clk(bond_clk), .bond_rst_n(bond_rst_n),
        .session_established(session_established),
        .lane0_tx_rst_n(lane0_tx_rst_n), .lane1_tx_rst_n(lane1_tx_rst_n),
        .lane0_rx_rst_n(lane0_rx_rst_n), .lane1_rx_rst_n(lane1_rx_rst_n),
        .session_active(session_active)
    );

    // A loss/reset of any physical direction drops session_active. Feed that
    // condition back into both datapaths so all packet, reorder and FIFO state
    // is flushed as one session, not left partially alive per lane.
    wire datapath_rst_n = bond_rst_n && session_active;
    wire tx_path_ready;
    wire rx_path_valid;
    assign tx_ready = session_active && tx_path_ready;
    assign rx_valid = session_active && rx_path_valid;

    bonded_two_lane_tx #(
        .DATA_WIDTH(DATA_WIDTH), .KEEP_WIDTH(KEEP_WIDTH),
        .FIFO_DEPTH(TX_FIFO_DEPTH), .MAX_PACKET_BYTES(MAX_PACKET_BYTES),
        .LANE0_ID(LANE0_ID), .LANE1_ID(LANE1_ID)
    ) tx_path (
        .bond_clk(bond_clk), .bond_rst_n(datapath_rst_n),
        .session_id(tx_session_id),
        .remote_byte_limit(remote_byte_limit), .remote_packet_limit(remote_packet_limit),
        .tx_valid(tx_valid && session_active), .tx_ready(tx_path_ready), .tx_data(tx_data),
        .tx_keep(tx_keep), .tx_sop(tx_sop), .tx_eop(tx_eop),
        .lane0_clk(lane0_tx_clk), .lane0_rst_n(lane0_tx_rst_n),
        .lane0_valid(lane0_tx_valid), .lane0_ready(lane0_tx_ready),
        .lane0_data(lane0_tx_data), .lane0_sop(lane0_tx_sop), .lane0_eop(lane0_tx_eop),
        .lane1_clk(lane1_tx_clk), .lane1_rst_n(lane1_tx_rst_n),
        .lane1_valid(lane1_tx_valid), .lane1_ready(lane1_tx_ready),
        .lane1_data(lane1_tx_data), .lane1_sop(lane1_tx_sop), .lane1_eop(lane1_tx_eop),
        .packet_error(tx_packet_error),
        .lane0_frame_error(lane0_tx_frame_error),
        .lane1_frame_error(lane1_tx_frame_error),
        .lane0_frame_sequence(lane0_tx_frame_sequence),
        .lane1_frame_sequence(lane1_tx_frame_sequence)
    );

    bonded_two_lane_rx #(
        .FIFO_DEPTH(RX_FIFO_DEPTH), .REORDER_WINDOW(REORDER_WINDOW),
        .MAX_PACKET_BYTES(MAX_PACKET_BYTES),
        .LANE0_ID(LANE0_ID), .LANE1_ID(LANE1_ID)
    ) rx_path (
        .bond_rst_n(datapath_rst_n), .expected_session_id(rx_expected_session_id),
        .lane0_clk(lane0_rx_clk), .lane0_rst_n(lane0_rx_rst_n),
        .lane0_valid(lane0_rx_valid), .lane0_ready(lane0_rx_ready),
        .lane0_data(lane0_rx_data), .lane0_sop(lane0_rx_sop), .lane0_eop(lane0_rx_eop),
        .lane1_clk(lane1_rx_clk), .lane1_rst_n(lane1_rx_rst_n),
        .lane1_valid(lane1_rx_valid), .lane1_ready(lane1_rx_ready),
        .lane1_data(lane1_rx_data), .lane1_sop(lane1_rx_sop), .lane1_eop(lane1_rx_eop),
        .bond_clk(bond_clk),
        .local_byte_limit(local_byte_limit), .local_packet_limit(local_packet_limit),
        .credit_error(rx_credit_error),
        .out_valid(rx_path_valid), .out_ready(rx_ready && session_active), .out_data(rx_data),
        .out_sop(rx_sop), .out_eop(rx_eop),
        .out_packet_sequence(rx_packet_sequence),
        .lane0_frame_error(lane0_rx_frame_error),
        .lane1_frame_error(lane1_rx_frame_error),
        .packet_error(rx_packet_error)
    );
endmodule
