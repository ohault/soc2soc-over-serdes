// SPDX-License-Identifier: BSD-2-Clause
// Board-neutral two-lane node with parallel 8b/10b PHY word boundaries.
// The bonding node remains byte-oriented and SoC-independent. Each lane bridge
// adapts its own TX user clock and recovered RX user clock to the node streams.
module bonded_two_lane_phy_word_node #(
    parameter integer DATA_WIDTH=32,
    parameter integer KEEP_WIDTH=DATA_WIDTH/8,
    parameter integer TX_FIFO_DEPTH=64,
    parameter integer RX_FIFO_DEPTH=64,
    parameter integer RX_ELASTIC_DEPTH=64,
    parameter integer REORDER_WINDOW=4,
    parameter integer MAX_PACKET_BYTES=4096,
    parameter integer SYMBOLS_PER_WORD=4,
    parameter integer PHY_RX_FIFO_DEPTH=16,
    parameter integer RX_PHY_STALLABLE=0,
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
    input wire bond_clk,input wire bond_rst_n,
    input wire lane0_up,input wire lane1_up,

    input wire lane0_tx_clk,input wire lane0_tx_rst_n,
    output wire lane0_phy_tx_valid,input wire lane0_phy_tx_ready,
    output wire [SYMBOLS_PER_WORD*8-1:0] lane0_phy_tx_data,
    output wire [SYMBOLS_PER_WORD-1:0] lane0_phy_tx_ctrl,
    input wire lane0_rx_clk,input wire lane0_rx_rst_n,
    input wire lane0_phy_rx_valid,output wire lane0_phy_rx_ready,
    input wire [SYMBOLS_PER_WORD*8-1:0] lane0_phy_rx_data,
    input wire [SYMBOLS_PER_WORD-1:0] lane0_phy_rx_ctrl,

    input wire lane1_tx_clk,input wire lane1_tx_rst_n,
    output wire lane1_phy_tx_valid,input wire lane1_phy_tx_ready,
    output wire [SYMBOLS_PER_WORD*8-1:0] lane1_phy_tx_data,
    output wire [SYMBOLS_PER_WORD-1:0] lane1_phy_tx_ctrl,
    input wire lane1_rx_clk,input wire lane1_rx_rst_n,
    input wire lane1_phy_rx_valid,output wire lane1_phy_rx_ready,
    input wire [SYMBOLS_PER_WORD*8-1:0] lane1_phy_rx_data,
    input wire [SYMBOLS_PER_WORD-1:0] lane1_phy_rx_ctrl,

    input wire tx_valid,output wire tx_ready,
    input wire [DATA_WIDTH-1:0] tx_data,
    input wire [KEEP_WIDTH-1:0] tx_keep,
    input wire tx_sop,input wire tx_eop,
    output wire rx_valid,input wire rx_ready,
    output wire [7:0] rx_data,output wire rx_sop,output wire rx_eop,
    output wire [31:0] rx_packet_sequence,

    output wire session_active,output wire control_fault,
    output wire rx_credit_error,output wire tx_packet_error,
    output wire rx_packet_error,
    output wire lane0_phy_tx_error,output wire lane1_phy_tx_error,
    output wire lane0_phy_rx_error,output wire lane1_phy_rx_error,
    output wire lane0_tx_frame_error,output wire lane1_tx_frame_error,
    output wire lane0_rx_frame_error,output wire lane1_rx_frame_error
);
    wire lane0_byte_tx_valid,lane0_byte_tx_ready;
    wire [7:0] lane0_byte_tx_data;
    wire lane0_byte_tx_sop,lane0_byte_tx_eop;
    wire lane1_byte_tx_valid,lane1_byte_tx_ready;
    wire [7:0] lane1_byte_tx_data;
    wire lane1_byte_tx_sop,lane1_byte_tx_eop;
    wire lane0_byte_rx_valid,lane0_byte_rx_ready;
    wire [7:0] lane0_byte_rx_data;
    wire lane1_byte_rx_valid,lane1_byte_rx_ready;
    wire [7:0] lane1_byte_rx_data;
    wire lane0_rx_overflow,lane1_rx_overflow;
    wire lane0_rx_fault,lane1_rx_fault;
    wire lane0_rx_symbol_error,lane1_rx_symbol_error;
    wire lane0_rx_gearbox_error,lane1_rx_gearbox_error;

    bonded_two_lane_node #(
        .DATA_WIDTH(DATA_WIDTH),.KEEP_WIDTH(KEEP_WIDTH),
        .TX_FIFO_DEPTH(TX_FIFO_DEPTH),.RX_FIFO_DEPTH(RX_FIFO_DEPTH),
        .RX_ELASTIC_DEPTH(RX_ELASTIC_DEPTH),.REORDER_WINDOW(REORDER_WINDOW),
        .MAX_PACKET_BYTES(MAX_PACKET_BYTES),.LANE0_ID(LANE0_ID),.LANE1_ID(LANE1_ID),
        .SESSION_ID(SESSION_ID),.LOCAL_PEER_ID(LOCAL_PEER_ID),
        .EXPECTED_PEER_ID(EXPECTED_PEER_ID),.PROFILE_ID(PROFILE_ID),
        .MAX_PAYLOAD(MAX_PAYLOAD),.PING_INTERVAL_CYCLES(PING_INTERVAL_CYCLES),
        .PONG_TIMEOUT_CYCLES(PONG_TIMEOUT_CYCLES)
    ) node (
        .bond_clk(bond_clk),.bond_rst_n(bond_rst_n),
        .lane0_up(lane0_up && !lane0_phy_tx_error),
        .lane1_up(lane1_up && !lane1_phy_tx_error),
        .lane0_tx_clk(lane0_tx_clk),.lane0_tx_rst_n(lane0_tx_rst_n),
        .lane0_tx_valid(lane0_byte_tx_valid),.lane0_tx_ready(lane0_byte_tx_ready),
        .lane0_tx_data(lane0_byte_tx_data),.lane0_tx_sop(lane0_byte_tx_sop),
        .lane0_tx_eop(lane0_byte_tx_eop),
        .lane1_tx_clk(lane1_tx_clk),.lane1_tx_rst_n(lane1_tx_rst_n),
        .lane1_tx_valid(lane1_byte_tx_valid),.lane1_tx_ready(lane1_byte_tx_ready),
        .lane1_tx_data(lane1_byte_tx_data),.lane1_tx_sop(lane1_byte_tx_sop),
        .lane1_tx_eop(lane1_byte_tx_eop),
        .lane0_rx_clk(lane0_rx_clk),.lane0_rx_rst_n(lane0_rx_rst_n),
        .lane0_rx_valid(lane0_byte_rx_valid),.lane0_rx_ready(lane0_byte_rx_ready),
        .lane0_rx_data(lane0_byte_rx_data),.lane0_rx_overflow(lane0_rx_fault),
        .lane1_rx_clk(lane1_rx_clk),.lane1_rx_rst_n(lane1_rx_rst_n),
        .lane1_rx_valid(lane1_byte_rx_valid),.lane1_rx_ready(lane1_byte_rx_ready),
        .lane1_rx_data(lane1_byte_rx_data),.lane1_rx_overflow(lane1_rx_fault),
        .tx_valid(tx_valid),.tx_ready(tx_ready),.tx_data(tx_data),.tx_keep(tx_keep),
        .tx_sop(tx_sop),.tx_eop(tx_eop),
        .rx_valid(rx_valid),.rx_ready(rx_ready),.rx_data(rx_data),
        .rx_sop(rx_sop),.rx_eop(rx_eop),.rx_packet_sequence(rx_packet_sequence),
        .session_active(session_active),.control_fault(control_fault),
        .rx_credit_error(rx_credit_error),.tx_packet_error(tx_packet_error),
        .rx_packet_error(rx_packet_error),
        .lane0_tx_frame_error(lane0_tx_frame_error),
        .lane1_tx_frame_error(lane1_tx_frame_error),
        .lane0_rx_frame_error(lane0_rx_frame_error),
        .lane1_rx_frame_error(lane1_rx_frame_error)
    );

    bonded_lane_phy_word_bridge #(
        .SYMBOLS_PER_WORD(SYMBOLS_PER_WORD),
        .RX_FIFO_DEPTH(PHY_RX_FIFO_DEPTH),
        .RX_PHY_STALLABLE(RX_PHY_STALLABLE)
    ) lane0_bridge (
        .session_active(session_active),
        .tx_clk(lane0_tx_clk),.tx_rst_n(lane0_tx_rst_n),
        .tx_byte_valid(lane0_byte_tx_valid),.tx_byte_ready(lane0_byte_tx_ready),
        .tx_byte_data(lane0_byte_tx_data),.tx_byte_sop(lane0_byte_tx_sop),
        .tx_byte_eop(lane0_byte_tx_eop),
        .tx_phy_valid(lane0_phy_tx_valid),.tx_phy_ready(lane0_phy_tx_ready),
        .tx_phy_data(lane0_phy_tx_data),.tx_phy_ctrl(lane0_phy_tx_ctrl),
        .tx_error(lane0_phy_tx_error),
        .rx_clk(lane0_rx_clk),.rx_rst_n(lane0_rx_rst_n),
        .rx_phy_valid(lane0_phy_rx_valid),.rx_phy_ready(lane0_phy_rx_ready),
        .rx_phy_data(lane0_phy_rx_data),.rx_phy_ctrl(lane0_phy_rx_ctrl),
        .rx_byte_valid(lane0_byte_rx_valid),.rx_byte_ready(lane0_byte_rx_ready),
        .rx_byte_data(lane0_byte_rx_data),.rx_overflow(lane0_rx_overflow),
        .rx_symbol_error(lane0_rx_symbol_error),
        .rx_gearbox_error(lane0_rx_gearbox_error)
    );
    bonded_lane_phy_word_bridge #(
        .SYMBOLS_PER_WORD(SYMBOLS_PER_WORD),
        .RX_FIFO_DEPTH(PHY_RX_FIFO_DEPTH),
        .RX_PHY_STALLABLE(RX_PHY_STALLABLE)
    ) lane1_bridge (
        .session_active(session_active),
        .tx_clk(lane1_tx_clk),.tx_rst_n(lane1_tx_rst_n),
        .tx_byte_valid(lane1_byte_tx_valid),.tx_byte_ready(lane1_byte_tx_ready),
        .tx_byte_data(lane1_byte_tx_data),.tx_byte_sop(lane1_byte_tx_sop),
        .tx_byte_eop(lane1_byte_tx_eop),
        .tx_phy_valid(lane1_phy_tx_valid),.tx_phy_ready(lane1_phy_tx_ready),
        .tx_phy_data(lane1_phy_tx_data),.tx_phy_ctrl(lane1_phy_tx_ctrl),
        .tx_error(lane1_phy_tx_error),
        .rx_clk(lane1_rx_clk),.rx_rst_n(lane1_rx_rst_n),
        .rx_phy_valid(lane1_phy_rx_valid),.rx_phy_ready(lane1_phy_rx_ready),
        .rx_phy_data(lane1_phy_rx_data),.rx_phy_ctrl(lane1_phy_rx_ctrl),
        .rx_byte_valid(lane1_byte_rx_valid),.rx_byte_ready(lane1_byte_rx_ready),
        .rx_byte_data(lane1_byte_rx_data),.rx_overflow(lane1_rx_overflow),
        .rx_symbol_error(lane1_rx_symbol_error),
        .rx_gearbox_error(lane1_rx_gearbox_error)
    );

    assign lane0_rx_fault=lane0_rx_overflow | lane0_rx_symbol_error | lane0_rx_gearbox_error;
    assign lane1_rx_fault=lane1_rx_overflow | lane1_rx_symbol_error | lane1_rx_gearbox_error;
    assign lane0_phy_rx_error=lane0_rx_fault;
    assign lane1_phy_rx_error=lane1_rx_fault;
endmodule
