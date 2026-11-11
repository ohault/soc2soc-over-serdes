// SPDX-License-Identifier: BSD-2-Clause
// Buffered, byte-stream v0 DATA frame decoder. Payload is released only after
// the complete frame, header CRC-16 and frame CRC-32C have been validated.
module bonded_wire_rx_lane #(
    parameter integer LANE_ID = 0,
    parameter integer MAX_PAYLOAD = 4096,
    parameter integer DYNAMIC_LANE_ID = 0
) (
    input wire clk, input wire rst,
    input wire [63:0] expected_session_id,
    input wire [31:0] expected_frame_sequence_override,
    input wire [7:0] expected_lane_id,
    input wire in_valid, output wire in_ready,
    input wire [7:0] in_data, input wire in_sop, input wire in_eop,
    output wire out_valid, input wire out_ready,
    output wire [7:0] out_data, output wire out_sop, output wire out_eop,
    output reg [31:0] out_packet_sequence,
    output reg [31:0] out_frame_sequence,
    output reg [7:0] out_lane_id,
    output reg [31:0] expected_frame_sequence,
    output reg frame_error, output reg frame_valid_pulse
);
    localparam integer MAX_FRAME = 24 + 4 + MAX_PAYLOAD + 4;
    localparam [1:0] ST_IDLE=2'd0, ST_COLLECT=2'd1,
                     ST_CHECK=2'd2, ST_OUTPUT=2'd3;
    reg [1:0] state;
    reg [7:0] frame_mem [0:MAX_FRAME-1];
    reg [12:0] rx_count;
    reg [7:0] tail0, tail1, tail2, tail3;
    reg [15:0] header_crc;
    reg [31:0] frame_crc;
    reg [15:0] payload_length;
    reg [12:0] output_index;
    reg [63:0] active_session;

    function [15:0] crc16_byte(input [15:0] crc_in,input [7:0] data);
        integer k; reg [15:0] c;
        begin
            c=crc_in ^ {data,8'h00};
            for(k=0;k<8;k=k+1)
                c=c[15] ? ((c<<1)^16'h1021) : (c<<1);
            crc16_byte=c;
        end
    endfunction
    function [31:0] crc32c_byte(input [31:0] crc_in,input [7:0] data);
        integer k; reg [31:0] c;
        begin
            c=crc_in ^ data;
            for(k=0;k<8;k=k+1)
                c=c[0] ? ((c>>1)^32'h82f63b78) : (c>>1);
            crc32c_byte=c;
        end
    endfunction

    assign in_ready = !rst && (state==ST_IDLE || state==ST_COLLECT);
    assign out_valid = !rst && (state==ST_OUTPUT);
    assign out_data = frame_mem[28+output_index];
    assign out_sop = out_valid && (output_index==0);
    assign out_eop = out_valid && (output_index+1'b1==payload_length);

    always @(posedge clk) begin
        if(rst) begin
            state<=ST_IDLE; rx_count<=0;
            tail0<=0; tail1<=0; tail2<=0; tail3<=0;
            header_crc<=16'hffff; frame_crc<=32'hffffffff;
            payload_length<=0; output_index<=0; active_session<=0;
            out_packet_sequence<=0; out_frame_sequence<=0; out_lane_id<=0;
            expected_frame_sequence<=0; frame_error<=0; frame_valid_pulse<=0;
        end else begin
            frame_valid_pulse<=0;
            if(in_valid && in_ready) begin
                if(state==ST_IDLE) begin
                    if(!in_sop || in_eop || expected_session_id==0) begin
                        frame_error<=1;
                    end else begin
                        state<=ST_COLLECT; rx_count<=1;
                        frame_mem[0]<=in_data;
                        tail0<=in_data; tail1<=0; tail2<=0; tail3<=0;
                        header_crc<=crc16_byte(16'hffff,in_data);
                        frame_crc<=32'hffffffff;
                        active_session<=expected_session_id;
                    end
                end else begin
                    if(in_sop) begin
                        // A fresh SOP is an explicit resynchronization point:
                        // discard the truncated frame and start collecting anew.
                        frame_error<=1; state<=ST_COLLECT; rx_count<=1;
                        frame_mem[0]<=in_data;
                        tail0<=in_data; tail1<=0; tail2<=0; tail3<=0;
                        header_crc<=crc16_byte(16'hffff,in_data);
                        frame_crc<=32'hffffffff;
                        active_session<=expected_session_id;
                    end else if(rx_count>=MAX_FRAME) begin
                        frame_error<=1; state<=ST_IDLE; rx_count<=0;
                    end else begin
                        frame_mem[rx_count]<=in_data;
                        if(rx_count<22)
                            header_crc<=crc16_byte(header_crc,in_data);
                        if(rx_count>=4)
                            frame_crc<=crc32c_byte(frame_crc,tail3);
                        tail3<=tail2; tail2<=tail1; tail1<=tail0; tail0<=in_data;
                        rx_count<=rx_count+1'b1;
                        if(in_eop) state<=ST_CHECK;
                    end
                end
            end

            if(state==ST_CHECK) begin
                if(frame_mem[0]!=8'h53 || frame_mem[1]!=8'h42 ||
                   frame_mem[2]!=8'h01 || frame_mem[3]!=8'h01 ||
                   frame_mem[4]!=8'h00 || frame_mem[5]>8'd1 ||
                   (DYNAMIC_LANE_ID ? ((expected_lane_id!=8'hff) && (frame_mem[5]!=expected_lane_id)) : (frame_mem[5]!=LANE_ID[7:0])) ||
                   frame_mem[6]!=8'h00 || frame_mem[7]!=8'h18 ||
                   {frame_mem[22],frame_mem[23]}!=header_crc ||
                   {frame_mem[20],frame_mem[21]}<4 ||
                   {frame_mem[20],frame_mem[21]}>MAX_PAYLOAD+4 ||
                   rx_count!=(24+{frame_mem[20],frame_mem[21]}+4) ||
                   {tail3,tail2,tail1,tail0}!=~frame_crc) begin
                    frame_error<=1; state<=ST_IDLE; rx_count<=0;
                end else if({frame_mem[8],frame_mem[9],frame_mem[10],frame_mem[11],
                             frame_mem[12],frame_mem[13],frame_mem[14],frame_mem[15]}!=active_session) begin
                    // A complete frame from an older or unadopted session is
                    // stale, not a physical-lane framing error.
                    state<=ST_IDLE;rx_count<=0;
                end else if({frame_mem[16],frame_mem[17],frame_mem[18],frame_mem[19]}!=expected_frame_sequence_override ||
                            expected_frame_sequence_override==32'hffffffff) begin
                    frame_error<=1;state<=ST_IDLE;rx_count<=0;
                end else begin
                    out_packet_sequence<={frame_mem[24],frame_mem[25],frame_mem[26],frame_mem[27]};
                    out_frame_sequence<=expected_frame_sequence_override;
                    out_lane_id<=frame_mem[5];
                    expected_frame_sequence<=expected_frame_sequence_override+1'b1;
                    payload_length<={frame_mem[20],frame_mem[21]}-16'd4;
                    output_index<=0; frame_valid_pulse<=1;
                    if({frame_mem[20],frame_mem[21]}==4) begin
                        // Represent a legal empty DATA packet by one zero-byte
                        // SOP/EOP marker on this byte-stream interface.
                        payload_length<=1; frame_mem[28]<=0;
                    end
                    state<=ST_OUTPUT;
                end
            end

            if(state==ST_OUTPUT && out_valid && out_ready) begin
                if(output_index+1'b1>=payload_length) begin
                    state<=ST_IDLE; rx_count<=0;
                end else output_index<=output_index+1'b1;
            end
        end
    end
endmodule
