// SPDX-License-Identifier: BSD-2-Clause
// End-to-end two-lane receive test: independent recovered clocks, real wire
// frame validation, per-lane async FIFOs and global packet reordering.
module tb_bonded_two_lane_rx;
    reg lane0_clk=0, lane1_clk=0, bond_clk=0;
    always #5 lane0_clk=~lane0_clk;
    always #7 lane1_clk=~lane1_clk;
    always #4 bond_clk=~bond_clk;

    reg bond_rst_n=0, lane0_rst_n=0, lane1_rst_n=0;
    reg [63:0] expected_session_id=64'h0102030405060708;
    reg lane0_valid=0,lane0_sop=0,lane0_eop=0;
    reg [7:0] lane0_data=0;
    wire lane0_ready;
    reg lane1_valid=0,lane1_sop=0,lane1_eop=0;
    reg [7:0] lane1_data=0;
    wire lane1_ready;

    wire out_valid,out_sop,out_eop;
    reg out_ready=0;
    wire [7:0] out_data;
    wire [31:0] out_packet_sequence;
    wire lane0_frame_error,lane1_frame_error,packet_error;

    bonded_two_lane_rx #(.FIFO_DEPTH(64),.REORDER_WINDOW(4),.MAX_PACKET_BYTES(64)) dut(
        .bond_rst_n(bond_rst_n),.expected_session_id(expected_session_id),
        .lane0_clk(lane0_clk),.lane0_rst_n(lane0_rst_n),
        .lane0_valid(lane0_valid),.lane0_ready(lane0_ready),.lane0_data(lane0_data),
        .lane0_sop(lane0_sop),.lane0_eop(lane0_eop),
        .lane1_clk(lane1_clk),.lane1_rst_n(lane1_rst_n),
        .lane1_valid(lane1_valid),.lane1_ready(lane1_ready),.lane1_data(lane1_data),
        .lane1_sop(lane1_sop),.lane1_eop(lane1_eop),
        .bond_clk(bond_clk),.out_valid(out_valid),.out_ready(out_ready),
        .out_data(out_data),.out_sop(out_sop),.out_eop(out_eop),
        .out_packet_sequence(out_packet_sequence),
        .lane0_frame_error(lane0_frame_error),.lane1_frame_error(lane1_frame_error),
        .packet_error(packet_error)
    );

    reg [7:0] frame0 [0:33];
    reg [7:0] frame1 [0:33];
    integer got=0, i, cycles=0;

    always @(posedge bond_clk) begin
        if(bond_rst_n && out_valid && out_ready) begin
            if(out_packet_sequence !== (got<2 ? 32'd0 : 32'd1))
                $fatal(1,"global sequence mismatch at byte %0d",got);
            if(got==0 && (!out_sop || out_data!==8'h10)) $fatal(1,"packet 0 byte 0 mismatch");
            if(got==1 && (!out_eop || out_data!==8'h11)) $fatal(1,"packet 0 byte 1 mismatch");
            if(got==2 && (!out_sop || out_data!==8'h20)) $fatal(1,"packet 1 byte 0 mismatch");
            if(got==3 && (!out_eop || out_data!==8'h21)) $fatal(1,"packet 1 byte 1 mismatch");
            got=got+1;
        end
    end

    task send0(input integer index);
        begin
            @(negedge lane0_clk);
            lane0_valid=1; lane0_data=frame0[index];
            lane0_sop=(index==0); lane0_eop=(index==33);
            #1;
            while(!lane0_ready) begin @(negedge lane0_clk); #1; end
            @(posedge lane0_clk);
            @(negedge lane0_clk);
            lane0_valid=0; lane0_sop=0; lane0_eop=0;
        end
    endtask
    task send1(input integer index);
        begin
            @(negedge lane1_clk);
            lane1_valid=1; lane1_data=frame1[index];
            lane1_sop=(index==0); lane1_eop=(index==33);
            #1;
            while(!lane1_ready) begin @(negedge lane1_clk); #1; end
            @(posedge lane1_clk);
            @(negedge lane1_clk);
            lane1_valid=0; lane1_sop=0; lane1_eop=0;
        end
    endtask

    initial begin
        frame0[0]=8'h53; frame0[1]=8'h42; frame0[2]=8'h01; frame0[3]=8'h01;
        frame0[4]=8'h00; frame0[5]=8'h00; frame0[6]=8'h00; frame0[7]=8'h18;
        frame0[8]=8'h01; frame0[9]=8'h02; frame0[10]=8'h03; frame0[11]=8'h04;
        frame0[12]=8'h05; frame0[13]=8'h06; frame0[14]=8'h07; frame0[15]=8'h08;
        frame0[16]=8'h00; frame0[17]=8'h00; frame0[18]=8'h00; frame0[19]=8'h00;
        frame0[20]=8'h00; frame0[21]=8'h06; frame0[22]=8'h6a; frame0[23]=8'hec;
        frame0[24]=8'h00; frame0[25]=8'h00; frame0[26]=8'h00; frame0[27]=8'h00;
        frame0[28]=8'h10; frame0[29]=8'h11; frame0[30]=8'hbe; frame0[31]=8'h66;
        frame0[32]=8'ha2; frame0[33]=8'hc5;

        frame1[0]=8'h53; frame1[1]=8'h42; frame1[2]=8'h01; frame1[3]=8'h01;
        frame1[4]=8'h00; frame1[5]=8'h01; frame1[6]=8'h00; frame1[7]=8'h18;
        frame1[8]=8'h01; frame1[9]=8'h02; frame1[10]=8'h03; frame1[11]=8'h04;
        frame1[12]=8'h05; frame1[13]=8'h06; frame1[14]=8'h07; frame1[15]=8'h08;
        frame1[16]=8'h00; frame1[17]=8'h00; frame1[18]=8'h00; frame1[19]=8'h00;
        frame1[20]=8'h00; frame1[21]=8'h06; frame1[22]=8'h7a; frame1[23]=8'h0e;
        frame1[24]=8'h00; frame1[25]=8'h00; frame1[26]=8'h00; frame1[27]=8'h01;
        frame1[28]=8'h20; frame1[29]=8'h21; frame1[30]=8'ha3; frame1[31]=8'h4c;
        frame1[32]=8'h7a; frame1[33]=8'h03;

        #80;
        @(negedge bond_clk);
        bond_rst_n=1; lane0_rst_n=1; lane1_rst_n=1;
        // Packet sequence 1 arrives first on lane 1.
        for(i=0;i<34;i=i+1) send1(i);
        repeat(30) @(posedge bond_clk);
        if(out_valid) $fatal(1,"packet sequence 1 escaped before sequence 0");
        // Then sequence 0 arrives on lane 0.
        for(i=0;i<34;i=i+1) send0(i);
        cycles=0;
        while(!out_valid && cycles<100) begin @(posedge bond_clk); cycles=cycles+1; end
        if(!out_valid || out_data!==8'h10 || !out_sop)
            $fatal(1,"packet 0 did not reach logical output");
        repeat(4) begin
            @(posedge bond_clk);
            if(!out_valid || out_data!==8'h10 || !out_sop)
                $fatal(1,"logical output changed under backpressure");
        end
        @(negedge bond_clk); out_ready=1;
        cycles=0;
        while(got<4 && cycles<300) begin @(posedge bond_clk); cycles=cycles+1; end
        @(posedge bond_clk);
        if(got!=4 || lane0_frame_error || lane1_frame_error || packet_error)
            $fatal(1,"end-to-end RX failed got=%0d frame_err=%b/%b packet_err=%b",
                   got,lane0_frame_error,lane1_frame_error,packet_error);
        $display("PASS: two-lane wire RX -> async CDC -> ordered logical packet stream");
        $finish;
    end
endmodule
