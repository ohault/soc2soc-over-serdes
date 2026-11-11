// SPDX-License-Identifier: BSD-2-Clause
// Autonomous two-lane bonded node: endpoint datapaths plus RTL control manager.
// v0 session ID is provisioned identically at both peers.
module bonded_two_lane_node #(
    parameter integer DATA_WIDTH=32,
    parameter integer KEEP_WIDTH=DATA_WIDTH/8,
    parameter integer TX_FIFO_DEPTH=64,
    parameter integer RX_FIFO_DEPTH=64,
    parameter integer RX_ELASTIC_DEPTH=64,
    parameter integer REORDER_WINDOW=4,
    parameter integer MAX_PACKET_BYTES=4096,
    parameter integer LANE0_ID=0,
    parameter integer LANE1_ID=1,
    parameter [63:0] SESSION_ID=64'h1,
    parameter [63:0] LOCAL_PEER_ID=64'd1,
    parameter [63:0] EXPECTED_PEER_ID=64'd2,
    parameter [15:0] PROFILE_ID=16'd1,
    parameter [15:0] MAX_PAYLOAD=MAX_PACKET_BYTES,
    parameter [31:0] PING_INTERVAL_CYCLES=32'd100000000,
    parameter [31:0] PONG_TIMEOUT_CYCLES=32'd300000000
) (
    input wire bond_clk,
    input wire bond_rst_n,
    input wire lane0_up,
    input wire lane1_up,

    input wire lane0_tx_clk,input wire lane0_tx_rst_n,
    output wire lane0_tx_valid,input wire lane0_tx_ready,
    output wire [7:0] lane0_tx_data,
    output wire lane0_tx_sop, output wire lane0_tx_eop,
    input wire lane1_tx_clk,input wire lane1_tx_rst_n,
    output wire lane1_tx_valid,input wire lane1_tx_ready,
    output wire [7:0] lane1_tx_data,
    output wire lane1_tx_sop, output wire lane1_tx_eop,

    input wire lane0_rx_clk,input wire lane0_rx_rst_n,
    input wire lane0_rx_valid,output wire lane0_rx_ready,
    input wire [7:0] lane0_rx_data,
    // Sticky adapter overrun level; hold until bond_rst_n is asserted.
    input wire lane0_rx_overflow,
    input wire lane1_rx_clk,input wire lane1_rx_rst_n,
    input wire lane1_rx_valid,output wire lane1_rx_ready,
    input wire [7:0] lane1_rx_data,
    // Sticky adapter overrun level; hold until bond_rst_n is asserted.
    input wire lane1_rx_overflow,

    input wire tx_valid,output wire tx_ready,
    input wire [DATA_WIDTH-1:0] tx_data,
    input wire [KEEP_WIDTH-1:0] tx_keep,
    input wire tx_sop,input wire tx_eop,

    output wire rx_valid,input wire rx_ready,
    output wire [7:0] rx_data,output wire rx_sop,output wire rx_eop,
    output wire [31:0] rx_packet_sequence,

    output wire session_active,
    output wire control_fault,
    output wire rx_credit_error,
    output wire tx_packet_error,
    output wire rx_packet_error,
    output wire lane0_tx_frame_error,output wire lane1_tx_frame_error,
    output wire lane0_rx_frame_error,output wire lane1_rx_frame_error
);
    initial begin
        if(SESSION_ID==0) $error("v0 SESSION_ID must be non-zero");
        if(LOCAL_PEER_ID==EXPECTED_PEER_ID) $error("local and expected peer IDs must differ");
        if(MAX_PAYLOAD!=MAX_PACKET_BYTES) $error("v0 peer payload limit must match MAX_PACKET_BYTES");
    end

    (* async_reg = "true" *) reg [1:0] lane_up_sync1,lane_up_sync2;
    (* async_reg = "true" *) reg [1:0] lane_rx_error_sync1,lane_rx_error_sync2;
    (* async_reg = "true" *) reg [1:0] lane_tx_error_sync1,lane_tx_error_sync2;
    always @(posedge bond_clk or negedge bond_rst_n) begin
        if(!bond_rst_n) begin
            lane_up_sync1<=0;lane_up_sync2<=0;
            lane_rx_error_sync1<=0;lane_rx_error_sync2<=0;
            lane_tx_error_sync1<=0;lane_tx_error_sync2<=0;
        end else begin
            lane_up_sync1<={lane1_up,lane0_up};
            lane_up_sync2<=lane_up_sync1;
            lane_rx_error_sync1<={lane1_rx_frame_error,lane0_rx_frame_error};
            lane_rx_error_sync2<=lane_rx_error_sync1;
            lane_tx_error_sync1<={lane1_tx_frame_error,lane0_tx_frame_error};
            lane_tx_error_sync2<=lane_tx_error_sync1;
        end
    end
    wire [1:0] lane_up=lane_up_sync2 & ~lane_rx_error_sync2 & ~lane_tx_error_sync2;

    // Convert a bonding-clock session drop into one reset pulse in each
    // recovered RX clock domain. CONTROL negotiation remains alive.
    reg session_active_d,session_drop_toggle;
    always @(posedge bond_clk or negedge bond_rst_n) begin
        if(!bond_rst_n) begin
            session_active_d<=1'b0;
            session_drop_toggle<=1'b0;
        end else begin
            session_active_d<=session_active;
            if(session_active_d && !session_active)
                session_drop_toggle<=~session_drop_toggle;
        end
    end

    wire lane0_rx_base_rst_n=bond_rst_n && lane0_rx_rst_n;
    wire lane1_rx_base_rst_n=bond_rst_n && lane1_rx_rst_n;
    (* async_reg = "true" *) reg [1:0] lane0_drop_sync,lane1_drop_sync;
    reg lane0_drop_seen,lane1_drop_seen;
    wire lane0_session_drop_pulse=(lane0_drop_sync[1]!=lane0_drop_seen);
    wire lane1_session_drop_pulse=(lane1_drop_sync[1]!=lane1_drop_seen);
    always @(posedge lane0_rx_clk or negedge lane0_rx_base_rst_n) begin
        if(!lane0_rx_base_rst_n) begin lane0_drop_sync<=0;lane0_drop_seen<=0;end
        else begin
            lane0_drop_sync<={lane0_drop_sync[0],session_drop_toggle};
            if(lane0_session_drop_pulse) lane0_drop_seen<=lane0_drop_sync[1];
        end
    end
    always @(posedge lane1_rx_clk or negedge lane1_rx_base_rst_n) begin
        if(!lane1_rx_base_rst_n) begin lane1_drop_sync<=0;lane1_drop_seen<=0;end
        else begin
            lane1_drop_sync<={lane1_drop_sync[0],session_drop_toggle};
            if(lane1_session_drop_pulse) lane1_drop_seen<=lane1_drop_sync[1];
        end
    end
    wire lane0_rx_local_reset=!lane0_rx_base_rst_n || lane0_session_drop_pulse;
    wire lane1_rx_local_reset=!lane1_rx_base_rst_n || lane1_session_drop_pulse;
    wire ctrl_tx_valid,ctrl_tx_ready,ctrl_rx_valid,ctrl_rx_ready,ctrl_rx_lane;
    wire [207:0] ctrl_tx_body,ctrl_rx_body;
    wire [5:0] ctrl_tx_length,ctrl_rx_length;
    wire [63:0] local_byte_limit,remote_byte_limit;
    wire [31:0] local_packet_limit,remote_packet_limit;
    wire session_established;
    wire [31:0] lane0_tx_seq,lane1_tx_seq;
    wire lane0_tx_sop_internal,lane0_tx_eop_internal,lane1_tx_sop_internal,lane1_tx_eop_internal;
    wire lane0_framed_valid,lane0_framed_ready,lane0_framed_sop,lane0_framed_eop;
    wire lane1_framed_valid,lane1_framed_ready,lane1_framed_sop,lane1_framed_eop;
    wire [7:0] lane0_framed_data,lane1_framed_data;
    wire lane0_framer_error,lane1_framer_error;
    wire lane0_raw_valid,lane0_raw_ready,lane1_raw_valid,lane1_raw_ready;
    wire [7:0] lane0_raw_data,lane1_raw_data;

    bonded_sync_byte_fifo #(.DEPTH(RX_ELASTIC_DEPTH)) lane0_rx_elastic (
        .clk(lane0_rx_clk),.rst(lane0_rx_local_reset),
        .in_valid(lane0_rx_valid),.in_ready(lane0_rx_ready),.in_data(lane0_rx_data),
        .out_valid(lane0_raw_valid),.out_ready(lane0_raw_ready),.out_data(lane0_raw_data),
        .full(),.empty()
    );
    bonded_sync_byte_fifo #(.DEPTH(RX_ELASTIC_DEPTH)) lane1_rx_elastic (
        .clk(lane1_rx_clk),.rst(lane1_rx_local_reset),
        .in_valid(lane1_rx_valid),.in_ready(lane1_rx_ready),.in_data(lane1_rx_data),
        .out_valid(lane1_raw_valid),.out_ready(lane1_raw_ready),.out_data(lane1_raw_data),
        .full(),.empty()
    );
    wire lane0_endpoint_rx_error,lane1_endpoint_rx_error;

    bonded_wire_rx_framer #(.MAX_FRAME_BODY(MAX_PACKET_BYTES+4)) lane0_framer (
        .clk(lane0_rx_clk),.rst(lane0_rx_local_reset),
        .in_valid(lane0_raw_valid),.in_ready(lane0_raw_ready),.in_data(lane0_raw_data),
        .out_valid(lane0_framed_valid),.out_ready(lane0_framed_ready),
        .out_data(lane0_framed_data),.out_sop(lane0_framed_sop),.out_eop(lane0_framed_eop),
        .frame_error(lane0_framer_error)
    );
    bonded_wire_rx_framer #(.MAX_FRAME_BODY(MAX_PACKET_BYTES+4)) lane1_framer (
        .clk(lane1_rx_clk),.rst(lane1_rx_local_reset),
        .in_valid(lane1_raw_valid),.in_ready(lane1_raw_ready),.in_data(lane1_raw_data),
        .out_valid(lane1_framed_valid),.out_ready(lane1_framed_ready),
        .out_data(lane1_framed_data),.out_sop(lane1_framed_sop),.out_eop(lane1_framed_eop),
        .frame_error(lane1_framer_error)
    );

    bonded_control_manager #(
        .LOCAL_PEER_ID(LOCAL_PEER_ID),.EXPECTED_PEER_ID(EXPECTED_PEER_ID),
        .PROFILE_ID(PROFILE_ID),.MAX_PAYLOAD(MAX_PAYLOAD),
        .PING_INTERVAL_CYCLES(PING_INTERVAL_CYCLES),
        .PONG_TIMEOUT_CYCLES(PONG_TIMEOUT_CYCLES)
    ) control_manager (
        .clk(bond_clk),.rst(!bond_rst_n),.lane_up(lane_up),
        .ctrl_rx_valid(ctrl_rx_valid),.ctrl_rx_ready(ctrl_rx_ready),
        .ctrl_rx_body(ctrl_rx_body),.ctrl_rx_body_length(ctrl_rx_length),.ctrl_rx_lane(ctrl_rx_lane),
        .ctrl_tx_valid(ctrl_tx_valid),.ctrl_tx_ready(ctrl_tx_ready),
        .ctrl_tx_body(ctrl_tx_body),.ctrl_tx_body_length(ctrl_tx_length),
        .local_byte_limit(local_byte_limit),.local_packet_limit(local_packet_limit),
        .remote_byte_limit(remote_byte_limit),.remote_packet_limit(remote_packet_limit),
        .session_established(session_established),.fault(control_fault)
    );

    bonded_two_lane_endpoint #(
        .DATA_WIDTH(DATA_WIDTH),.KEEP_WIDTH(KEEP_WIDTH),
        .TX_FIFO_DEPTH(TX_FIFO_DEPTH),.RX_FIFO_DEPTH(RX_FIFO_DEPTH),
        .REORDER_WINDOW(REORDER_WINDOW),.MAX_PACKET_BYTES(MAX_PACKET_BYTES),
        .LANE0_ID(LANE0_ID),.LANE1_ID(LANE1_ID),.DYNAMIC_LANE_MAP(1)
    ) endpoint (
        .bond_clk(bond_clk),.bond_rst_n(bond_rst_n),
        .tx_session_id(SESSION_ID),.rx_expected_session_id(SESSION_ID),
        .remote_byte_limit(remote_byte_limit),.remote_packet_limit(remote_packet_limit),
        .ctrl_tx_valid(ctrl_tx_valid),.ctrl_tx_ready(ctrl_tx_ready),
        .ctrl_tx_body(ctrl_tx_body),.ctrl_tx_body_length(ctrl_tx_length),
        .session_established(session_established),.session_active(session_active),
        .local_byte_limit(local_byte_limit),.local_packet_limit(local_packet_limit),
        .rx_credit_error(rx_credit_error),
        .ctrl_rx_valid(ctrl_rx_valid),.ctrl_rx_ready(ctrl_rx_ready),
        .ctrl_rx_body(ctrl_rx_body),.ctrl_rx_body_length(ctrl_rx_length),.ctrl_rx_lane(ctrl_rx_lane),
        .tx_valid(tx_valid),.tx_ready(tx_ready),.tx_data(tx_data),.tx_keep(tx_keep),
        .tx_sop(tx_sop),.tx_eop(tx_eop),
        .rx_valid(rx_valid),.rx_ready(rx_ready),.rx_data(rx_data),
        .rx_sop(rx_sop),.rx_eop(rx_eop),.rx_packet_sequence(rx_packet_sequence),
        .lane0_tx_clk(lane0_tx_clk),.lane0_tx_rst_n(lane0_tx_rst_n),
        .lane0_tx_valid(lane0_tx_valid),.lane0_tx_ready(lane0_tx_ready),
        .lane0_tx_data(lane0_tx_data),.lane0_tx_sop(lane0_tx_sop_internal),.lane0_tx_eop(lane0_tx_eop_internal),
        .lane1_tx_clk(lane1_tx_clk),.lane1_tx_rst_n(lane1_tx_rst_n),
        .lane1_tx_valid(lane1_tx_valid),.lane1_tx_ready(lane1_tx_ready),
        .lane1_tx_data(lane1_tx_data),.lane1_tx_sop(lane1_tx_sop_internal),.lane1_tx_eop(lane1_tx_eop_internal),
        .lane0_rx_clk(lane0_rx_clk),.lane0_rx_rst_n(lane0_rx_rst_n),
        .lane0_rx_valid(lane0_framed_valid),.lane0_rx_ready(lane0_framed_ready),
        .lane0_rx_data(lane0_framed_data),.lane0_rx_sop(lane0_framed_sop),.lane0_rx_eop(lane0_framed_eop),
        .lane1_rx_clk(lane1_rx_clk),.lane1_rx_rst_n(lane1_rx_rst_n),
        .lane1_rx_valid(lane1_framed_valid),.lane1_rx_ready(lane1_framed_ready),
        .lane1_rx_data(lane1_framed_data),.lane1_rx_sop(lane1_framed_sop),.lane1_rx_eop(lane1_framed_eop),
        .tx_packet_error(tx_packet_error),
        .lane0_tx_frame_error(lane0_tx_frame_error),.lane1_tx_frame_error(lane1_tx_frame_error),
        .lane0_rx_frame_error(lane0_endpoint_rx_error),.lane1_rx_frame_error(lane1_endpoint_rx_error),
        .rx_packet_error(rx_packet_error),
        .lane0_tx_frame_sequence(lane0_tx_seq),.lane1_tx_frame_sequence(lane1_tx_seq)
    );
    assign lane0_tx_sop = lane0_tx_sop_internal;
    assign lane0_tx_eop = lane0_tx_eop_internal;
    assign lane1_tx_sop = lane1_tx_sop_internal;
    assign lane1_tx_eop = lane1_tx_eop_internal;
    assign lane0_rx_frame_error = lane0_rx_overflow | lane0_framer_error | lane0_endpoint_rx_error;
    assign lane1_rx_frame_error = lane1_rx_overflow | lane1_framer_error | lane1_endpoint_rx_error;
endmodule
