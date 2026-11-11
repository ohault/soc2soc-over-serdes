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
    output wire ctrl_rx_valid, input wire ctrl_rx_ready,
    output wire [207:0] ctrl_rx_body, output wire [5:0] ctrl_rx_body_length,
    output wire ctrl_rx_lane,
    output wire [63:0] local_byte_limit,
    output wire [31:0] local_packet_limit,
    output wire credit_error,
    output wire out_valid, input wire out_ready,
    output wire [7:0] out_data, output wire out_sop, output wire out_eop,
    output wire [31:0] out_packet_sequence,

    output wire lane0_frame_error, output wire lane1_frame_error,
    output wire packet_error
);
    localparam integer CDC_WIDTH = 42;
    wire data0_valid,data0_ready,data0_sop,data0_eop;
    wire [7:0] data0_data;
    wire ctrl0_stream_valid,ctrl0_stream_ready,ctrl0_stream_sop,ctrl0_stream_eop;
    wire [7:0] ctrl0_stream_data;
    wire ctrl0_message_valid,ctrl0_message_ready;
    wire [207:0] ctrl0_message_body;
    wire [5:0] ctrl0_message_length;
    wire [31:0] ctrl0_frame_seq,ctrl0_expected_seq;
    wire ctrl0_demux_error,ctrl0_frame_error;
    wire rx0_valid, rx0_ready, rx0_sop, rx0_eop;
    wire [7:0] rx0_data;
    wire [31:0] rx0_packet_seq, rx0_frame_seq, rx0_expected_frame;
    wire rx0_frame_pulse;
    wire data1_valid,data1_ready,data1_sop,data1_eop;
    wire [7:0] data1_data;
    wire ctrl1_stream_valid,ctrl1_stream_ready,ctrl1_stream_sop,ctrl1_stream_eop;
    wire [7:0] ctrl1_stream_data;
    wire ctrl1_message_valid,ctrl1_message_ready;
    wire [207:0] ctrl1_message_body;
    wire [5:0] ctrl1_message_length;
    wire [31:0] ctrl1_frame_seq,ctrl1_expected_seq;
    wire ctrl1_demux_error,ctrl1_frame_error;
    wire rx1_valid, rx1_ready, rx1_sop, rx1_eop;
    wire [7:0] rx1_data;
    wire [31:0] rx1_packet_seq, rx1_frame_seq, rx1_expected_frame;
    wire rx1_frame_pulse;

    bonded_wire_rx_demux demux0 (
        .clk(lane0_clk),.rst(!bond_rst_n || !lane0_rst_n),
        .in_valid(lane0_valid),.in_ready(lane0_ready),.in_data(lane0_data),
        .in_sop(lane0_sop),.in_eop(lane0_eop),
        .data_valid(data0_valid),.data_ready(data0_ready),.data_data(data0_data),
        .data_sop(data0_sop),.data_eop(data0_eop),
        .ctrl_valid(ctrl0_stream_valid),.ctrl_ready(ctrl0_stream_ready),.ctrl_data(ctrl0_stream_data),
        .ctrl_sop(ctrl0_stream_sop),.ctrl_eop(ctrl0_stream_eop),.frame_error(ctrl0_demux_error)
    );
    bonded_wire_rx_demux demux1 (
        .clk(lane1_clk),.rst(!bond_rst_n || !lane1_rst_n),
        .in_valid(lane1_valid),.in_ready(lane1_ready),.in_data(lane1_data),
        .in_sop(lane1_sop),.in_eop(lane1_eop),
        .data_valid(data1_valid),.data_ready(data1_ready),.data_data(data1_data),
        .data_sop(data1_sop),.data_eop(data1_eop),
        .ctrl_valid(ctrl1_stream_valid),.ctrl_ready(ctrl1_stream_ready),.ctrl_data(ctrl1_stream_data),
        .ctrl_sop(ctrl1_stream_sop),.ctrl_eop(ctrl1_stream_eop),.frame_error(ctrl1_demux_error)
    );

    bonded_wire_rx_lane #(.LANE_ID(LANE0_ID),.MAX_PAYLOAD(MAX_PACKET_BYTES)) lane0_decoder (
        .clk(lane0_clk), .rst(!bond_rst_n || !lane0_rst_n),
        .expected_session_id(expected_session_id),
        .in_valid(data0_valid), .in_ready(data0_ready), .in_data(data0_data),
        .in_sop(data0_sop), .in_eop(data0_eop),
        .out_valid(rx0_valid), .out_ready(rx0_ready), .out_data(rx0_data),
        .out_sop(rx0_sop), .out_eop(rx0_eop),
        .out_packet_sequence(rx0_packet_seq), .out_frame_sequence(rx0_frame_seq),
        .expected_frame_sequence(rx0_expected_frame),
        .frame_error(lane0_frame_error), .frame_valid_pulse(rx0_frame_pulse)
    );
    bonded_control_frame_rx #(.LANE_ID(LANE0_ID)) control_decoder0 (
        .clk(lane0_clk),.rst(!bond_rst_n || !lane0_rst_n),.expected_session_id(expected_session_id),
        .in_valid(ctrl0_stream_valid),.in_ready(ctrl0_stream_ready),.in_data(ctrl0_stream_data),
        .in_sop(ctrl0_stream_sop),.in_eop(ctrl0_stream_eop),
        .ctrl_valid(ctrl0_message_valid),.ctrl_ready(ctrl0_message_ready),
        .ctrl_body(ctrl0_message_body),.ctrl_body_length(ctrl0_message_length),
        .received_frame_sequence(ctrl0_frame_seq),.expected_frame_sequence(ctrl0_expected_seq),
        .frame_error(ctrl0_frame_error)
    );

    bonded_wire_rx_lane #(.LANE_ID(LANE1_ID),.MAX_PAYLOAD(MAX_PACKET_BYTES)) lane1_decoder (
        .clk(lane1_clk), .rst(!bond_rst_n || !lane1_rst_n),
        .expected_session_id(expected_session_id),
        .in_valid(data1_valid), .in_ready(data1_ready), .in_data(data1_data),
        .in_sop(data1_sop), .in_eop(data1_eop),
        .out_valid(rx1_valid), .out_ready(rx1_ready), .out_data(rx1_data),
        .out_sop(rx1_sop), .out_eop(rx1_eop),
        .out_packet_sequence(rx1_packet_seq), .out_frame_sequence(rx1_frame_seq),
        .expected_frame_sequence(rx1_expected_frame),
        .frame_error(lane1_frame_error), .frame_valid_pulse(rx1_frame_pulse)
    );
    bonded_control_frame_rx #(.LANE_ID(LANE1_ID)) control_decoder1 (
        .clk(lane1_clk),.rst(!bond_rst_n || !lane1_rst_n),.expected_session_id(expected_session_id),
        .in_valid(ctrl1_stream_valid),.in_ready(ctrl1_stream_ready),.in_data(ctrl1_stream_data),
        .in_sop(ctrl1_stream_sop),.in_eop(ctrl1_stream_eop),
        .ctrl_valid(ctrl1_message_valid),.ctrl_ready(ctrl1_message_ready),
        .ctrl_body(ctrl1_message_body),.ctrl_body_length(ctrl1_message_length),
        .received_frame_sequence(ctrl1_frame_seq),.expected_frame_sequence(ctrl1_expected_seq),
        .frame_error(ctrl1_frame_error)
    );

    wire [214:0] ctrl0_cdc_data,ctrl1_cdc_data;
    wire ctrl0_cdc_valid,ctrl1_cdc_valid,ctrl0_cdc_ready,ctrl1_cdc_ready;
    bonded_async_fifo #(.DATA_WIDTH(215),.DEPTH(FIFO_DEPTH)) control_cdc0 (
        .wr_clk(lane0_clk),.wr_rst_n(bond_rst_n && lane0_rst_n),
        .wr_valid(ctrl0_message_valid),.wr_ready(ctrl0_message_ready),
        .wr_data({1'b0,ctrl0_message_length,ctrl0_message_body}),
        .rd_clk(bond_clk),.rd_rst_n(bond_rst_n),
        .rd_valid(ctrl0_cdc_valid),.rd_ready(ctrl0_cdc_ready),.rd_data(ctrl0_cdc_data)
    );
    bonded_async_fifo #(.DATA_WIDTH(215),.DEPTH(FIFO_DEPTH)) control_cdc1 (
        .wr_clk(lane1_clk),.wr_rst_n(bond_rst_n && lane1_rst_n),
        .wr_valid(ctrl1_message_valid),.wr_ready(ctrl1_message_ready),
        .wr_data({1'b1,ctrl1_message_length,ctrl1_message_body}),
        .rd_clk(bond_clk),.rd_rst_n(bond_rst_n),
        .rd_valid(ctrl1_cdc_valid),.rd_ready(ctrl1_cdc_ready),.rd_data(ctrl1_cdc_data)
    );
    reg control_rr;
    wire select_ctrl1 = ctrl1_cdc_valid && (!ctrl0_cdc_valid || control_rr);
    assign ctrl_rx_valid = ctrl0_cdc_valid || ctrl1_cdc_valid;
    assign ctrl_rx_body = select_ctrl1 ? ctrl1_cdc_data[207:0] : ctrl0_cdc_data[207:0];
    assign ctrl_rx_body_length = select_ctrl1 ? ctrl1_cdc_data[213:208] : ctrl0_cdc_data[213:208];
    assign ctrl_rx_lane = select_ctrl1;
    assign ctrl0_cdc_ready = ctrl_rx_valid && !select_ctrl1 && ctrl_rx_ready;
    assign ctrl1_cdc_ready = ctrl_rx_valid && select_ctrl1 && ctrl_rx_ready;
    always @(posedge bond_clk) begin
        if(!bond_rst_n) control_rr<=0;
        else if(ctrl_rx_valid && ctrl_rx_ready) control_rr<=~select_ctrl1;
    end

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

    wire packet_accept_valid, packet_consume_valid;
    wire [15:0] packet_accept_bytes, packet_consume_bytes;
    wire [63:0] tx_reserved_bytes, rx_accepted_bytes, rx_consumed_bytes;
    wire [31:0] tx_reserved_packets, rx_accepted_packets, rx_consumed_packets;
    wire rx_accept_ready;

    bonded_credit_manager #(
        .INITIAL_RX_BYTES(REORDER_WINDOW * MAX_PACKET_BYTES),
        .INITIAL_RX_PACKETS(REORDER_WINDOW)
    ) credit_accounting (
        .clk(bond_clk), .rst(!bond_rst_n),
        .tx_reserve_valid(1'b0), .tx_reserve_bytes(16'd0), .tx_reserve_ready(),
        .remote_byte_limit(64'hffff_ffff_ffff_ffff),
        .remote_packet_limit(32'hffff_ffff),
        .tx_reserved_bytes(tx_reserved_bytes), .tx_reserved_packets(tx_reserved_packets),
        .rx_accept_valid(packet_accept_valid), .rx_accept_bytes(packet_accept_bytes),
        .rx_accept_ready(rx_accept_ready),
        .rx_consume_valid(packet_consume_valid), .rx_consume_bytes(packet_consume_bytes),
        .rx_accepted_bytes(rx_accepted_bytes), .rx_accepted_packets(rx_accepted_packets),
        .rx_consumed_bytes(rx_consumed_bytes), .rx_consumed_packets(rx_consumed_packets),
        .local_byte_limit(local_byte_limit), .local_packet_limit(local_packet_limit),
        .credit_error(credit_error)
    );

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
        .expected_packet_sequence(), .packet_error(packet_error),
        .packet_accept_valid(packet_accept_valid), .packet_accept_bytes(packet_accept_bytes),
        .packet_consume_valid(packet_consume_valid), .packet_consume_bytes(packet_consume_bytes)
    );
endmodule
