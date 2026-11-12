// SPDX-License-Identifier: BSD-2-Clause
`timescale 1ns/1ps
module tb_bonded_wire_tx_lane_parallel_multibeat;
    parameter integer DATA_WIDTH=32;
    localparam integer KEEP_WIDTH=DATA_WIDTH/8;
    localparam integer PAYLOAD_LEN=7;
    localparam integer TOTAL_LEN=24+4+PAYLOAD_LEN+4;
    reg clk=0; always #5 clk=~clk;
    reg rst=1;
    reg [63:0] session_id=64'h0102030405060708;
    reg in_valid=0,in_sop=0,in_eop=0;
    wire in_ready;
    reg [DATA_WIDTH-1:0] in_data=0;
    reg [KEEP_WIDTH-1:0] in_keep=0;
    reg [31:0] in_packet_sequence=32'h11223344;
    reg [15:0] in_packet_length=PAYLOAD_LEN;
    wire out_valid,out_sop,out_eop;
    reg out_ready=0;
    wire [DATA_WIDTH-1:0] out_data;
    wire [KEEP_WIDTH-1:0] out_keep;
    wire frame_error;
    reg [7:0] expected[0:TOTAL_LEN-1];
    reg [7:0] header[0:23];
    reg [15:0] hcrc;
    reg [31:0] fcrc;
    integer got=0,cycles=0,i,j,n,offset,beat_bytes;
    reg [DATA_WIDTH-1:0] beat_data;
    reg [KEEP_WIDTH-1:0] beat_keep;

    bonded_wire_tx_lane_parallel #(.DATA_WIDTH(DATA_WIDTH),.LANE_ID(1)) dut (
        .clk(clk),.rst(rst),.session_id(session_id),.frame_start_enable(1'b1),
        .frame_sequence(32'd0),.in_valid(in_valid),.in_ready(in_ready),
        .in_data(in_data),.in_keep(in_keep),.in_sop(in_sop),.in_eop(in_eop),
        .in_packet_sequence(in_packet_sequence),.in_packet_length(in_packet_length),
        .out_valid(out_valid),.out_ready(out_ready),.out_data(out_data),
        .out_keep(out_keep),.out_sop(out_sop),.out_eop(out_eop),.frame_error(frame_error)
    );

    function [15:0] crc16_byte(input [15:0] ci,input [7:0] d);
        integer k; reg [15:0] c;
        begin c=ci^{d,8'h00}; for(k=0;k<8;k=k+1)c=c[15]?((c<<1)^16'h1021):(c<<1); crc16_byte=c; end
    endfunction
    function [31:0] crc32_byte(input [31:0] ci,input [7:0] d);
        integer k; reg [31:0] c;
        begin c=ci^d; for(k=0;k<8;k=k+1)c=c[0]?((c>>1)^32'h82f63b78):(c>>1); crc32_byte=c; end
    endfunction

    task send_beat(input [DATA_WIDTH-1:0] d,input [KEEP_WIDTH-1:0] k,
                   input s,input e);
        begin
            @(negedge clk); in_valid=1; in_data=d; in_keep=k; in_sop=s; in_eop=e;
            while(!in_ready) @(negedge clk);
            @(posedge clk);
            @(negedge clk); in_valid=0; in_sop=0; in_eop=0;
        end
    endtask

    always @(posedge clk) begin
        if(!rst) out_ready <= ((cycles%5)!=1 && (cycles%7)!=3);
        if(!rst && out_valid && out_ready) begin
            for(n=0;n<KEEP_WIDTH;n=n+1) if(out_keep[n]) begin
                if(got>=TOTAL_LEN || out_data[n*8 +: 8]!==expected[got])
                    $fatal(1,"WIDTH=%0d byte mismatch index=%0d got=%02x expected=%02x",
                           DATA_WIDTH,got,out_data[n*8 +: 8],expected[got]);
                if(got==0 && !out_sop) $fatal(1,"WIDTH=%0d missing SOP",DATA_WIDTH);
                if(got==TOTAL_LEN-1 && !out_eop) $fatal(1,"WIDTH=%0d missing EOP",DATA_WIDTH);
                got=got+1;
            end
        end
        if(!rst) cycles=cycles+1;
    end

    initial begin
        header[0]=8'h53; header[1]=8'h42; header[2]=8'h01; header[3]=8'h01;
        header[4]=8'h00; header[5]=8'h01; header[6]=8'h00; header[7]=8'h18;
        header[8]=8'h01; header[9]=8'h02; header[10]=8'h03; header[11]=8'h04;
        header[12]=8'h05; header[13]=8'h06; header[14]=8'h07; header[15]=8'h08;
        header[16]=8'h00; header[17]=8'h00; header[18]=8'h00; header[19]=8'h00;
        header[20]=8'h00; header[21]=PAYLOAD_LEN+4;
        hcrc=16'hffff;
        for(i=0;i<22;i=i+1) hcrc=crc16_byte(hcrc,header[i]);
        header[22]=hcrc[15:8]; header[23]=hcrc[7:0];

        offset=0;
        for(i=0;i<24;i=i+1) begin expected[offset]=header[i]; offset=offset+1; end
        expected[offset]=8'h11; expected[offset+1]=8'h22;
        expected[offset+2]=8'h33; expected[offset+3]=8'h44; offset=offset+4;
        expected[offset]=8'h10; expected[offset+1]=8'h20;
        expected[offset+2]=8'h30; expected[offset+3]=8'h40;
        expected[offset+4]=8'h50; expected[offset+5]=8'h60;
        expected[offset+6]=8'h70; offset=offset+7;
        fcrc=32'hffffffff;
        for(i=0;i<offset;i=i+1) fcrc=crc32_byte(fcrc,expected[i]);
        expected[offset]=~fcrc[31:24]; expected[offset+1]=~fcrc[23:16];
        expected[offset+2]=~fcrc[15:8]; expected[offset+3]=~fcrc[7:0];

        repeat(4) @(posedge clk);
        @(negedge clk); rst=0;
        offset=0;
        while(offset<PAYLOAD_LEN) begin
            beat_data=0; beat_keep=0; beat_bytes=0;
            for(j=0;j<KEEP_WIDTH;j=j+1) begin
                if(offset+beat_bytes<PAYLOAD_LEN) begin
                    case(offset+beat_bytes)
                        0: beat_data[j*8 +: 8]=8'h10;
                        1: beat_data[j*8 +: 8]=8'h20;
                        2: beat_data[j*8 +: 8]=8'h30;
                        3: beat_data[j*8 +: 8]=8'h40;
                        4: beat_data[j*8 +: 8]=8'h50;
                        5: beat_data[j*8 +: 8]=8'h60;
                        default: beat_data[j*8 +: 8]=8'h70;
                    endcase
                    beat_keep[j]=1'b1; beat_bytes=beat_bytes+1;
                end
            end
            send_beat(beat_data,beat_keep,(offset==0),(offset+beat_bytes==PAYLOAD_LEN));
            offset=offset+beat_bytes;
        end

        cycles=0;
        while(got<TOTAL_LEN && cycles<1000) @(posedge clk);
        repeat(3) @(posedge clk);
        if(got!=TOTAL_LEN || frame_error)
            $fatal(1,"WIDTH=%0d failed: got=%0d expected=%0d frame_error=%b",
                   DATA_WIDTH,got,TOTAL_LEN,frame_error);
        $display("PASS: parallel DATA multi-beat encoder DATA_WIDTH=%0d",DATA_WIDTH);
        $finish;
    end
endmodule
