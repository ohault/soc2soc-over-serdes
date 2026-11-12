// SPDX-License-Identifier: BSD-2-Clause
`timescale 1ns/1ps
module tb_bonded_wire_rx_lane_parallel;
    parameter integer DATA_WIDTH=32;
    localparam integer KEEP_WIDTH=DATA_WIDTH/8;
    localparam integer PAYLOAD_LEN=7;
    localparam integer FRAME_LEN=24+4+PAYLOAD_LEN+4;
    localparam integer WORD_BYTES=DATA_WIDTH/8;
    reg clk=0; always #5 clk=~clk;
    reg rst=1;
    reg [63:0] expected_session_id=64'h0102030405060708;
    reg [31:0] expected_frame_sequence_override=0;
    reg [7:0] expected_lane_id=8'ha5;
    reg in_valid=0,in_sop=0,in_eop=0;
    wire in_ready;
    reg [DATA_WIDTH-1:0] in_data=0;
    reg [KEEP_WIDTH-1:0] in_keep=0;
    wire out_valid,out_sop,out_eop;
    reg out_ready=0;
    wire [DATA_WIDTH-1:0] out_data;
    wire [KEEP_WIDTH-1:0] out_keep;
    wire [31:0] out_packet_sequence,out_frame_sequence,expected_frame_sequence;
    wire [7:0] out_lane_id;
    wire frame_error,frame_valid_pulse;
    reg [7:0] frame[0:FRAME_LEN-1];
    reg [7:0] payload[0:PAYLOAD_LEN-1];
    reg [15:0] hcrc;
    reg [31:0] fcrc;
    integer i,j,offset,count,got=0,cycles=0;
    reg force_stall=0;

    bonded_wire_rx_lane_parallel #(.DATA_WIDTH(DATA_WIDTH),.LANE_ID(0),.DYNAMIC_LANE_ID(1)) dut (
        .clk(clk),.rst(rst),.expected_session_id(expected_session_id),
        .expected_frame_sequence_override(expected_frame_sequence_override),
        .expected_lane_id(expected_lane_id),.in_valid(in_valid),.in_ready(in_ready),
        .in_data(in_data),.in_keep(in_keep),.in_sop(in_sop),.in_eop(in_eop),
        .out_valid(out_valid),.out_ready(out_ready),.out_data(out_data),.out_keep(out_keep),
        .out_sop(out_sop),.out_eop(out_eop),.out_packet_sequence(out_packet_sequence),
        .out_frame_sequence(out_frame_sequence),.out_lane_id(out_lane_id),
        .expected_frame_sequence(expected_frame_sequence),.frame_error(frame_error),
        .frame_valid_pulse(frame_valid_pulse)
    );

    function [15:0] crc16_byte(input [15:0] ci,input [7:0] d);
        integer k; reg [15:0] c;
        begin c=ci^{d,8'h00}; for(k=0;k<8;k=k+1)c=c[15]?((c<<1)^16'h1021):(c<<1); crc16_byte=c; end
    endfunction
    function [31:0] crc32_byte(input [31:0] ci,input [7:0] d);
        integer k; reg [31:0] c;
        begin c=ci^d; for(k=0;k<8;k=k+1)c=c[0]?((c>>1)^32'h82f63b78):(c>>1); crc32_byte=c; end
    endfunction

    task send_word(input integer start,input integer bytes,input bit first,input bit last);
        integer q;
        begin
            @(negedge clk); in_data=0; in_keep=0;
            for(q=0;q<bytes;q=q+1) begin
                in_data[q*8 +: 8]=frame[start+q]; in_keep[q]=1;
            end
            in_sop=first; in_eop=last; in_valid=1;
            while(!in_ready) @(negedge clk);
            @(posedge clk); @(negedge clk); in_valid=0; in_sop=0; in_eop=0;
        end
    endtask

    always @(posedge clk) begin
        if(!rst) out_ready<=force_stall ? 1'b0 : ((cycles%4)!=1);
        if(!rst && out_valid && out_ready) begin
            if(got==0 && !out_sop) $fatal(1,"missing output SOP");
            for(j=0;j<KEEP_WIDTH;j=j+1) if(out_keep[j]) begin
                if(got>=PAYLOAD_LEN || out_data[j*8 +: 8]!==payload[got])
                    $fatal(1,"WIDTH=%0d payload mismatch index=%0d got=%02x expected=%02x",
                           DATA_WIDTH,got,out_data[j*8 +: 8],payload[got]);
                got=got+1;
            end
            if(out_eop && got!=PAYLOAD_LEN) $fatal(1,"early EOP");
            if(got==PAYLOAD_LEN && !out_eop) $fatal(1,"missing EOP");
        end
        if(!rst) cycles=cycles+1;
    end

    initial begin
        frame[0]=8'h53; frame[1]=8'h42; frame[2]=1; frame[3]=1;
        frame[4]=0; frame[5]=8'ha5; frame[6]=0; frame[7]=24;
        frame[8]=1; frame[9]=2; frame[10]=3; frame[11]=4;
        frame[12]=5; frame[13]=6; frame[14]=7; frame[15]=8;
        frame[16]=0; frame[17]=0; frame[18]=0; frame[19]=0;
        frame[20]=0; frame[21]=PAYLOAD_LEN+4;
        hcrc=16'hffff; for(i=0;i<22;i=i+1) hcrc=crc16_byte(hcrc,frame[i]);
        frame[22]=hcrc[15:8]; frame[23]=hcrc[7:0];
        frame[24]=8'h11; frame[25]=8'h22; frame[26]=8'h33; frame[27]=8'h44;
        payload[0]=8'h10; payload[1]=8'h20; payload[2]=8'h30; payload[3]=8'h40;
        payload[4]=8'h50; payload[5]=8'h60; payload[6]=8'h70;
        for(i=0;i<PAYLOAD_LEN;i=i+1) frame[28+i]=payload[i];
        fcrc=32'hffffffff; for(i=0;i<FRAME_LEN-4;i=i+1) fcrc=crc32_byte(fcrc,frame[i]);
        frame[FRAME_LEN-4]=~fcrc[31:24]; frame[FRAME_LEN-3]=~fcrc[23:16];
        frame[FRAME_LEN-2]=~fcrc[15:8]; frame[FRAME_LEN-1]=~fcrc[7:0];

        repeat(4) @(posedge clk); @(negedge clk); rst=0;
        offset=0;
        while(offset<FRAME_LEN) begin
            if(offset<28) count=WORD_BYTES;
            else if(offset<28+PAYLOAD_LEN) begin
                count=WORD_BYTES; if(offset+count>28+PAYLOAD_LEN) count=28+PAYLOAD_LEN-offset;
            end else count=WORD_BYTES;
            if(offset+count>FRAME_LEN) count=FRAME_LEN-offset;
            send_word(offset,count,(offset==0),(offset+count==FRAME_LEN));
            offset=offset+count;
        end
        while(got<PAYLOAD_LEN && cycles<1000) @(posedge clk);
        repeat(3) @(posedge clk);
        if(got!=PAYLOAD_LEN || frame_error || out_packet_sequence!=32'h11223344 ||
           out_frame_sequence!=0 || out_lane_id!=8'ha5 || expected_frame_sequence!=1)
            $fatal(1,"WIDTH=%0d failed got=%0d err=%b packet=%h frame=%h lane=%d next=%h",
                   DATA_WIDTH,got,frame_error,out_packet_sequence,out_frame_sequence,
                   out_lane_id,expected_frame_sequence);

        // Re-run after reset with a corrupted frame CRC. No payload may escape.
        @(negedge clk); rst=1; got=0;
        repeat(3) @(posedge clk); @(negedge clk); rst=0;
        frame[FRAME_LEN-1]=frame[FRAME_LEN-1]^8'h01;
        offset=0;
        while(offset<FRAME_LEN) begin
            if(offset<28) count=WORD_BYTES;
            else if(offset<28+PAYLOAD_LEN) begin
                count=WORD_BYTES; if(offset+count>28+PAYLOAD_LEN) count=28+PAYLOAD_LEN-offset;
            end else count=WORD_BYTES;
            if(offset+count>FRAME_LEN) count=FRAME_LEN-offset;
            send_word(offset,count,(offset==0),(offset+count==FRAME_LEN));
            offset=offset+count;
        end
        repeat(100) @(posedge clk);
        if(!frame_error || got!=0)
            $fatal(1,"WIDTH=%0d corrupted CRC was not rejected (err=%b got=%0d)",DATA_WIDTH,frame_error,got);
        $display("PASS: parallel DATA RX DATA_WIDTH=%0d (valid + CRC rejection)",DATA_WIDTH);

        // A valid frame from an old session is discarded without link error.
        @(negedge clk); rst=1; got=0; frame[FRAME_LEN-1]=frame[FRAME_LEN-1]^8'h01;
        expected_session_id=64'h1112131415161718;
        repeat(3) @(posedge clk); @(negedge clk); rst=0;
        offset=0;
        while(offset<FRAME_LEN) begin
            if(offset<28) count=WORD_BYTES;
            else if(offset<28+PAYLOAD_LEN) begin
                count=WORD_BYTES; if(offset+count>28+PAYLOAD_LEN) count=28+PAYLOAD_LEN-offset;
            end else count=WORD_BYTES;
            if(offset+count>FRAME_LEN) count=FRAME_LEN-offset;
            send_word(offset,count,(offset==0),(offset+count==FRAME_LEN));
            offset=offset+count;
        end
        repeat(100) @(posedge clk);
        if(frame_error || got!=0)
            $fatal(1,"WIDTH=%0d stale session was not silently discarded",DATA_WIDTH);
        $display("PASS: parallel DATA RX stale-session discard");

        // A valid frame with an unexpected frame sequence is rejected.
        @(negedge clk); rst=1; got=0; expected_session_id=64'h0102030405060708;
        expected_frame_sequence_override=1;
        repeat(3) @(posedge clk); @(negedge clk); rst=0;
        offset=0;
        while(offset<FRAME_LEN) begin
            if(offset<28) count=WORD_BYTES;
            else if(offset<28+PAYLOAD_LEN) begin
                count=WORD_BYTES; if(offset+count>28+PAYLOAD_LEN) count=28+PAYLOAD_LEN-offset;
            end else count=WORD_BYTES;
            if(offset+count>FRAME_LEN) count=FRAME_LEN-offset;
            send_word(offset,count,(offset==0),(offset+count==FRAME_LEN));
            offset=offset+count;
        end
        repeat(100) @(posedge clk);
        if(!frame_error || got!=0)
            $fatal(1,"WIDTH=%0d unexpected frame sequence was not rejected",DATA_WIDTH);
        $display("PASS: parallel DATA RX frame-sequence rejection");

        // Reset while a validated payload is stalled must flush the frame.
        @(negedge clk); rst=1; got=0; expected_session_id=64'h0102030405060708;
        expected_frame_sequence_override=0;
        force_stall=1;
        repeat(3) @(posedge clk); @(negedge clk); rst=0;
        offset=0;
        while(offset<FRAME_LEN) begin
            if(offset<28) count=WORD_BYTES;
            else if(offset<28+PAYLOAD_LEN) begin
                count=WORD_BYTES; if(offset+count>28+PAYLOAD_LEN) count=28+PAYLOAD_LEN-offset;
            end else count=WORD_BYTES;
            if(offset+count>FRAME_LEN) count=FRAME_LEN-offset;
            send_word(offset,count,(offset==0),(offset+count==FRAME_LEN));
            offset=offset+count;
        end
        while(!frame_valid_pulse && cycles<5000) @(posedge clk);
        @(negedge clk); rst=1;
        repeat(3) @(posedge clk); @(negedge clk); rst=0;
        force_stall=0;
        repeat(4) @(posedge clk);
        if(out_valid || got!=0 || frame_error)
            $fatal(1,"WIDTH=%0d reset did not flush stalled output",DATA_WIDTH);
        $display("PASS: parallel DATA RX reset during stalled output");

        if(KEEP_WIDTH>1) begin
            @(negedge clk); rst=1;
            repeat(3) @(posedge clk); @(negedge clk); rst=0;
            @(negedge clk); in_data=0; in_keep=0; in_keep[KEEP_WIDTH-1]=1; if(KEEP_WIDTH>2) in_keep[0]=1;
            in_sop=1; in_eop=0; in_valid=1;
            while(!in_ready) @(negedge clk);
            @(posedge clk); @(negedge clk); in_valid=0; in_sop=0; in_keep=0;
            repeat(4) @(posedge clk);
            if(!frame_error || out_valid)
                $fatal(1,"WIDTH=%0d non-contiguous KEEP was not rejected",DATA_WIDTH);
            $display("PASS: parallel DATA RX rejects non-contiguous KEEP");
        end

        // A new SOP during an incomplete frame must flag the abandoned frame,
        // resynchronize immediately, and still deliver the following valid frame.
        @(negedge clk); rst=1; got=0; expected_session_id=64'h0102030405060708;
        expected_frame_sequence_override=0; force_stall=0;
        repeat(3) @(posedge clk); @(negedge clk); rst=0;
        send_word(0,WORD_BYTES,1'b1,1'b0);
        offset=0;
        while(offset<FRAME_LEN) begin
            count=WORD_BYTES;
            if(offset+count>FRAME_LEN) count=FRAME_LEN-offset;
            send_word(offset,count,(offset==0),(offset+count==FRAME_LEN));
            offset=offset+count;
        end
        while(got<PAYLOAD_LEN && cycles<8000) @(posedge clk);
        repeat(3) @(posedge clk);
        if(got!=PAYLOAD_LEN || !frame_error || out_lane_id!=8'ha5)
            $fatal(1,"WIDTH=%0d premature-SOP resynchronization failed got=%0d err=%b lane=%h",
                   DATA_WIDTH,got,frame_error,out_lane_id);
        $display("PASS: parallel DATA RX premature-SOP resynchronization");

        $finish;
    end
endmodule
