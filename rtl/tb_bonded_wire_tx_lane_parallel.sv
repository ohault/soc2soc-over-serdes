// SPDX-License-Identifier: BSD-2-Clause
`timescale 1ns/1ps
module tb_bonded_wire_tx_lane_parallel;
    reg clk=0; always #5 clk=~clk;
    reg rst=1;
    reg [63:0] session_id=64'h0102030405060708;
    reg in_valid=0,in_sop=0,in_eop=0;
    wire in_ready;
    reg [31:0] in_data=0;
    reg [3:0] in_keep=0;
    reg [31:0] in_packet_sequence=32'h11223344;
    reg [15:0] in_packet_length=3;
    wire out_valid,out_sop,out_eop;
    reg out_ready=0;
    wire [31:0] out_data;
    wire [3:0] out_keep;
    wire frame_error;

    bonded_wire_tx_lane_parallel #(.DATA_WIDTH(32),.LANE_ID(1)) dut (
        .clk(clk),.rst(rst),.session_id(session_id),.frame_start_enable(1'b1),
        .frame_sequence(32'd0),.in_valid(in_valid),.in_ready(in_ready),
        .in_data(in_data),.in_keep(in_keep),.in_sop(in_sop),.in_eop(in_eop),
        .in_packet_sequence(in_packet_sequence),.in_packet_length(in_packet_length),
        .out_valid(out_valid),.out_ready(out_ready),.out_data(out_data),
        .out_keep(out_keep),.out_sop(out_sop),.out_eop(out_eop),.frame_error(frame_error)
    );

    reg [7:0] expected[0:34];
    integer got=0,cycles=0,n;
    always @(posedge clk) begin
        if(!rst && out_valid && out_ready) begin
            for(n=0;n<4;n=n+1) if(out_keep[n]) begin
                if(got>=35 || out_data[n*8 +: 8]!==expected[got])
                    $fatal(1,"byte mismatch index=%0d got=%02x expected=%02x",
                           got,out_data[n*8 +: 8],expected[got]);
                if(got==0 && !out_sop) $fatal(1,"missing SOP");
                if(got==34 && !out_eop) $fatal(1,"missing EOP");
                got=got+1;
            end
        end
    end

    initial begin
        expected[0]=8'h53; expected[1]=8'h42; expected[2]=8'h01; expected[3]=8'h01;
        expected[4]=8'h00; expected[5]=8'h01; expected[6]=8'h00; expected[7]=8'h18;
        expected[8]=8'h01; expected[9]=8'h02; expected[10]=8'h03; expected[11]=8'h04;
        expected[12]=8'h05; expected[13]=8'h06; expected[14]=8'h07; expected[15]=8'h08;
        expected[16]=8'h00; expected[17]=8'h00; expected[18]=8'h00; expected[19]=8'h00;
        expected[20]=8'h00; expected[21]=8'h07; expected[22]=8'h6a; expected[23]=8'h2f;
        expected[24]=8'h11; expected[25]=8'h22; expected[26]=8'h33; expected[27]=8'h44;
        expected[28]=8'haa; expected[29]=8'hbb; expected[30]=8'hcc;
        expected[31]=8'hcc; expected[32]=8'h37; expected[33]=8'hd6; expected[34]=8'h56;

        repeat(3) @(posedge clk);
        @(negedge clk); rst=0;
        @(negedge clk); in_valid=1;in_sop=1;in_eop=1;
        in_data=32'h00ccbbaa;in_keep=4'h7;
        while(!in_ready) @(negedge clk);
        @(posedge clk);
        @(negedge clk);in_valid=0;in_sop=0;in_eop=0;
        // Hold the first output word under backpressure and verify stability.
        repeat(3) begin
            @(posedge clk);
            if(!out_valid || out_data!==32'h01014253 || out_keep!==4'hf || !out_sop)
                $fatal(1,"first word was not held stable under backpressure");
        end
        @(negedge clk); out_ready=1;
        cycles=0;
        while(got<35 && cycles<100) begin @(posedge clk);cycles=cycles+1;end
        if(got!=35 || frame_error) $fatal(1,"parallel encoder failed got=%0d error=%b",got,frame_error);
        $display("PASS: parallel DATA encoder matches byte-serial v0 golden vector");
        $finish;
    end
endmodule
