// SPDX-License-Identifier: BSD-2-Clause
// Two-lane end-to-end receive integration:
// recovered-clock wire decoders -> per-lane async FIFOs -> common-clock
// global packet reordering -> logical byte stream.
module bonded_two_lane_rx #(
    parameter integer FIFO_DEPTH = 64,
    parameter integer REORDER_WINDOW = 4,
    parameter integer MAX_PACKET_BYTES = 4096,
    parameter integer LANE0_ID = 0,
    parameter integer LANE1_ID = 1
) (
    input wire bond_rst_n,
    input wire [63:0] expected_session_id,

    input wire lane0_clk, input wire lane0_rst_n,
    input wire lane0_valid, output wire lane0_ready,
    input wire [7:0] lane0_data, input wire lane0_sop, input wire lane0_eop,

    input wire lane1_clk, input wire lane1_rst_n,
    input wire lane1_valid, output wire lane1_ready,
    input wire [7:0] lane1_data, input wire lane1_sop, input wire lane1_eop,

    input wire bond_clk,
    output wire out_valid, input wire out_ready,
    output wire [7:0] out_data, output wire out_sop, output wire out_eop,
    output wire [31:0] out_packet_sequence,

    output wire lane0_frame_error, output wire lane1_frame_error,
    output wire packet_error
);
    localparam integer CDC_WIDTH = 42;
    wire rx0_valid, rx0_ready, rx0_sop, rx0_eop;
    wire [7:0] rx0_data;
    wire [31:0] rx0_packet_seq, rx0_frame_seq, rx0_expected_frame;
    wire rx0_frame_pulse;
    wire rx1_valid, rx1_ready, rx1_sop, rx1_eop;
    wire [7:0] rx1_data;
    wire [31:0] rx1_packet_seq, rx1_frame_seq, rx1_expected_frame;
    wire rx1_frame_pulse;

    bonded_wire_rx_lane #(.LANE_ID(LANE0_ID),.MAX_PAYLOAD(MAX_PACKET_BYTES)) lane0_decoder (
        .clk(lane0_clk), .rst(!bond_rst_n || !lane0_rst_n),
        .expected_session_id(expected_session_id),
        .in_valid(lane0_valid), .in_ready(lane0_ready), .in_data(lane0_data),
        .in_sop(lane0_sop), .in_eop(lane0_eop),
        .out_valid(rx0_valid), .out_ready(rx0_ready), .out_data(rx0_data),
        .out_sop(rx0_sop), .out_eop(rx0_eop),
        .out_packet_sequence(rx0_packet_seq), .out_frame_sequence(rx0_frame_seq),
        .expected_frame_sequence(rx0_expected_frame),
        .frame_error(lane0_frame_error), .frame_valid_pulse(rx0_frame_pulse)
    );

    bonded_wire_rx_lane #(.LANE_ID(LANE1_ID),.MAX_PAYLOAD(MAX_PACKET_BYTES)) lane1_decoder (
        .clk(lane1_clk), .rst(!bond_rst_n || !lane1_rst_n),
        .expected_session_id(expected_session_id),
        .in_valid(lane1_valid), .in_ready(lane1_ready), .in_data(lane1_data),
        .in_sop(lane1_sop), .in_eop(lane1_eop),
        .out_valid(rx1_valid), .out_ready(rx1_ready), .out_data(rx1_data),
        .out_sop(rx1_sop), .out_eop(rx1_eop),
        .out_packet_sequence(rx1_packet_seq), .out_frame_sequence(rx1_frame_seq),
        .expected_frame_sequence(rx1_expected_frame),
        .frame_error(lane1_frame_error), .frame_valid_pulse(rx1_frame_pulse)
    );

    wire cdc0_valid, cdc0_ready, cdc1_valid, cdc1_ready;
    wire [CDC_WIDTH-1:0] cdc0_data, cdc1_data;
    bonded_two_lane_cdc #(.DATA_WIDTH(CDC_WIDTH),.FIFO_DEPTH(FIFO_DEPTH)) lane_cdc (
        .bond_rst_n(bond_rst_n),
        .lane0_clk(lane0_clk), .lane0_rst_n(lane0_rst_n),
        .lane0_valid(rx0_valid), .lane0_ready(rx0_ready),
        .lane0_data({rx0_packet_seq,rx0_eop,rx0_sop,rx0_data}),
        .lane1_clk(lane1_clk), .lane1_rst_n(lane1_rst_n),
        .lane1_valid(rx1_valid), .lane1_ready(rx1_ready),
        .lane1_data({rx1_packet_seq,rx1_eop,rx1_sop,rx1_data}),
        .bond_clk(bond_clk),
        .bond_lane0_valid(cdc0_valid), .bond_lane0_ready(cdc0_ready), .bond_lane0_data(cdc0_data),
        .bond_lane1_valid(cdc1_valid), .bond_lane1_ready(cdc1_ready), .bond_lane1_data(cdc1_data)
    );

    wire [1:0] reorder_valid = {cdc1_valid,cdc0_valid};
    wire [1:0] reorder_ready;
    wire [15:0] reorder_data = {cdc1_data[7:0],cdc0_data[7:0]};
    wire [1:0] reorder_sop = {cdc1_data[8],cdc0_data[8]};
    wire [1:0] reorder_eop = {cdc1_data[9],cdc0_data[9]};
    wire [63:0] reorder_sequence = {cdc1_data[41:10],cdc0_data[41:10]};

    assign cdc0_ready = reorder_ready[0];
    assign cdc1_ready = reorder_ready[1];

    bonded_packet_rx #(
        .LANE_COUNT(2), .WINDOW_SIZE(REORDER_WINDOW),
        .MAX_PACKET_BYTES(MAX_PACKET_BYTES)
    ) packet_reorder (
        .clk(bond_clk), .rst(!bond_rst_n),
        .lane_valid(reorder_valid), .lane_ready(reorder_ready),
        .lane_data(reorder_data), .lane_sop(reorder_sop), .lane_eop(reorder_eop),
        .lane_packet_sequence(reorder_sequence),
        .out_valid(out_valid), .out_ready(out_ready), .out_data(out_data),
        .out_sop(out_sop), .out_eop(out_eop),
        .out_packet_sequence(out_packet_sequence),
        .expected_packet_sequence(), .packet_error(packet_error)
    );
endmodule
