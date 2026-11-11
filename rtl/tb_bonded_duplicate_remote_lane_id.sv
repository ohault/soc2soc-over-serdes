// SPDX-License-Identifier: BSD-2-Clause
`timescale 1ns/1ps
module tb_bonded_duplicate_remote_lane_id;
    reg bond_a=0,bond_b=0;
    always #4 bond_a=~bond_a;
    always #4.5 bond_b=~bond_b;
    reg a_tx0=0,a_tx1=0,b_tx0=0,b_tx1=0;
    reg a_rx0=0,a_rx1=0,b_rx0=0,b_rx1=0;
    always #5 a_tx0=~a_tx0;
    always #6 a_tx1=~a_tx1;
    always #7 b_tx0=~b_tx0;
    always #8 b_tx1=~b_tx1;
    always #9 a_rx0=~a_rx0;
    always #10 a_rx1=~a_rx1;
    always #11 b_rx0=~b_rx0;
    always #12 b_rx1=~b_rx1;
    reg rst_n=0;

    wire a0_txv,a1_txv,b0_txv,b1_txv,a0_txr,a1_txr,b0_txr,b1_txr;
    wire [31:0] a0_txd,a1_txd,b0_txd,b1_txd;
    wire [3:0] a0_txc,a1_txc,b0_txc,b1_txc;
    wire a0_rxv,a1_rxv,b0_rxv,b1_rxv,a0_rxr,a1_rxr,b0_rxr,b1_rxr;
    wire [31:0] a0_rxd,a1_rxd,b0_rxd,b1_rxd;
    wire [3:0] a0_rxc,a1_rxc,b0_rxc,b1_rxc;

    bonded_async_fifo #(.DATA_WIDTH(36),.DEPTH(16)) ab0(
        .wr_clk(a_tx0),.wr_rst_n(rst_n),.wr_valid(a0_txv),.wr_ready(a0_txr),
        .wr_data({a0_txc,a0_txd}),.rd_clk(b_rx0),.rd_rst_n(rst_n),
        .rd_valid(b0_rxv),.rd_ready(b0_rxr),.rd_data({b0_rxc,b0_rxd}));
    bonded_async_fifo #(.DATA_WIDTH(36),.DEPTH(16)) ab1(
        .wr_clk(a_tx1),.wr_rst_n(rst_n),.wr_valid(a1_txv),.wr_ready(a1_txr),
        .wr_data({a1_txc,a1_txd}),.rd_clk(b_rx1),.rd_rst_n(rst_n),
        .rd_valid(b1_rxv),.rd_ready(b1_rxr),.rd_data({b1_rxc,b1_rxd}));
    bonded_async_fifo #(.DATA_WIDTH(36),.DEPTH(16)) ba0(
        .wr_clk(b_tx0),.wr_rst_n(rst_n),.wr_valid(b0_txv),.wr_ready(b0_txr),
        .wr_data({b0_txc,b0_txd}),.rd_clk(a_rx0),.rd_rst_n(rst_n),
        .rd_valid(a0_rxv),.rd_ready(a0_rxr),.rd_data({a0_rxc,a0_rxd}));
    bonded_async_fifo #(.DATA_WIDTH(36),.DEPTH(16)) ba1(
        .wr_clk(b_tx1),.wr_rst_n(rst_n),.wr_valid(b1_txv),.wr_ready(b1_txr),
        .wr_data({b1_txc,b1_txd}),.rd_clk(a_rx1),.rd_rst_n(rst_n),
        .rd_valid(a1_rxv),.rd_ready(a1_rxr),.rd_data({a1_rxc,a1_rxd}));

    wire active_a,active_b,fault_a,fault_b;
    wire b0_frame_error,b1_frame_error;
    wire unused_ready_a,unused_ready_b;
    wire [7:0] unused_rx_a,unused_rx_b;
    wire unused_rx_valid_a,unused_rx_valid_b;
    wire [31:0] unused_seq_a,unused_seq_b;
    wire unused_tx_error_a,unused_tx_error_b,unused_rx_credit_a,unused_rx_credit_b;
    wire unused_tx_packet_a,unused_tx_packet_b,unused_rx_packet_a,unused_rx_packet_b;

    bonded_two_lane_phy_word_node #(
        .LANE0_ID(0),.LANE1_ID(0),
        .SESSION_ID(64'h123456789abcdef0),.LOCAL_PEER_ID(64'd1),
        .EXPECTED_PEER_ID(64'd2),.MAX_PACKET_BYTES(64),.MAX_PAYLOAD(16'd64)
    ) node_a (
        .bond_clk(bond_a),.bond_rst_n(rst_n),.lane0_up(1'b1),.lane1_up(1'b1),
        .lane0_tx_clk(a_tx0),.lane0_tx_rst_n(rst_n),
        .lane0_phy_tx_valid(a0_txv),.lane0_phy_tx_ready(a0_txr),
        .lane0_phy_tx_data(a0_txd),.lane0_phy_tx_ctrl(a0_txc),
        .lane0_rx_clk(a_rx0),.lane0_rx_rst_n(rst_n),
        .lane0_phy_rx_valid(a0_rxv),.lane0_phy_rx_ready(a0_rxr),
        .lane0_phy_rx_data(a0_rxd),.lane0_phy_rx_ctrl(a0_rxc),
        .lane1_tx_clk(a_tx1),.lane1_tx_rst_n(rst_n),
        .lane1_phy_tx_valid(a1_txv),.lane1_phy_tx_ready(a1_txr),
        .lane1_phy_tx_data(a1_txd),.lane1_phy_tx_ctrl(a1_txc),
        .lane1_rx_clk(a_rx1),.lane1_rx_rst_n(rst_n),
        .lane1_phy_rx_valid(a1_rxv),.lane1_phy_rx_ready(a1_rxr),
        .lane1_phy_rx_data(a1_rxd),.lane1_phy_rx_ctrl(a1_rxc),
        .tx_valid(1'b0),.tx_ready(unused_ready_a),.tx_data(32'd0),
        .tx_keep(4'd0),.tx_sop(1'b0),.tx_eop(1'b0),
        .rx_valid(unused_rx_valid_a),.rx_ready(1'b1),.rx_data(unused_rx_a),
        .rx_sop(),.rx_eop(),.rx_packet_sequence(unused_seq_a),
        .session_active(active_a),.control_fault(fault_a),
        .rx_credit_error(unused_rx_credit_a),.tx_packet_error(unused_tx_packet_a),
        .rx_packet_error(unused_rx_packet_a),
        .lane0_phy_tx_error(unused_tx_error_a),.lane1_phy_tx_error(),
        .lane0_phy_rx_error(),.lane1_phy_rx_error(),
        .lane0_tx_frame_error(),.lane1_tx_frame_error(),
        .lane0_rx_frame_error(),.lane1_rx_frame_error()
    );

    bonded_two_lane_phy_word_node #(
        .LANE0_ID(0),.LANE1_ID(1),
        .SESSION_ID(64'h123456789abcdef0),.LOCAL_PEER_ID(64'd2),
        .EXPECTED_PEER_ID(64'd1),.MAX_PACKET_BYTES(64),.MAX_PAYLOAD(16'd64)
    ) node_b (
        .bond_clk(bond_b),.bond_rst_n(rst_n),.lane0_up(1'b1),.lane1_up(1'b1),
        .lane0_tx_clk(b_tx0),.lane0_tx_rst_n(rst_n),
        .lane0_phy_tx_valid(b0_txv),.lane0_phy_tx_ready(b0_txr),
        .lane0_phy_tx_data(b0_txd),.lane0_phy_tx_ctrl(b0_txc),
        .lane0_rx_clk(b_rx0),.lane0_rx_rst_n(rst_n),
        .lane0_phy_rx_valid(b0_rxv),.lane0_phy_rx_ready(b0_rxr),
        .lane0_phy_rx_data(b0_rxd),.lane0_phy_rx_ctrl(b0_rxc),
        .lane1_tx_clk(b_tx1),.lane1_tx_rst_n(rst_n),
        .lane1_phy_tx_valid(b1_txv),.lane1_phy_tx_ready(b1_txr),
        .lane1_phy_tx_data(b1_txd),.lane1_phy_tx_ctrl(b1_txc),
        .lane1_rx_clk(b_rx1),.lane1_rx_rst_n(rst_n),
        .lane1_phy_rx_valid(b1_rxv),.lane1_phy_rx_ready(b1_rxr),
        .lane1_phy_rx_data(b1_rxd),.lane1_phy_rx_ctrl(b1_rxc),
        .tx_valid(1'b0),.tx_ready(unused_ready_b),.tx_data(32'd0),
        .tx_keep(4'd0),.tx_sop(1'b0),.tx_eop(1'b0),
        .rx_valid(unused_rx_valid_b),.rx_ready(1'b1),.rx_data(unused_rx_b),
        .rx_sop(),.rx_eop(),.rx_packet_sequence(unused_seq_b),
        .session_active(active_b),.control_fault(fault_b),
        .rx_credit_error(unused_rx_credit_b),.tx_packet_error(unused_tx_packet_b),
        .rx_packet_error(unused_rx_packet_b),
        .lane0_phy_tx_error(unused_tx_error_b),.lane1_phy_tx_error(),
        .lane0_phy_rx_error(),.lane1_phy_rx_error(),
        .lane0_tx_frame_error(),.lane1_tx_frame_error(),
        .lane0_rx_frame_error(b0_frame_error),.lane1_rx_frame_error(b1_frame_error)
    );

    integer cycles=0;
    initial begin
        repeat(10) @(posedge bond_a);
        @(negedge bond_a);rst_n=1;
        while(!fault_b && cycles<20000) begin
            @(posedge bond_b);cycles=cycles+1;
        end
        repeat(4) @(posedge bond_b);
        if(!fault_b || active_b || !b0_frame_error || !b1_frame_error ||
           !node_b.node.endpoint.rx_path.duplicate_remote_lane_id)
            $fatal(1,"duplicate remote lane IDs were not rejected: active=%b fault=%b map=%0d/%0d",
                active_b,fault_b,
                node_b.node.endpoint.rx_path.lane0_remote_lane_id,
                node_b.node.endpoint.rx_path.lane1_remote_lane_id);
        $display("PASS: duplicate remote lane IDs invalidate the two-lane session");
        $finish;
    end
    initial begin #500000;$fatal(1,"timeout waiting for duplicate-lane rejection");end
endmodule
