// SPDX-License-Identifier: BSD-2-Clause
// End-to-end TX loopback: packet scheduler -> per-lane async FIFO ->
// v0 wire encoders -> independent v0 wire decoders.
module tb_bonded_two_lane_tx;
    reg bond_clk=0,lane0_clk=0,lane1_clk=0;
    always #4 bond_clk=~bond_clk;
    always #5 lane0_clk=~lane0_clk;
    always #7 lane1_clk=~lane1_clk;
    reg bond_rst_n=0,lane0_rst_n=0,lane1_rst_n=0;
    reg [63:0] session_id=64'h1020304050607080;
    reg tx_valid=0,tx_sop=0,tx_eop=0;
    reg [31:0] tx_data=0;
    reg [3:0] tx_keep=0;
    wire tx_ready,packet_error;
    wire l0v,l0s,l0e,l1v,l1s,l1e;
    wire [7:0] l0d,l1d;
    wire l0r,l1r;
    wire l0err,l1err;
    wire [31:0] l0seq,l1seq;

    bonded_two_lane_tx #(.DATA_WIDTH(32),.FIFO_DEPTH(16),.MAX_PACKET_BYTES(64),
                         .LANE0_ID(0),.LANE1_ID(1)) dut (
        .bond_clk(bond_clk),.bond_rst_n(bond_rst_n),.session_id(session_id),
        .tx_valid(tx_valid),.tx_ready(tx_ready),.tx_data(tx_data),.tx_keep(tx_keep),
        .tx_sop(tx_sop),.tx_eop(tx_eop),
        .lane0_clk(lane0_clk),.lane0_rst_n(lane0_rst_n),
        .lane0_valid(l0v),.lane0_ready(l0r),.lane0_data(l0d),.lane0_sop(l0s),.lane0_eop(l0e),
        .lane1_clk(lane1_clk),.lane1_rst_n(lane1_rst_n),
        .lane1_valid(l1v),.lane1_ready(l1r),.lane1_data(l1d),.lane1_sop(l1s),.lane1_eop(l1e),
        .packet_error(packet_error),.lane0_frame_error(l0err),.lane1_frame_error(l1err),
        .lane0_frame_sequence(l0seq),.lane1_frame_sequence(l1seq)
    );

    wire d0v,d0s,d0e,d1v,d1s,d1e;
    wire [7:0] d0d,d1d;
    wire [31:0] d0seq,d1seq,d0fseq,d1fseq,d0expected,d1expected;
    wire d0err,d1err,d0pulse,d1pulse;
    reg [31:0] got0=0,got1=0;
    bonded_wire_rx_lane #(.LANE_ID(0),.MAX_PAYLOAD(64)) decoder0 (
        .clk(lane0_clk),.rst(!bond_rst_n || !lane0_rst_n),.expected_session_id(session_id),
        .in_valid(l0v),.in_ready(l0r),.in_data(l0d),.in_sop(l0s),.in_eop(l0e),
        .out_valid(d0v),.out_ready(1'b1),.out_data(d0d),.out_sop(d0s),.out_eop(d0e),
        .out_packet_sequence(d0seq),.out_frame_sequence(d0fseq),
        .expected_frame_sequence(d0expected),.frame_error(d0err),.frame_valid_pulse(d0pulse)
    );
    bonded_wire_rx_lane #(.LANE_ID(1),.MAX_PAYLOAD(64)) decoder1 (
        .clk(lane1_clk),.rst(!bond_rst_n || !lane1_rst_n),.expected_session_id(session_id),
        .in_valid(l1v),.in_ready(l1r),.in_data(l1d),.in_sop(l1s),.in_eop(l1e),
        .out_valid(d1v),.out_ready(1'b1),.out_data(d1d),.out_sop(d1s),.out_eop(d1e),
        .out_packet_sequence(d1seq),.out_frame_sequence(d1fseq),
        .expected_frame_sequence(d1expected),.frame_error(d1err),.frame_valid_pulse(d1pulse)
    );

    always @(posedge lane0_clk) if(d0v) begin
        if(d0seq!==0 || (got0==0 && (!d0s || d0d!==8'h11)) ||
           (got0==1 && (!d0e || d0d!==8'h22)) || got0>1)
            $fatal(1,"lane0 decoded payload mismatch index=%0d data=%h seq=%0d",got0,d0d,d0seq);
        got0<=got0+1;
    end
    always @(posedge lane1_clk) if(d1v) begin
        if(d1seq!==1 || (got1==0 && (!d1s || d1d!==8'h33)) ||
           (got1==1 && (!d1e || d1d!==8'h44)) || got1>1)
            $fatal(1,"lane1 decoded payload mismatch index=%0d data=%h seq=%0d",got1,d1d,d1seq);
        got1<=got1+1;
    end

    task send_packet(input [31:0] data,input [3:0] keep);
        begin
            @(negedge bond_clk);
            tx_valid=1;tx_sop=1;tx_eop=1;tx_data=data;tx_keep=keep;
            #1;
            while(!tx_ready) begin @(negedge bond_clk); #1; end
            @(posedge bond_clk);
            @(negedge bond_clk);tx_valid=0;tx_sop=0;tx_eop=0;
        end
    endtask

    integer cycles=0;
    initial begin
        repeat(4) @(posedge bond_clk);
        @(negedge bond_clk);bond_rst_n=1;lane0_rst_n=1;lane1_rst_n=1;
        send_packet(32'h00002211,4'b0011);
        send_packet(32'h00004433,4'b0011);
        cycles=0;
        while((got0<2 || got1<2) && cycles<1000) begin
            @(posedge bond_clk);cycles=cycles+1;
        end
        if(got0!=2 || got1!=2 || packet_error || l0err || l1err || d0err || d1err ||
           l0seq!=1 || l1seq!=1 || d0expected!=1 || d1expected!=1)
            $fatal(1,"TX loopback failed got=%0d/%0d sched=%b wire=%b/%b rx=%b/%b",
                   got0,got1,packet_error,l0err,l1err,d0err,d1err);
        $display("PASS: two-lane packet TX, async CDC, wire framing and CRC loopback");
        $finish;
    end
endmodule
