// SPDX-License-Identifier: BSD-2-Clause
// Reconstruct frame SOP/EOP from a raw byte stream. No sideband framing is
// assumed on the physical serial link. Header CRC16 protects the length field.
module bonded_wire_rx_framer #(
    parameter integer MAX_FRAME_BODY = 4100
) (
    input wire clk,
    input wire rst,
    input wire in_valid,
    output wire in_ready,
    input wire [7:0] in_data,
    output wire out_valid,
    input wire out_ready,
    output wire [7:0] out_data,
    output wire out_sop,
    output wire out_eop,
    output reg frame_error
);
    localparam [2:0] ST_SEARCH=3'd0, ST_HEADER=3'd1,
                     ST_RESCAN=3'd2, ST_REPLAY=3'd3, ST_BODY=3'd4;
    reg [2:0] state;
    reg [7:0] header_mem[0:23];
    reg [7:0] shift0,shift1,shift2;
    reg [4:0] header_count,replay_index,scan_index;
    reg [15:0] header_crc;
    reg [15:0] body_remaining;
    wire [15:0] header_body_length={header_mem[20],header_mem[21]};
    wire replay_valid=(state==ST_REPLAY);
    wire body_valid=(state==ST_BODY) && in_valid;
    wire output_valid=replay_valid || body_valid;
    wire [7:0] output_data=replay_valid ? header_mem[replay_index] : in_data;

    integer j;
    reg [15:0] crc_tmp;

    function [15:0] crc16_byte(input [15:0] ci,input [7:0] d);
        integer k; reg [15:0] c;
        begin
            c=ci^{d,8'h00};
            for(k=0;k<8;k=k+1)c=c[15]?((c<<1)^16'h1021):(c<<1);
            crc16_byte=c;
        end
    endfunction

    assign in_ready=!rst && ((state==ST_SEARCH) || (state==ST_HEADER) ||
                              (state==ST_BODY && out_ready));
    assign out_valid=!rst && output_valid;
    assign out_data=output_data;
    assign out_sop=out_valid && replay_valid && (replay_index==0);
    assign out_eop=out_valid && body_valid && (body_remaining==1);

    always @(posedge clk) begin
        if(rst) begin
            state<=ST_SEARCH;shift0<=0;shift1<=0;shift2<=0;
            header_count<=0;replay_index<=0;scan_index<=0;
            header_crc<=16'hffff;body_remaining<=0;frame_error<=0;
        end else begin
            if(state==ST_SEARCH && in_valid && in_ready) begin
                if(shift0==8'h53 && shift1==8'h42 && shift2==8'h01 &&
                   (in_data==8'h01 || in_data==8'h02)) begin
                    header_mem[0]<=shift0;header_mem[1]<=shift1;
                    header_mem[2]<=shift2;header_mem[3]<=in_data;
                    header_count<=4;
                    crc_tmp=16'hffff;
                    crc_tmp=crc16_byte(crc_tmp,shift0);
                    crc_tmp=crc16_byte(crc_tmp,shift1);
                    crc_tmp=crc16_byte(crc_tmp,shift2);
                    header_crc<=crc16_byte(crc_tmp,in_data);
                    shift0<=0;shift1<=0;shift2<=0;
                    state<=ST_HEADER;
                end else begin
                    shift0<=shift1;shift1<=shift2;shift2<=in_data;
                end
            end

            if(state==ST_HEADER && in_valid && in_ready) begin
                header_mem[header_count]<=in_data;
                if(header_count<22) header_crc<=crc16_byte(header_crc,in_data);
                if(header_count==23) begin
                    if(header_mem[0]==8'h53 && header_mem[1]==8'h42 &&
                       header_mem[2]==8'h01 &&
                       (header_mem[3]==8'h01 || header_mem[3]==8'h02) &&
                       {header_mem[22],in_data}==header_crc &&
                       header_body_length!=0 && header_body_length<=MAX_FRAME_BODY) begin
                        body_remaining<=header_body_length+16'd4;
                        replay_index<=0;
                        state<=ST_REPLAY;
                    end else begin
                        frame_error<=1'b1;
                        scan_index<=1;
                        state<=ST_RESCAN;
                    end
                    header_count<=0;
                end else header_count<=header_count+1'b1;
            end

            if(state==ST_RESCAN) begin
                if(scan_index<=20 &&
                   header_mem[scan_index]==8'h53 &&
                   header_mem[scan_index+1'b1]==8'h42 &&
                   header_mem[scan_index+2'd2]==8'h01 &&
                   (header_mem[scan_index+2'd3]==8'h01 ||
                    header_mem[scan_index+2'd3]==8'h02)) begin
                    crc_tmp=16'hffff;
                    for(j=0;j<24;j=j+1)
                        if(j<22 && j<(24-scan_index))
                            crc_tmp=crc16_byte(crc_tmp,header_mem[scan_index+j]);
                    for(j=0;j<24;j=j+1)
                        if(j<(24-scan_index))
                            header_mem[j]<=header_mem[scan_index+j];
                    header_count<=24-scan_index;
                    header_crc<=crc_tmp;
                    state<=ST_HEADER;
                end else if(scan_index==20) begin
                    shift0<=header_mem[21];
                    shift1<=header_mem[22];
                    shift2<=header_mem[23];
                    state<=ST_SEARCH;
                    scan_index<=0;
                end else scan_index<=scan_index+1'b1;
            end

            if(state==ST_REPLAY && out_valid && out_ready) begin
                if(replay_index==23) begin
                    replay_index<=0;
                    state<=ST_BODY;
                end else replay_index<=replay_index+1'b1;
            end

            if(state==ST_BODY && in_valid && in_ready) begin
                if(body_remaining==1) begin
                    body_remaining<=0;
                    shift0<=0;shift1<=0;shift2<=0;
                    state<=ST_SEARCH;
                end else body_remaining<=body_remaining-1'b1;
            end
        end
    end
endmodule
