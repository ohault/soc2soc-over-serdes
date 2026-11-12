// SPDX-License-Identifier: BSD-2-Clause
// Parallel-word v0 DATA frame decoder. Buffers a complete frame and releases
// payload only after header CRC-16, frame CRC-32C and sequence/session checks.
module bonded_wire_rx_lane_parallel #(
    parameter integer DATA_WIDTH=32,
    parameter integer KEEP_WIDTH=DATA_WIDTH/8,
    parameter integer LANE_ID=0,
    parameter integer MAX_PAYLOAD=4096,
    parameter integer DYNAMIC_LANE_ID=0
) (
    input wire clk, input wire rst,
    input wire [63:0] expected_session_id,
    input wire [31:0] expected_frame_sequence_override,
    input wire [7:0] expected_lane_id,
    input wire in_valid, output wire in_ready,
    input wire [DATA_WIDTH-1:0] in_data,
    input wire [KEEP_WIDTH-1:0] in_keep,
    input wire in_sop, input wire in_eop,
    output wire out_valid, input wire out_ready,
    output reg [DATA_WIDTH-1:0] out_data,
    output reg [KEEP_WIDTH-1:0] out_keep,
    output wire out_sop, output wire out_eop,
    output reg [31:0] out_packet_sequence,
    output reg [31:0] out_frame_sequence,
    output reg [7:0] out_lane_id,
    output reg [31:0] expected_frame_sequence,
    output reg frame_error, output reg frame_valid_pulse
);
    localparam integer WORD_BYTES=DATA_WIDTH/8;
    localparam integer MAX_FRAME=24+4+MAX_PAYLOAD+4;
    localparam [1:0] ST_IDLE=0, ST_COLLECT=1, ST_CHECK=2, ST_OUTPUT=3;
    reg [1:0] state;
    reg [7:0] frame_mem[0:MAX_FRAME-1];
    reg [12:0] rx_count;
    reg [12:0] output_index;
    reg [12:0] payload_length;
    reg [15:0] header_crc_calc;
    reg [31:0] frame_crc_calc;
    reg [7:0] tail0,tail1,tail2,tail3;
    reg [31:0] frame_sequence_received;
    integer byte_count;

    // Update integrity state as bytes arrive. The four-byte rolling tail keeps
    // the received CRC trailer out of the CRC-32C calculation.
    task capture_word;
        input integer base_index;
        input [DATA_WIDTH-1:0] word_data;
        input [KEEP_WIDTH-1:0] word_keep;
        input reset_crc;
        integer n;
        reg [15:0] h;
        reg [31:0] f;
        reg [7:0] t0,t1,t2,t3;
        begin
            h=reset_crc ? 16'hffff : header_crc_calc;
            f=reset_crc ? 32'hffffffff : frame_crc_calc;
            t0=reset_crc ? 8'h00 : tail0;
            t1=reset_crc ? 8'h00 : tail1;
            t2=reset_crc ? 8'h00 : tail2;
            t3=reset_crc ? 8'h00 : tail3;
            for(n=0;n<KEEP_WIDTH;n=n+1) begin
                if(word_keep[n]) begin
                    if(base_index+n<22)
                        h=crc16_byte(h,word_data[n*8 +: 8]);
                    if(base_index+n>=4)
                        f=crc32_byte(f,t3);
                    t3=t2; t2=t1; t1=t0; t0=word_data[n*8 +: 8];
                    frame_mem[base_index+n]<=word_data[n*8 +: 8];
                end
            end
            header_crc_calc<=h;
            frame_crc_calc<=f;
            tail0<=t0; tail1<=t1; tail2<=t2; tail3<=t3;
        end
    endtask

    function keep_contiguous(input [KEEP_WIDTH-1:0] keep);
        begin keep_contiguous=(keep!=0)&&((keep&(keep+1'b1))==0); end
    endfunction
    function integer count_keep(input [KEEP_WIDTH-1:0] keep);
        integer n;
        begin count_keep=0; for(n=0;n<KEEP_WIDTH;n=n+1) count_keep=count_keep+keep[n]; end
    endfunction
    function [15:0] crc16_byte(input [15:0] ci,input [7:0] d);
        integer k; reg [15:0] c;
        begin c=ci^{d,8'h00}; for(k=0;k<8;k=k+1)c=c[15]?((c<<1)^16'h1021):(c<<1); crc16_byte=c; end
    endfunction
    function [31:0] crc32_byte(input [31:0] ci,input [7:0] d);
        integer k; reg [31:0] c;
        begin c=ci^d; for(k=0;k<8;k=k+1)c=c[0]?((c>>1)^32'h82f63b78):(c>>1); crc32_byte=c; end
    endfunction

    assign in_ready=!rst&&(state==ST_IDLE||state==ST_COLLECT);
    assign out_valid=!rst&&(state==ST_OUTPUT);
    assign out_sop=out_valid&&(output_index==0);
    assign out_eop=out_valid&&(output_index+count_keep(out_keep)>=payload_length);

    always @* begin
        out_data={DATA_WIDTH{1'b0}};
        out_keep={KEEP_WIDTH{1'b0}};
        for(integer b=0;b<WORD_BYTES;b=b+1) begin
            if(output_index+b<payload_length) begin
                out_data[b*8 +: 8]=frame_mem[28+output_index+b];
                out_keep[b]=1'b1;
            end
        end
        if(state==ST_OUTPUT && payload_length==0) begin
            out_data=0; out_keep={KEEP_WIDTH{1'b0}};
        end
    end

    always @(posedge clk) begin
        if(rst) begin
            state<=ST_IDLE; rx_count<=0; output_index<=0; payload_length<=0;
            header_crc_calc<=16'hffff; frame_crc_calc<=32'hffffffff;
            tail0<=0; tail1<=0; tail2<=0; tail3<=0;
            out_packet_sequence<=0; out_frame_sequence<=0; out_lane_id<=0;
            expected_frame_sequence<=0; frame_error<=0; frame_valid_pulse<=0;
        end else begin
            frame_valid_pulse<=0;
            if(in_valid&&in_ready) begin
                if(state==ST_IDLE) begin
                    if(!in_sop || expected_session_id==0 || !keep_contiguous(in_keep)) begin
                        frame_error<=1;
                    end else begin
                        byte_count=count_keep(in_keep);
                        if(byte_count>MAX_FRAME) begin frame_error<=1; end
                        else begin
                            capture_word(0,in_data,in_keep,1'b1);
                            rx_count<=byte_count; state<=in_eop?ST_CHECK:ST_COLLECT;
                        end
                    end
                end else begin
                    if(in_sop) begin
                        // Explicit SOP is a resynchronization point.
                        frame_error<=1; byte_count=count_keep(in_keep);
                        if(!keep_contiguous(in_keep)||byte_count>MAX_FRAME) begin
                            state<=ST_IDLE; rx_count<=0;
                        end else begin
                            capture_word(0,in_data,in_keep,1'b1);
                            rx_count<=byte_count; state<=in_eop?ST_CHECK:ST_COLLECT;
                        end
                    end else begin
                        byte_count=count_keep(in_keep);
                        if(!keep_contiguous(in_keep)||
                           rx_count+byte_count>MAX_FRAME) begin
                            frame_error<=1; state<=ST_IDLE; rx_count<=0;
                        end else begin
                            capture_word(rx_count,in_data,in_keep,1'b0);
                            rx_count<=rx_count+byte_count;
                            if(in_eop) state<=ST_CHECK;
                        end
                    end
                end
            end

            if(state==ST_CHECK) begin
                frame_sequence_received={frame_mem[16],frame_mem[17],frame_mem[18],frame_mem[19]};
                if(rx_count<32 || frame_mem[0]!=8'h53 || frame_mem[1]!=8'h42 ||
                   frame_mem[2]!=8'h01 || frame_mem[3]!=8'h01 || frame_mem[4]!=0 ||
                   (DYNAMIC_LANE_ID ? ((expected_lane_id!=8'hff)&&(frame_mem[5]!=expected_lane_id)) : (frame_mem[5]!=LANE_ID[7:0])) ||
                   frame_mem[6]!=0 || frame_mem[7]!=8'h18 ||
                   {frame_mem[22],frame_mem[23]}!=header_crc_calc ||
                   {frame_mem[20],frame_mem[21]}<4 ||
                   {frame_mem[20],frame_mem[21]}>MAX_PAYLOAD+4 ||
                   rx_count!=24+{frame_mem[20],frame_mem[21]}+4 ||
                   {tail3,tail2,tail1,tail0}!=~frame_crc_calc) begin
                    frame_error<=1; state<=ST_IDLE; rx_count<=0;
                end else if({frame_mem[8],frame_mem[9],frame_mem[10],frame_mem[11],
                             frame_mem[12],frame_mem[13],frame_mem[14],frame_mem[15]}!=expected_session_id) begin
                    // Stale session frames are discarded without reporting link corruption.
                    state<=ST_IDLE; rx_count<=0;
                end else if(frame_sequence_received!=expected_frame_sequence_override ||
                            expected_frame_sequence_override==32'hffffffff) begin
                    frame_error<=1; state<=ST_IDLE; rx_count<=0;
                end else begin
                    out_packet_sequence<={frame_mem[24],frame_mem[25],frame_mem[26],frame_mem[27]};
                    out_frame_sequence<=frame_sequence_received; out_lane_id<=frame_mem[5];
                    expected_frame_sequence<=frame_sequence_received+1'b1;
                    payload_length<={frame_mem[20],frame_mem[21]}-16'd4;
                    output_index<=0; frame_valid_pulse<=1; state<=ST_OUTPUT;
                end
            end

            if(state==ST_OUTPUT && out_valid && out_ready) begin
                if(payload_length==0 || output_index+count_keep(out_keep)>=payload_length) begin
                    state<=ST_IDLE; rx_count<=0;
                end else output_index<=output_index+count_keep(out_keep);
            end
        end
    end

    `ifndef SYNTHESIS
    initial begin
        if((DATA_WIDTH!=8)&&(DATA_WIDTH!=16)&&(DATA_WIDTH!=32)) $error("DATA_WIDTH must be 8, 16 or 32");
        if(KEEP_WIDTH!=WORD_BYTES) $error("KEEP_WIDTH must equal DATA_WIDTH/8");
        if(MAX_PAYLOAD<1||MAX_PAYLOAD>4096) $error("MAX_PAYLOAD must be 1..4096");
    end
    `endif
endmodule
