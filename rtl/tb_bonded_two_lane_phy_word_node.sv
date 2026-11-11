// SPDX-License-Identifier: BSD-2-Clause
`timescale 1ns/1ps
module tb_bonded_two_lane_phy_word_node;
    reg bond_a=0,bond_b=0;
    always #4 bond_a=~bond_a;
    always #4.5 bond_b=~bond_b;
    reg a_tx0=0,a_tx1=0,b_tx0=0,b_tx1=0;
    reg a_rx0=0,a_rx1=0,b_rx0=0,b_rx1=0;
    always #5 a_tx0=~a_tx0;
    always #9 a_tx1=~a_tx1;
    always #7 b_tx0=~b_tx0;
    always #11 b_tx1=~b_tx1;
    always #6.1 a_rx0=~a_rx0;
    always #10.3 a_rx1=~a_rx1;
    always #8.2 b_rx0=~b_rx0;
    always #12.4 b_rx1=~b_rx1;
    reg rst_n=0;

    wire a0_txv,a1_txv,b0_txv,b1_txv;
    wire a0_txr,a1_txr,b0_txr,b1_txr;
    wire [31:0] a0_txd,a1_txd,b0_txd,b1_txd;
    wire [3:0] a0_txc,a1_txc,b0_txc,b1_txc;
    wire a0_rxv,a1_rxv,b0_rxv,b1_rxv;
    wire a0_rxr,a1_rxr,b0_rxr,b1_rxr;
    wire [31:0] a0_rxd,a1_rxd,b0_rxd,b1_rxd;
    wire [3:0] a0_rxc,a1_rxc,b0_rxc,b1_rxc;

    bonded_async_fifo #(.DATA_WIDTH(36),.DEPTH(32)) ab0(
        .wr_clk(a_tx0),.wr_rst_n(rst_n),.wr_valid(a0_txv),.wr_ready(a0_txr),
        .wr_data({a0_txc,a0_txd}),.rd_clk(b_rx0),.rd_rst_n(rst_n),
        .rd_valid(b0_rxv),.rd_ready(b0_rxr),.rd_data({b0_rxc,b0_rxd}));
    bonded_async_fifo #(.DATA_WIDTH(36),.DEPTH(32)) ab1(
        .wr_clk(a_tx1),.wr_rst_n(rst_n),.wr_valid(a1_txv),.wr_ready(a1_txr),
        .wr_data({a1_txc,a1_txd}),.rd_clk(b_rx1),.rd_rst_n(rst_n),
        .rd_valid(b1_rxv),.rd_ready(b1_rxr),.rd_data({b1_rxc,b1_rxd}));
    bonded_async_fifo #(.DATA_WIDTH(36),.DEPTH(32)) ba0(
        .wr_clk(b_tx0),.wr_rst_n(rst_n),.wr_valid(b0_txv),.wr_ready(b0_txr),
        .wr_data({b0_txc,b0_txd}),.rd_clk(a_rx0),.rd_rst_n(rst_n),
        .rd_valid(a0_rxv),.rd_ready(a0_rxr),.rd_data({a0_rxc,a0_rxd}));
    bonded_async_fifo #(.DATA_WIDTH(36),.DEPTH(32)) ba1(
        .wr_clk(b_tx1),.wr_rst_n(rst_n),.wr_valid(b1_txv),.wr_ready(b1_txr),
        .wr_data({b1_txc,b1_txd}),.rd_clk(a_rx1),.rd_rst_n(rst_n),
        .rd_valid(a1_rxv),.rd_ready(a1_rxr),.rd_data({a1_rxc,a1_rxd}));

    reg app_valid=0,app_sop=0,app_eop=0;
    reg [31:0] app_data=0;
    reg [3:0] app_keep=0;
    wire app_ready,b_app_ready;
    wire a_rx_valid,b_rx_valid;
    wire [7:0] a_rx_data,b_rx_data;
    wire a_rx_sop,a_rx_eop,b_rx_sop,b_rx_eop;
    wire [31:0] a_rx_seq,b_rx_seq;
    wire active_a,active_b,fault_a,fault_b,credit_a,credit_b;
    wire txerr_a,txerr_b,rxerr_a,rxerr_b;
    wire a0txerr,a1txerr,b0txerr,b1txerr,a0rxerr,a1rxerr,b0rxerr,b1rxerr;
    wire a0tf,a1tf,b0tf,b1tf,a0rf,a1rf,b0rf,b1rf;

    bonded_two_lane_phy_word_node #(
        .DATA_WIDTH(32),.TX_FIFO_DEPTH(16),.RX_FIFO_DEPTH(16),
        .REORDER_WINDOW(4),.MAX_PACKET_BYTES(64),.SYMBOLS_PER_WORD(4),
        .SESSION_ID(64'h123456789abcdef0),.LOCAL_PEER_ID(64'd1),
        .EXPECTED_PEER_ID(64'd2),.MAX_PAYLOAD(16'd64),
        .PING_INTERVAL_CYCLES(32'd1000000),.PONG_TIMEOUT_CYCLES(32'd3000000)
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
        .tx_valid(app_valid),.tx_ready(app_ready),.tx_data(app_data),
        .tx_keep(app_keep),.tx_sop(app_sop),.tx_eop(app_eop),
        .rx_valid(a_rx_valid),.rx_ready(1'b1),.rx_data(a_rx_data),
        .rx_sop(a_rx_sop),.rx_eop(a_rx_eop),.rx_packet_sequence(a_rx_seq),
        .session_active(active_a),.control_fault(fault_a),
        .rx_credit_error(credit_a),.tx_packet_error(txerr_a),.rx_packet_error(rxerr_a),
        .lane0_phy_tx_error(a0txerr),.lane1_phy_tx_error(a1txerr),
        .lane0_phy_rx_error(a0rxerr),.lane1_phy_rx_error(a1rxerr),
        .lane0_tx_frame_error(a0tf),.lane1_tx_frame_error(a1tf),
        .lane0_rx_frame_error(a0rf),.lane1_rx_frame_error(a1rf)
    );

    bonded_two_lane_phy_word_node #(
        .DATA_WIDTH(32),.TX_FIFO_DEPTH(16),.RX_FIFO_DEPTH(16),
        .REORDER_WINDOW(4),.MAX_PACKET_BYTES(64),.SYMBOLS_PER_WORD(4),
        .SESSION_ID(64'h123456789abcdef0),.LOCAL_PEER_ID(64'd2),
        .EXPECTED_PEER_ID(64'd1),.MAX_PAYLOAD(16'd64),
        .PING_INTERVAL_CYCLES(32'd1000000),.PONG_TIMEOUT_CYCLES(32'd3000000)
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
        .tx_valid(1'b0),.tx_ready(b_app_ready),.tx_data(32'd0),
        .tx_keep(4'd0),.tx_sop(1'b0),.tx_eop(1'b0),
        .rx_valid(b_rx_valid),.rx_ready(1'b1),.rx_data(b_rx_data),
        .rx_sop(b_rx_sop),.rx_eop(b_rx_eop),.rx_packet_sequence(b_rx_seq),
        .session_active(active_b),.control_fault(fault_b),
        .rx_credit_error(credit_b),.tx_packet_error(txerr_b),.rx_packet_error(rxerr_b),
        .lane0_phy_tx_error(b0txerr),.lane1_phy_tx_error(b1txerr),
        .lane0_phy_rx_error(b0rxerr),.lane1_phy_rx_error(b1rxerr),
        .lane0_tx_frame_error(b0tf),.lane1_tx_frame_error(b1tf),
        .lane0_rx_frame_error(b0rf),.lane1_rx_frame_error(b1rf)
    );

    integer got=0,cycles=0;
    always @(posedge bond_b) if(b_rx_valid) begin
        case(got)
            0: if(!b_rx_sop || b_rx_data!==8'haa || b_rx_eop || b_rx_seq!==0) $fatal(1,"packet0 byte0");
            1: if(b_rx_sop || b_rx_data!==8'hbb || !b_rx_eop || b_rx_seq!==0) $fatal(1,"packet0 byte1");
            2: if(!b_rx_sop || b_rx_data!==8'hcc || b_rx_eop || b_rx_seq!==1) $fatal(1,"packet1 byte0");
            3: if(b_rx_sop || b_rx_data!==8'hdd || !b_rx_eop || b_rx_seq!==1) $fatal(1,"packet1 byte1");
            default: $fatal(1,"unexpected extra byte");
        endcase
        got=got+1;
    end

    task send_packet(input [31:0] data);
    begin
        @(negedge bond_a);
        app_valid=1;app_sop=1;app_eop=1;app_keep=4'b0011;app_data=data;
        while(!app_ready) begin @(negedge bond_a); end
        @(posedge bond_a);
        @(negedge bond_a);
        app_valid=0;app_sop=0;app_eop=0;app_keep=0;
    end
    endtask

    initial begin
        repeat(10) @(posedge bond_a);
        @(negedge bond_a);rst_n=1;
        cycles=0;
        while((!active_a || !active_b) && cycles<20000) begin
            @(posedge bond_a);cycles=cycles+1;
        end
        if(!active_a || !active_b || fault_a || fault_b)
            $fatal(1,"parallel PHY HELLO/READY failed active=%b/%b fault=%b/%b",
                   active_a,active_b,fault_a,fault_b);
        send_packet(32'h0000bbaa);
        cycles=0;
        while(got<2 && cycles<10000) begin @(posedge bond_b);cycles=cycles+1;end
        if(got!=2) $fatal(1,"first packet did not cross parallel PHY lanes");
        send_packet(32'h0000ddcc);
        cycles=0;
        while(got<4 && cycles<10000) begin @(posedge bond_b);cycles=cycles+1;end
        repeat(8) @(posedge bond_b);
        if(got!=4 || fault_a || fault_b || credit_a || credit_b ||
           txerr_a || rxerr_b || a0txerr || a1txerr || b0txerr || b1txerr ||
           a0rxerr || a1rxerr || b0rxerr || b1rxerr ||
           a0tf || a1tf || b0tf || b1tf || a0rf || a1rf || b0rf || b1rf)
            $fatal(1,"parallel two-node PHY transport failed got=%0d",got);
        $display("PASS: autonomous two-node DATA/CONTROL over two parallel 8b/10b lanes");
        $finish;
    end
    initial begin #1000000;$fatal(1,"timeout active=%b/%b got=%0d",active_a,active_b,got);end
endmodule
