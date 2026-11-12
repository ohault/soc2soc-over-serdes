// SPDX-License-Identifier: BSD-2-Clause
`timescale 1ns/1ps
// Side-by-side behavioural comparison of the byte-array reference and the
// synchronous payload-RAM candidate. The two implementations may have
// different latency; this test compares accepted payload streams and metadata.
module tb_bonded_wire_rx_lane_parallel_differential;
    parameter integer DATA_WIDTH=32;
    parameter integer PAYLOAD_LEN=7;
    localparam integer KEEP_WIDTH=DATA_WIDTH/8;
    localparam integer FRAME_LEN=24+4+PAYLOAD_LEN+4;
    localparam integer WORD_BYTES=DATA_WIDTH/8;

    reg clk=0; always #5 clk=~clk;
    reg rst=1;
    reg [63:0] expected_session_id=64'h0102030405060708;
    reg [31:0] expected_frame_sequence_override=0;
    reg [7:0] expected_lane_id=8'ha5;
    reg in_valid=0,in_sop=0,in_eop=0;
    wire in_ready_ref,in_ready_ram;
    reg [DATA_WIDTH-1:0] in_data=0;
    reg [KEEP_WIDTH-1:0] in_keep=0;
    wire ref_valid,ref_sop,ref_eop,ram_valid,ram_sop,ram_eop;
    reg out_ready=0;
    wire [DATA_WIDTH-1:0] ref_data,ram_data;
    wire [KEEP_WIDTH-1:0] ref_keep,ram_keep;
    wire [31:0] ref_packet,ref_frame,ref_expected,ram_packet,ram_frame,ram_expected;
    wire [7:0] ref_lane,ram_lane;
    wire ref_error,ref_pulse,ram_error,ram_pulse;

    reg [7:0] frame[0:FRAME_LEN-1];
    reg [7:0] payload[0:((PAYLOAD_LEN>0)?PAYLOAD_LEN:1)-1];
    reg [7:0] ref_bytes[0:((PAYLOAD_LEN>0)?PAYLOAD_LEN:1)-1];
    reg [7:0] ram_bytes[0:((PAYLOAD_LEN>0)?PAYLOAD_LEN:1)-1];
    reg [15:0] hcrc;
    reg [31:0] fcrc;
    integer i,j,offset,count,got_ref=0,got_ram=0,cycles=0,watchdog;
    reg ref_eop_seen=0,ram_eop_seen=0;
    reg ref_stalled=0,ram_stalled=0;
    reg [DATA_WIDTH-1:0] ref_stall_data,ram_stall_data;
    reg [KEEP_WIDTH-1:0] ref_stall_keep,ram_stall_keep;
    reg ref_stall_sop,ref_stall_eop,ram_stall_sop,ram_stall_eop;

    bonded_wire_rx_lane_parallel #(
        .DATA_WIDTH(DATA_WIDTH),.LANE_ID(0),.DYNAMIC_LANE_ID(1)
    ) reference_rx (
        .clk(clk),.rst(rst),.expected_session_id(expected_session_id),
        .expected_frame_sequence_override(expected_frame_sequence_override),
        .expected_lane_id(expected_lane_id),.in_valid(in_valid),.in_ready(in_ready_ref),
        .in_data(in_data),.in_keep(in_keep),.in_sop(in_sop),.in_eop(in_eop),
        .out_valid(ref_valid),.out_ready(out_ready),.out_data(ref_data),.out_keep(ref_keep),
        .out_sop(ref_sop),.out_eop(ref_eop),.out_packet_sequence(ref_packet),
        .out_frame_sequence(ref_frame),.out_lane_id(ref_lane),
        .expected_frame_sequence(ref_expected),.frame_error(ref_error),
        .frame_valid_pulse(ref_pulse)
    );

    bonded_wire_rx_lane_parallel_ram #(
        .DATA_WIDTH(DATA_WIDTH),.LANE_ID(0),.DYNAMIC_LANE_ID(1)
    ) candidate_rx (
        .clk(clk),.rst(rst),.expected_session_id(expected_session_id),
        .expected_frame_sequence_override(expected_frame_sequence_override),
        .expected_lane_id(expected_lane_id),.in_valid(in_valid),.in_ready(in_ready_ram),
        .in_data(in_data),.in_keep(in_keep),.in_sop(in_sop),.in_eop(in_eop),
        .out_valid(ram_valid),.out_ready(out_ready),.out_data(ram_data),.out_keep(ram_keep),
        .out_sop(ram_sop),.out_eop(ram_eop),.out_packet_sequence(ram_packet),
        .out_frame_sequence(ram_frame),.out_lane_id(ram_lane),
        .expected_frame_sequence(ram_expected),.frame_error(ram_error),
        .frame_valid_pulse(ram_pulse)
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
            @(negedge clk);
            in_data=0; in_keep=0;
            for(q=0;q<bytes;q=q+1) begin
                in_data[q*8 +: 8]=frame[start+q];
                in_keep[q]=1;
            end
            in_sop=first; in_eop=last; in_valid=1;
            while(!in_ready_ref || !in_ready_ram) @(negedge clk);
            @(posedge clk);
            @(negedge clk);
            in_valid=0; in_sop=0; in_eop=0; in_keep=0;
        end
    endtask

    always @(posedge clk) begin
        if(!rst) begin
            // Input-ready may legitimately differ because the RAM candidate
            // has additional synchronous-read latency; the driver waits for both.
            out_ready <= ((cycles%5)!=1);
            cycles=cycles+1;

            if(ref_stalled && (!ref_valid || ref_data!==ref_stall_data ||
               ref_keep!==ref_stall_keep || ref_sop!==ref_stall_sop || ref_eop!==ref_stall_eop))
                $fatal(1,"WIDTH=%0d reference output changed while stalled",DATA_WIDTH);
            if(ram_stalled && (!ram_valid || ram_data!==ram_stall_data ||
               ram_keep!==ram_stall_keep || ram_sop!==ram_stall_sop || ram_eop!==ram_stall_eop))
                $fatal(1,"WIDTH=%0d RAM candidate output changed while stalled",DATA_WIDTH);
            ref_stalled <= ref_valid && !out_ready;
            ram_stalled <= ram_valid && !out_ready;
            if(ref_valid && !out_ready) begin
                ref_stall_data<=ref_data; ref_stall_keep<=ref_keep;
                ref_stall_sop<=ref_sop; ref_stall_eop<=ref_eop;
            end
            if(ram_valid && !out_ready) begin
                ram_stall_data<=ram_data; ram_stall_keep<=ram_keep;
                ram_stall_sop<=ram_sop; ram_stall_eop<=ram_eop;
            end
            if(ref_valid && out_ready) begin
                if(got_ref==0 && !ref_sop) $fatal(1,"reference missing SOP");
                for(j=0;j<KEEP_WIDTH;j=j+1) if(ref_keep[j]) begin
                    if(got_ref>=PAYLOAD_LEN) $fatal(1,"reference emitted excess bytes");
                    ref_bytes[got_ref]=ref_data[j*8 +: 8];
                    got_ref=got_ref+1;
                end
                if(ref_eop) begin
                    ref_eop_seen=1;
                    if(got_ref!=PAYLOAD_LEN) $fatal(1,"reference early EOP");
                end
            end

            if(ram_valid && out_ready) begin
                if(got_ram==0 && !ram_sop) $fatal(1,"RAM candidate missing SOP");
                for(j=0;j<KEEP_WIDTH;j=j+1) if(ram_keep[j]) begin
                    if(got_ram>=PAYLOAD_LEN) $fatal(1,"RAM candidate emitted excess bytes");
                    ram_bytes[got_ram]=ram_data[j*8 +: 8];
                    got_ram=got_ram+1;
                end
                if(ram_eop) begin
                    ram_eop_seen=1;
                    if(got_ram!=PAYLOAD_LEN) $fatal(1,"RAM candidate early EOP");
                end
            end
        end
    end

    task build_frame;
        begin
            frame[0]=8'h53; frame[1]=8'h42; frame[2]=1; frame[3]=1;
            frame[4]=0; frame[5]=8'ha5; frame[6]=0; frame[7]=24;
            frame[8]=1; frame[9]=2; frame[10]=3; frame[11]=4;
            frame[12]=5; frame[13]=6; frame[14]=7; frame[15]=8;
            frame[16]=0; frame[17]=0; frame[18]=0; frame[19]=0;
            frame[20]=(PAYLOAD_LEN+4)>>8; frame[21]=(PAYLOAD_LEN+4)&8'hff;
            hcrc=16'hffff;
            for(i=0;i<22;i=i+1) hcrc=crc16_byte(hcrc,frame[i]);
            frame[22]=hcrc[15:8]; frame[23]=hcrc[7:0];
            frame[24]=8'h11; frame[25]=8'h22; frame[26]=8'h33; frame[27]=8'h44;
            for(i=0;i<PAYLOAD_LEN;i=i+1) begin
                payload[i]=(i*37+8'h10)&8'hff;
                frame[28+i]=payload[i];
            end
            fcrc=32'hffffffff;
            for(i=0;i<FRAME_LEN-4;i=i+1) fcrc=crc32_byte(fcrc,frame[i]);
            frame[FRAME_LEN-4]=~fcrc[31:24]; frame[FRAME_LEN-3]=~fcrc[23:16];
            frame[FRAME_LEN-2]=~fcrc[15:8]; frame[FRAME_LEN-1]=~fcrc[7:0];
        end
    endtask

    task send_complete_frame;
        begin
            offset=0;
            while(offset<FRAME_LEN) begin
                count=WORD_BYTES;
                if(offset+count>FRAME_LEN) count=FRAME_LEN-offset;
                send_word(offset,count,(offset==0),(offset+count==FRAME_LEN));
                offset=offset+count;
            end
        end
    endtask

    initial begin
        if(DATA_WIDTH!=8 && DATA_WIDTH!=16 && DATA_WIDTH!=32)
            $fatal(1,"Unsupported DATA_WIDTH=%0d",DATA_WIDTH);
        if(PAYLOAD_LEN<0 || PAYLOAD_LEN>4096)
            $fatal(1,"PAYLOAD_LEN must be 0..4096");
        build_frame();
        repeat(4) @(posedge clk);
        @(negedge clk); rst=0;
        send_complete_frame();

        watchdog=0;
        while((!ref_eop_seen || !ram_eop_seen) && watchdog<20000) begin
            @(posedge clk); watchdog=watchdog+1;
        end
        repeat(4) @(posedge clk);
        if(!ref_eop_seen || !ram_eop_seen || got_ref!=PAYLOAD_LEN || got_ram!=PAYLOAD_LEN)
            $fatal(1,"WIDTH=%0d payload timeout ref=%0d ram=%0d",DATA_WIDTH,got_ref,got_ram);
        for(i=0;i<PAYLOAD_LEN;i=i+1)
            if(ref_bytes[i]!==ram_bytes[i] || ref_bytes[i]!==payload[i])
                $fatal(1,"WIDTH=%0d differential payload mismatch at byte %0d",DATA_WIDTH,i);
        if(ref_error || ram_error || ref_packet!=ram_packet || ref_frame!=ram_frame ||
           ref_lane!=ram_lane || ref_expected!=ram_expected)
            $fatal(1,"WIDTH=%0d differential metadata/error mismatch",DATA_WIDTH);

        // Corrupt the trailer and prove neither implementation releases data.
        @(negedge clk); rst=1; got_ref=0; got_ram=0; ref_eop_seen=0; ram_eop_seen=0; ref_stalled=0; ram_stalled=0;
        repeat(3) @(posedge clk);
        @(negedge clk); rst=0;
        frame[FRAME_LEN-1]=frame[FRAME_LEN-1]^8'h01;
        send_complete_frame();
        repeat(100) @(posedge clk);
        if(!ref_error || !ram_error || got_ref!=0 || got_ram!=0)
            $fatal(1,"WIDTH=%0d invalid frame handling differs or leaked payload",DATA_WIDTH);

        // A valid frame from an old session is silently discarded by both.
        @(negedge clk);
        rst=1; got_ref=0; got_ram=0; ref_eop_seen=0; ram_eop_seen=0;
        ref_stalled=0; ram_stalled=0;
        expected_session_id=64'h1112131415161718;
        expected_frame_sequence_override=0; expected_lane_id=8'ha5;
        repeat(3) @(posedge clk);
        @(negedge clk); rst=0;
        build_frame(); send_complete_frame();
        repeat(100) @(posedge clk);
        if(ref_error || ram_error || got_ref!=0 || got_ram!=0)
            $fatal(1,"WIDTH=%0d stale-session handling differs",DATA_WIDTH);

        // Unexpected frame sequence must be rejected by both receivers.
        @(negedge clk);
        rst=1; got_ref=0; got_ram=0; ref_eop_seen=0; ram_eop_seen=0;
        expected_session_id=64'h0102030405060708;
        expected_frame_sequence_override=1; expected_lane_id=8'ha5;
        repeat(3) @(posedge clk);
        @(negedge clk); rst=0;
        build_frame(); send_complete_frame();
        repeat(100) @(posedge clk);
        if(!ref_error || !ram_error || got_ref!=0 || got_ram!=0)
            $fatal(1,"WIDTH=%0d frame-sequence rejection differs",DATA_WIDTH);

        // Dynamic lane mismatch must also reject the frame before delivery.
        @(negedge clk);
        rst=1; got_ref=0; got_ram=0; ref_eop_seen=0; ram_eop_seen=0;
        expected_frame_sequence_override=0; expected_lane_id=8'h5a;
        repeat(3) @(posedge clk);
        @(negedge clk); rst=0;
        build_frame(); send_complete_frame();
        repeat(100) @(posedge clk);
        if(!ref_error || !ram_error || got_ref!=0 || got_ram!=0)
            $fatal(1,"WIDTH=%0d lane-mismatch rejection differs",DATA_WIDTH);

        $display("PASS differential byte-array vs RAM-backed RX DATA_WIDTH=%0d PAYLOAD_LEN=%0d",DATA_WIDTH,PAYLOAD_LEN);
        $finish;
    end
endmodule
