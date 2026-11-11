// SPDX-License-Identifier: BSD-2-Clause
// Two endpoint full-duplex loopback over two independent lanes per direction.
// TX and peer RX clocks are intentionally unrelated.
module tb_bonded_two_lane_endpoint;
    reg bond_a=0,bond_b=0;
    always #4 bond_a=~bond_a;
    always #4.5 bond_b=~bond_b;
    reg a_tx0=0,a_tx1=0,b_rx0=0,b_rx1=0;
    reg b_tx0=0,b_tx1=0,a_rx0=0,a_rx1=0;
    always #5 a_tx0=~a_tx0;
    always #9 a_tx1=~a_tx1;
    always #6 b_rx0=~b_rx0;
    always #10 b_rx1=~b_rx1;
    always #7 b_tx0=~b_tx0;
    always #11 b_tx1=~b_tx1;
    always #8 a_rx0=~a_rx0;
    always #12 a_rx1=~a_rx1;

    reg rst_n=0, session_established=0;
    reg a_tx0_rst_n=0, b_rx0_rst_n=0;
    reg av=0,asop=0,aeop=0,bv=0,bsop=0,beop=0;
    reg [31:0] ad=0,bd=0;
    reg [3:0] ak=0,bk=0;
    wire ardy,brdy,session_a,session_b;
    wire [63:0] a_local_bytes,b_local_bytes;
    wire [31:0] a_local_packets,b_local_packets;
    wire a_credit_error,b_credit_error;
    wire arv,ars,are,brv,brs,bre;
    wire [7:0] ard,brd;
    wire [31:0] arseq,brseq;

    wire at0v,at0s,at0e,at1v,at1s,at1e,bt0v,bt0s,bt0e,bt1v,bt1s,bt1e;
    wire [7:0] at0d,at1d,bt0d,bt1d;
    wire at0r,at1r,bt0r,bt1r;
    wire a2b0_valid,a2b1_valid,b2a0_valid,b2a1_valid;
    wire a2b0_ready,a2b1_ready,b2a0_ready,b2a1_ready;
    wire [9:0] a2b0_data,a2b1_data,b2a0_data,b2a1_data;
    bonded_async_fifo #(.DATA_WIDTH(10),.DEPTH(16)) link_a2b_lane0 (
        .wr_clk(a_tx0),.wr_rst_n(rst_n),.wr_valid(at0v),.wr_ready(a2b0_ready),
        .wr_data({at0e,at0s,at0d}),.rd_clk(b_rx0),.rd_rst_n(rst_n),
        .rd_valid(a2b0_valid),.rd_ready(at0r),.rd_data(a2b0_data));
    bonded_async_fifo #(.DATA_WIDTH(10),.DEPTH(16)) link_a2b_lane1 (
        .wr_clk(a_tx1),.wr_rst_n(rst_n),.wr_valid(at1v),.wr_ready(a2b1_ready),
        .wr_data({at1e,at1s,at1d}),.rd_clk(b_rx1),.rd_rst_n(rst_n),
        .rd_valid(a2b1_valid),.rd_ready(at1r),.rd_data(a2b1_data));
    bonded_async_fifo #(.DATA_WIDTH(10),.DEPTH(16)) link_b2a_lane0 (
        .wr_clk(b_tx0),.wr_rst_n(rst_n),.wr_valid(bt0v),.wr_ready(b2a0_ready),
        .wr_data({bt0e,bt0s,bt0d}),.rd_clk(a_rx0),.rd_rst_n(rst_n),
        .rd_valid(b2a0_valid),.rd_ready(bt0r),.rd_data(b2a0_data));
    bonded_async_fifo #(.DATA_WIDTH(10),.DEPTH(16)) link_b2a_lane1 (
        .wr_clk(b_tx1),.wr_rst_n(rst_n),.wr_valid(bt1v),.wr_ready(b2a1_ready),
        .wr_data({bt1e,bt1s,bt1d}),.rd_clk(a_rx1),.rd_rst_n(rst_n),
        .rd_valid(b2a1_valid),.rd_ready(bt1r),.rd_data(b2a1_data));
    wire [31:0] at0seq,at1seq,bt0seq,bt1seq;
    wire ate,at0err,at1err,are0,are1,arerr;
    wire bte,bt0err,bt1err,bre0,bre1,brerr;

    bonded_two_lane_endpoint #(.DATA_WIDTH(32),.TX_FIFO_DEPTH(16),.RX_FIFO_DEPTH(16),
        .REORDER_WINDOW(4),.MAX_PACKET_BYTES(64)) endpoint_a (
        .bond_clk(bond_a),.bond_rst_n(rst_n),.tx_session_id(64'hA11CE),
        .rx_expected_session_id(64'hB0B),.remote_byte_limit(b_local_bytes),.remote_packet_limit(b_local_packets),.session_established(session_established),.session_active(session_a),
        .local_byte_limit(a_local_bytes),.local_packet_limit(a_local_packets),.rx_credit_error(a_credit_error),
        .tx_valid(av),.tx_ready(ardy),.tx_data(ad),.tx_keep(ak),.tx_sop(asop),.tx_eop(aeop),
        .rx_valid(arv),.rx_ready(1'b1),.rx_data(ard),.rx_sop(ars),.rx_eop(are),
        .rx_packet_sequence(arseq),
        .lane0_tx_clk(a_tx0),.lane0_tx_rst_n(a_tx0_rst_n),.lane0_tx_valid(at0v),
        .lane0_tx_ready(a2b0_ready),.lane0_tx_data(at0d),.lane0_tx_sop(at0s),.lane0_tx_eop(at0e),
        .lane1_tx_clk(a_tx1),.lane1_tx_rst_n(rst_n),.lane1_tx_valid(at1v),
        .lane1_tx_ready(a2b1_ready),.lane1_tx_data(at1d),.lane1_tx_sop(at1s),.lane1_tx_eop(at1e),
        .lane0_rx_clk(a_rx0),.lane0_rx_rst_n(rst_n),.lane0_rx_valid(b2a0_valid),
        .lane0_rx_ready(bt0r),.lane0_rx_data(b2a0_data[7:0]),.lane0_rx_sop(b2a0_data[8]),.lane0_rx_eop(b2a0_data[9]),
        .lane1_rx_clk(a_rx1),.lane1_rx_rst_n(rst_n),.lane1_rx_valid(b2a1_valid),
        .lane1_rx_ready(bt1r),.lane1_rx_data(b2a1_data[7:0]),.lane1_rx_sop(b2a1_data[8]),.lane1_rx_eop(b2a1_data[9]),
        .tx_packet_error(ate),.lane0_tx_frame_error(at0err),.lane1_tx_frame_error(at1err),
        .lane0_rx_frame_error(are0),.lane1_rx_frame_error(are1),.rx_packet_error(arerr),
        .lane0_tx_frame_sequence(at0seq),.lane1_tx_frame_sequence(at1seq)
    );

    bonded_two_lane_endpoint #(.DATA_WIDTH(32),.TX_FIFO_DEPTH(16),.RX_FIFO_DEPTH(16),
        .REORDER_WINDOW(4),.MAX_PACKET_BYTES(64)) endpoint_b (
        .bond_clk(bond_b),.bond_rst_n(rst_n),.tx_session_id(64'hB0B),
        .rx_expected_session_id(64'hA11CE),.remote_byte_limit(a_local_bytes),.remote_packet_limit(a_local_packets),.session_established(rst_n),.session_active(session_b),
        .local_byte_limit(b_local_bytes),.local_packet_limit(b_local_packets),.rx_credit_error(b_credit_error),
        .tx_valid(bv),.tx_ready(brdy),.tx_data(bd),.tx_keep(bk),.tx_sop(bsop),.tx_eop(beop),
        .rx_valid(brv),.rx_ready(1'b1),.rx_data(brd),.rx_sop(brs),.rx_eop(bre),
        .rx_packet_sequence(brseq),
        .lane0_tx_clk(b_tx0),.lane0_tx_rst_n(rst_n),.lane0_tx_valid(bt0v),
        .lane0_tx_ready(b2a0_ready),.lane0_tx_data(bt0d),.lane0_tx_sop(bt0s),.lane0_tx_eop(bt0e),
        .lane1_tx_clk(b_tx1),.lane1_tx_rst_n(rst_n),.lane1_tx_valid(bt1v),
        .lane1_tx_ready(b2a1_ready),.lane1_tx_data(bt1d),.lane1_tx_sop(bt1s),.lane1_tx_eop(bt1e),
        .lane0_rx_clk(b_rx0),.lane0_rx_rst_n(b_rx0_rst_n),.lane0_rx_valid(a2b0_valid),
        .lane0_rx_ready(at0r),.lane0_rx_data(a2b0_data[7:0]),.lane0_rx_sop(a2b0_data[8]),.lane0_rx_eop(a2b0_data[9]),
        .lane1_rx_clk(b_rx1),.lane1_rx_rst_n(rst_n),.lane1_rx_valid(a2b1_valid),
        .lane1_rx_ready(at1r),.lane1_rx_data(a2b1_data[7:0]),.lane1_rx_sop(a2b1_data[8]),.lane1_rx_eop(a2b1_data[9]),
        .tx_packet_error(bte),.lane0_tx_frame_error(bt0err),.lane1_tx_frame_error(bt1err),
        .lane0_rx_frame_error(bre0),.lane1_rx_frame_error(bre1),.rx_packet_error(brerr),
        .lane0_tx_frame_sequence(bt0seq),.lane1_tx_frame_sequence(bt1seq)
    );

    integer acount=0,bcount=0;
    always @(posedge bond_a) if(arv) begin
        case(acount)
          0: if(arseq!==0 || !ars || ard!==8'ha1 || are) $fatal(1,"A RX byte 0 mismatch");
          1: if(arseq!==0 || ars || ard!==8'hb2 || !are) $fatal(1,"A RX byte 1 mismatch");
          default: $fatal(1,"unexpected A RX byte");
        endcase
        acount<=acount+1;
    end
    always @(posedge bond_b) if(brv) begin
        case(bcount)
          0: if(brseq!==0 || !brs || brd!==8'hc3 || bre) $fatal(1,"B RX byte 0 mismatch");
          1: if(brseq!==0 || brs || brd!==8'hd4 || !bre) $fatal(1,"B RX byte 1 mismatch");
          default: $fatal(1,"unexpected B RX byte");
        endcase
        bcount<=bcount+1;
    end

    task send_a;
      begin
        @(negedge bond_a); av=1;asop=1;aeop=1;ak=4'b0011;ad=32'h0000d4c3;
        #1; while(!ardy) begin @(negedge bond_a); #1; end
        @(posedge bond_a); @(negedge bond_a);av=0;asop=0;aeop=0;
      end
    endtask
    task send_b;
      begin
        @(negedge bond_b); bv=1;bsop=1;beop=1;bk=4'b0011;bd=32'h0000b2a1;
        #1; while(!brdy) begin @(negedge bond_b); #1; end
        @(posedge bond_b); @(negedge bond_b);bv=0;bsop=0;beop=0;
      end
    endtask

    integer timeout=0;
    initial begin
        repeat(8) @(posedge bond_a);
        @(negedge bond_a); rst_n=1; a_tx0_rst_n=1; b_rx0_rst_n=1;
        // Wait for all four lane reset releases to cross into each endpoint's
        // bonding clock, then explicitly establish the initial session.
        repeat(4) @(posedge bond_a);
        @(negedge bond_a); session_established=1;
        repeat(4) @(posedge bond_b);
        if(!session_a || !session_b) $fatal(1,"initial session did not activate");
        fork send_a(); send_b(); join
        while((acount<2 || bcount<2) && timeout<3000) begin
            @(posedge bond_a); timeout=timeout+1;
        end
        repeat(5) @(posedge bond_a);
        if(!session_a || !session_b || acount!=2 || bcount!=2 || ate || bte || at0err || at1err ||
           bt0err || bt1err || are0 || are1 || bre0 || bre1 || arerr || brerr || a_credit_error || b_credit_error)
            $fatal(1,"full-duplex endpoint failed A=%0d B=%0d txerr=%b/%b rxerr=%b/%b",
                   acount,bcount,ate,bte,arerr,brerr);
        // A fault on one physical direction must flush both directions and
        // must not silently reactivate the old session when the lane recovers.
        @(negedge bond_a); session_established=0;
        @(negedge a_tx0); a_tx0_rst_n=0; b_rx0_rst_n=0;
        repeat(3) @(posedge bond_a);
        if(session_a || session_b || ardy || brdy)
            $fatal(1,"a bonded endpoint remained active during lane reset");
        @(negedge a_tx0); a_tx0_rst_n=1; b_rx0_rst_n=1;
        repeat(5) @(posedge bond_a);
        if(session_a || session_b || ardy || brdy)
            $fatal(1,"old session reactivated without renegotiation");
        @(negedge bond_a); session_established=1;
        repeat(5) @(posedge bond_a);
        if(!session_a || !session_b)
            $fatal(1,"endpoints failed to reactivate after renegotiation");
        $display("PASS: full-duplex packets, four unrelated clocks, coordinated session reset and re-arm");
        $finish;
    end
endmodule
