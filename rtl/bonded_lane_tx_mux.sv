// SPDX-License-Identifier: BSD-2-Clause
// Complete per-lane TX composition: independent DATA and CONTROL encoders
// feeding a frame-atomic CONTROL-priority arbiter.
module bonded_lane_tx_mux #(
    parameter integer DATA_WIDTH = 32,
    parameter integer KEEP_WIDTH = DATA_WIDTH/8,
    parameter integer LANE_ID = 0
) (
    input wire clk,
    input wire rst,
    input wire [63:0] session_id,

    input wire ctrl_valid,
    output wire ctrl_ready,
    input wire [207:0] ctrl_body,
    input wire [5:0] ctrl_body_length,

    input wire data_valid,
    output wire data_ready,
    input wire [DATA_WIDTH-1:0] data_data,
    input wire [KEEP_WIDTH-1:0] data_keep,
    input wire data_sop,
    input wire data_eop,
    input wire [31:0] data_packet_sequence,
    input wire [15:0] data_packet_length,

    output wire out_valid,
    input wire out_ready,
    output wire [7:0] out_data,
    output wire out_sop,
    output wire out_eop,

    output wire [31:0] data_frame_sequence,
    output wire [31:0] control_frame_sequence,
    output wire data_frame_error,
    output wire control_frame_error,
    output wire arbiter_protocol_error
);
    wire ctrl_frame_valid, ctrl_frame_ready, ctrl_frame_sop, ctrl_frame_eop;
    wire [7:0] ctrl_frame_data;
    wire data_frame_valid, data_frame_ready, data_frame_sop, data_frame_eop;
    wire [7:0] data_frame_data;

    bonded_control_frame_tx #(.LANE_ID(LANE_ID)) control_encoder (
        .clk(clk), .rst(rst), .session_id(session_id),
        .ctrl_valid(ctrl_valid), .ctrl_ready(ctrl_ready),
        .ctrl_body(ctrl_body), .ctrl_body_length(ctrl_body_length),
        .out_valid(ctrl_frame_valid), .out_ready(ctrl_frame_ready),
        .out_data(ctrl_frame_data), .out_sop(ctrl_frame_sop), .out_eop(ctrl_frame_eop),
        .next_frame_sequence(control_frame_sequence), .frame_error(control_frame_error)
    );

    bonded_wire_tx_lane #(
        .DATA_WIDTH(DATA_WIDTH), .KEEP_WIDTH(KEEP_WIDTH), .LANE_ID(LANE_ID)
    ) data_encoder (
        .clk(clk), .rst(rst), .session_id(session_id),
        .in_valid(data_valid), .in_ready(data_ready),
        .in_data(data_data), .in_keep(data_keep), .in_sop(data_sop), .in_eop(data_eop),
        .in_packet_sequence(data_packet_sequence), .in_packet_length(data_packet_length),
        .out_valid(data_frame_valid), .out_ready(data_frame_ready),
        .out_data(data_frame_data), .out_sop(data_frame_sop), .out_eop(data_frame_eop),
        .next_frame_sequence(data_frame_sequence), .frame_error(data_frame_error)
    );

    bonded_lane_frame_arbiter arbiter (
        .clk(clk), .rst(rst),
        .ctrl_valid(ctrl_frame_valid), .ctrl_ready(ctrl_frame_ready),
        .ctrl_data(ctrl_frame_data), .ctrl_sop(ctrl_frame_sop), .ctrl_eop(ctrl_frame_eop),
        .data_valid(data_frame_valid), .data_ready(data_frame_ready),
        .data_data(data_frame_data), .data_sop(data_frame_sop), .data_eop(data_frame_eop),
        .out_valid(out_valid), .out_ready(out_ready),
        .out_data(out_data), .out_sop(out_sop), .out_eop(out_eop),
        .protocol_error(arbiter_protocol_error)
    );
endmodule
