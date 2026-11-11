// SPDX-License-Identifier: BSD-2-Clause
// Golden-vector regression: bytes are generated independently by the Python
// v0 codec (CRC-16/CCITT-FALSE and CRC-32C).
module tb_bonded_wire_tx_lane;
    reg clk=0;
    always #5 clk=~clk;
    reg rst=1;
    reg [63:0] session_id=64'h0102030405060708;
    reg in_valid=0, in_sop=0, in_eop=0;
    wire in_ready;
    reg [31:0] in_data=0;
    reg [3:0] in_keep=0;
    reg [31:0] in_packet_sequence=32'h11223344;
    reg [15:0] in_packet_length=3;
    wire out_valid, out_sop, out_eop;
    reg out_ready=1;
    wire [7:0] out_data;
    wire [31:0] next_frame_sequence;
    wire frame_error;

    bonded_wire_tx_lane #(.DATA_WIDTH(32),.LANE_ID(1)) dut (
        .clk(clk),.rst(rst),.session_id(session_id),
        .in_valid(in_valid),.in_ready(in_ready),.in_data(in_data),
        .in_keep(in_keep),.in_sop(in_sop),.in_eop(in_eop),
        .in_packet_sequence(in_packet_sequence),.in_packet_length(in_packet_length),
        .out_valid(out_valid),.out_ready(out_ready),.out_data(out_data),
        .out_sop(out_sop),.out_eop(out_eop),
        .next_frame_sequence(next_frame_sequence),.frame_error(frame_error)
    );

    reg [7:0] expected [0:34];
    integer got=0, cycles=0;
    always @(posedge clk) begin
        if (!rst && out_valid && out_ready) begin
            if (got>=35 || out_data !== expected[got]) begin
                $display("byte mismatch index=%0d got=%02x expected=%02x frame_crc=%08x header_crc=%04x state=%0d crc_index=%0d mux=%02x",got,out_data,expected[got],dut.frame_crc,dut.header_crc,dut.state,dut.crc_index,dut.byte_mux);
                $fatal(1);
            end
            if (out_sop !== (got==0) || out_eop !== (got==34)) begin
                $display("SOP/EOP mismatch index=%0d sop=%b eop=%b",got,out_sop,out_eop);
                $fatal(1);
            end
            got=got+1;
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
        @(negedge clk);
        in_valid=1; in_sop=1; in_eop=1; in_data=32'h00ccbbaa; in_keep=4'h7;
        while(!in_ready) @(negedge clk);
        @(posedge clk);
        @(negedge clk); in_valid=0; in_sop=0; in_eop=0;
        cycles=0;
        while(got<35 && cycles<200) begin @(posedge clk); cycles=cycles+1; end
        if(got!=35 || frame_error || next_frame_sequence!=1) begin
            $display("FAIL got=%0d err=%b frame_seq=%0d",got,frame_error,next_frame_sequence);
            $fatal(1);
        end
        $display("PASS: v0 DATA frame matches independent golden vector");
        $finish;
    end
endmodule
