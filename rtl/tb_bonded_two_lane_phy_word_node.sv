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
    reg b_app_rx_ready=0;
    reg [15:0] consumer_lfsr=16'h1ace;
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
        .rx_valid(b_rx_valid),.rx_ready(b_app_rx_ready),.rx_data(b_rx_data),
        .rx_sop(b_rx_sop),.rx_eop(b_rx_eop),.rx_packet_sequence(b_rx_seq),
        .session_active(active_b),.control_fault(fault_b),
        .rx_credit_error(credit_b),.tx_packet_error(txerr_b),.rx_packet_error(rxerr_b),
        .lane0_phy_tx_error(b0txerr),.lane1_phy_tx_error(b1txerr),
        .lane0_phy_rx_error(b0rxerr),.lane1_phy_rx_error(b1rxerr),
        .lane0_tx_frame_error(b0tf),.lane1_tx_frame_error(b1tf),
        .lane0_rx_frame_error(b0rf),.lane1_rx_frame_error(b1rf)
    );

    reg [7:0] expected_data[0:127];
    reg [31:0] expected_sequence[0:127];
    reg expected_sop[0:127],expected_eop[0:127];
    integer expected_count=0,got=0,cycles=0,packet_number=0;
    integer lane0_data_frames=0,lane1_data_frames=0;

    always @(posedge b_rx0)
        if(node_b.node.endpoint.rx_path.lane0_decoder.frame_valid_pulse)
            lane0_data_frames<=lane0_data_frames+1;
    always @(posedge b_rx1)
        if(node_b.node.endpoint.rx_path.lane1_decoder.frame_valid_pulse)
            lane1_data_frames<=lane1_data_frames+1;

    always @(posedge bond_b) begin
        if(!rst_n) begin
            consumer_lfsr<=16'h1ace;
            b_app_rx_ready<=0;
        end else begin
            consumer_lfsr<={consumer_lfsr[14:0],
                consumer_lfsr[15]^consumer_lfsr[13]^consumer_lfsr[12]^consumer_lfsr[10]};
            // Deliberate, repeatable backpressure at the logical application
            // interface. The physical RX clocks continue independently.
            b_app_rx_ready<=(consumer_lfsr[2:0]!=0);
            if(b_rx_valid && b_app_rx_ready) begin
                if(got>=expected_count || b_rx_data!==expected_data[got] ||
                   b_rx_seq!==expected_sequence[got] ||
                   b_rx_sop!==expected_sop[got] || b_rx_eop!==expected_eop[got])
                    $fatal(1,"parallel RX mismatch at byte %0d data=%02x seq=%0d sop/eop=%b/%b",
                           got,b_rx_data,b_rx_seq,b_rx_sop,b_rx_eop);
                got=got+1;
            end
        end
    end

    task send_packet(input [127:0] payload,input integer length);
        integer offset,n,j;
        reg [31:0] beat;
        reg [3:0] keep;
    begin
        if(length<1 || length>16) $fatal(1,"bad test packet length");
        for(j=0;j<length;j=j+1) begin
            expected_data[expected_count+j]=payload[j*8 +: 8];
            expected_sequence[expected_count+j]=packet_number;
            expected_sop[expected_count+j]=(j==0);
            expected_eop[expected_count+j]=(j==length-1);
        end
        expected_count=expected_count+length;
        offset=0;
        while(offset<length) begin
            n=length-offset;
            if(n>4) n=4;
            beat=0;
            for(j=0;j<n;j=j+1) beat[j*8 +: 8]=payload[(offset+j)*8 +: 8];
            keep=(1<<n)-1;
            @(negedge bond_a);
            app_valid=1;
            app_sop=(offset==0);
            app_eop=(offset+n==length);
            app_keep=keep;
            app_data=beat;
            #1; // Let keep/EOP-dependent credit READY settle before testing it.
            while(app_ready !== 1'b1) @(negedge bond_a);
            @(posedge bond_a);
            offset=offset+n;
        end
        @(negedge bond_a);
        app_valid=0;app_sop=0;app_eop=0;app_keep=0;
        if(txerr_a) $fatal(1,"TX packet scheduler rejected packet %0d length=%0d",
                           packet_number,length);
        packet_number=packet_number+1;
    end
    endtask

    initial begin
        reg [127:0] payload;
        integer p,i;
        repeat(10) @(posedge bond_a);
        @(negedge bond_a);rst_n=1;
        cycles=0;
        while((!active_a || !active_b) && cycles<20000) begin
            @(posedge bond_a);cycles=cycles+1;
        end
        if(!active_a || !active_b || fault_a || fault_b)
            $fatal(1,"parallel PHY HELLO/READY failed active=%b/%b fault=%b/%b",
                   active_a,active_b,fault_a,fault_b);

        // Exercise SOP/EOP positions on short and multiword packets, including
        // partial final words and payload bytes equal to K28.5/K28.0 values.
        for(p=0;p<8;p=p+1) begin
            payload=0;
            for(i=0;i<16;i=i+1)
                payload[i*8 +: 8]=(p*8'h31)+(i*8'h17)+8'h5a;
            if(p==0) payload[7:0]=8'hbc;
            if(p==1) payload[7:0]=8'h1c;
            send_packet(payload,(p==0)?1:(p==1)?2:(p==2)?3:(p==3)?4:
                        (p==4)?5:(p==5)?7:(p==6)?11:16);
        end
        cycles=0;
        while(got<expected_count && cycles<50000) begin
            @(posedge bond_b);cycles=cycles+1;
        end
        repeat(12) @(posedge bond_b);
        $display("PHY stress diagnostics got=%0d expected=%0d active=%b/%b fault=%b/%b credit=%b/%b txerr=%b rxerr=%b",
                 got,expected_count,active_a,active_b,fault_a,fault_b,credit_a,credit_b,txerr_a,rxerr_b);
        $display("credits B local bytes/packets=%0d/%0d consumed=%0d/%0d accepted=%0d/%0d; A remote=%0d/%0d reserved=%0d/%0d",
                 node_b.node.local_byte_limit,node_b.node.local_packet_limit,
                 node_b.node.endpoint.rx_path.credit_accounting.rx_consumed_bytes,
                 node_b.node.endpoint.rx_path.credit_accounting.rx_consumed_packets,
                 node_b.node.endpoint.rx_path.credit_accounting.rx_accepted_bytes,
                 node_b.node.endpoint.rx_path.credit_accounting.rx_accepted_packets,
                 node_a.node.remote_byte_limit,node_a.node.remote_packet_limit,
                 node_a.node.endpoint.tx_path.credit_accounting.tx_reserved_bytes,
                 node_a.node.endpoint.tx_path.credit_accounting.tx_reserved_packets);
        $display("packet reorder expected=%0d error=%b; B lane frame errors=%b/%b PHY RX errors=%b/%b",
                 node_b.node.endpoint.rx_path.packet_reorder.expected_packet_sequence,
                 node_b.node.endpoint.rx_path.packet_reorder.packet_error,
                 b0rf,b1rf,b0rxerr,b1rxerr);
        if(got!=expected_count || lane0_data_frames!=4 || lane1_data_frames!=4 ||
           fault_a || fault_b || credit_a || credit_b ||
           txerr_a || rxerr_b || a0txerr || a1txerr || b0txerr || b1txerr ||
           a0rxerr || a1rxerr || b0rxerr || b1rxerr ||
           a0tf || a1tf || b0tf || b1tf || a0rf || a1rf || b0rf || b1rf)
            begin
                $display("diag active=%b/%b fault=%b/%b credit=%b/%b txerr=%b/%b rxerr=%b/%b",
                    active_a,active_b,fault_a,fault_b,credit_a,credit_b,txerr_a,txerr_b,rxerr_a,rxerr_b);
                $display("diag reorder expected=%0d slot_valid=%b filling=%b lane_active=%b lane_drop=%b counts=%0d/%0d",
                    node_b.node.endpoint.rx_path.packet_reorder.expected_packet_sequence,
                    node_b.node.endpoint.rx_path.packet_reorder.slot_valid,
                    node_b.node.endpoint.rx_path.packet_reorder.slot_filling,
                    node_b.node.endpoint.rx_path.packet_reorder.lane_active,
                    node_b.node.endpoint.rx_path.packet_reorder.lane_drop,
                    node_b.node.endpoint.rx_path.packet_reorder.lane_count[0],
                    node_b.node.endpoint.rx_path.packet_reorder.lane_count[1]);
                $display("diag lane frames tx=%0d/%0d rx_expected=%0d/%0d frame_errors=%b%b%b%b",
                    node_a.node.endpoint.tx_path.lane0_frame_sequence,
                    node_a.node.endpoint.tx_path.lane1_frame_sequence,
                    node_b.node.endpoint.rx_path.lane0_expected_wire_sequence,
                    node_b.node.endpoint.rx_path.lane1_expected_wire_sequence,
                    a0rf,a1rf,b0rf,b1rf);
                $fatal(1,"parallel two-node PHY transport failed got=%0d expected=%0d",
                       got,expected_count);
            end
        $display("PASS: two-node parallel PHY, 8 variable-length packets, both lanes, partial words and RX backpressure");
        $finish;
    end
    initial begin #2000000;$fatal(1,"timeout active=%b/%b got=%0d expected=%0d",
                                  active_a,active_b,got,expected_count);end
endmodule
