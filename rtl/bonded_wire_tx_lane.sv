// SPDX-License-Identifier: BSD-2-Clause
// Byte-serial v0 DATA frame encoder for one physical lane.
// Network byte order for envelope fields; payload bytes are emitted in
// little-endian order within each input beat (byte 0 first).
module bonded_wire_tx_lane #(
    parameter integer DATA_WIDTH = 32,
    parameter integer KEEP_WIDTH = DATA_WIDTH/8,
    parameter integer LANE_ID = 0
) (
    input wire clk,
    input wire rst,
    input wire [63:0] session_id,

    input wire in_valid,
    output wire in_ready,
    input wire [DATA_WIDTH-1:0] in_data,
    input wire [KEEP_WIDTH-1:0] in_keep,
    input wire in_sop,
    input wire in_eop,
    input wire [31:0] in_packet_sequence,
    input wire [15:0] in_packet_length,

    output wire out_valid,
    input wire out_ready,
    output wire [7:0] out_data,
    output wire out_sop,
    output wire out_eop,

    output reg [31:0] next_frame_sequence,
    output reg frame_error
);
    localparam [2:0] ST_IDLE=3'd0, ST_HEADER=3'd1,
                     ST_PREFIX=3'd2, ST_PAYLOAD=3'd3, ST_CRC=3'd4;
    reg [2:0] state;
    reg [5:0] header_index;
    reg [2:0] prefix_index;
    reg [1:0] crc_index;
    reg [31:0] packet_sequence;
    reg [15:0] packet_length;
    reg [63:0] active_session;
    reg [31:0] frame_sequence;
    reg [15:0] header_crc;
    reg [31:0] frame_crc;
    reg [DATA_WIDTH-1:0] payload_word;
    reg [KEEP_WIDTH-1:0] payload_keep;
    reg payload_eop;
    reg payload_loaded;
    reg [KEEP_WIDTH-1:0] payload_byte_index;
    reg [12:0] payload_bytes_seen;
    localparam integer KEEP_COUNT_WIDTH = (KEEP_WIDTH < 1) ? 1 : $clog2(KEEP_WIDTH+1);
    function [KEEP_COUNT_WIDTH-1:0] keep_count(input [KEEP_WIDTH-1:0] keep);
        integer n;
        begin
            keep_count=0;
            for(n=0;n<KEEP_WIDTH;n=n+1)
                keep_count=keep_count+keep[n];
        end
    endfunction

    function [15:0] crc16_byte(input [15:0] crc_in,input [7:0] data);
        integer k;
        reg [15:0] c;
        begin
            c=crc_in ^ {data,8'h00};
            for(k=0;k<8;k=k+1)
                c=c[15] ? ((c<<1)^16'h1021) : (c<<1);
            crc16_byte=c;
        end
    endfunction

    function [31:0] crc32c_byte(input [31:0] crc_in,input [7:0] data);
        integer k;
        reg [31:0] c;
        begin
            c=crc_in ^ data;
            for(k=0;k<8;k=k+1)
                c=c[0] ? ((c>>1)^32'h82f63b78) : (c>>1);
            crc32c_byte=c;
        end
    endfunction

    function [7:0] header_byte(input [5:0] index);
        begin
            case(index)
                0: header_byte=8'h53;
                1: header_byte=8'h42;
                2: header_byte=8'h01;
                3: header_byte=8'h01; // DATA
                4: header_byte=8'h00; // v0 flags
                5: header_byte=LANE_ID[7:0];
                6: header_byte=8'h00;
                7: header_byte=8'h18; // 24-byte header
                8: header_byte=active_session[63:56];
                9: header_byte=active_session[55:48];
                10: header_byte=active_session[47:40];
                11: header_byte=active_session[39:32];
                12: header_byte=active_session[31:24];
                13: header_byte=active_session[23:16];
                14: header_byte=active_session[15:8];
                15: header_byte=active_session[7:0];
                16: header_byte=frame_sequence[31:24];
                17: header_byte=frame_sequence[23:16];
                18: header_byte=frame_sequence[15:8];
                19: header_byte=frame_sequence[7:0];
                20: header_byte=(packet_length+16'd4)>>8;
                21: header_byte=(packet_length+16'd4);
                22: header_byte=header_crc[15:8];
                23: header_byte=header_crc[7:0];
                default: header_byte=8'h00;
            endcase
        end
    endfunction

    function keep_is_contiguous(input [KEEP_WIDTH-1:0] keep);
        begin
            keep_is_contiguous=(keep!=0) && ((keep & (keep+1'b1))==0);
        end
    endfunction

    assign in_ready = (state==ST_IDLE) ||
                      ((state==ST_PAYLOAD) && !payload_loaded);
    assign out_valid = (state==ST_HEADER) || (state==ST_PREFIX) ||
                       ((state==ST_PAYLOAD) && payload_loaded) ||
                       (state==ST_CRC);
    assign out_sop = out_valid && (state==ST_HEADER) && (header_index==0);
    assign out_eop = out_valid && (state==ST_CRC) && (crc_index==3);

    reg [7:0] byte_mux;
    integer b;
    always @* begin
        byte_mux=8'h00;
        case(state)
            ST_HEADER: begin
                if(header_index<22) byte_mux=header_byte(header_index);
                else if(header_index==22) byte_mux=header_crc[15:8];
                else byte_mux=header_crc[7:0];
            end
            ST_PREFIX: begin
                case(prefix_index)
                    0: byte_mux=packet_sequence[31:24];
                    1: byte_mux=packet_sequence[23:16];
                    2: byte_mux=packet_sequence[15:8];
                    default: byte_mux=packet_sequence[7:0];
                endcase
            end
            ST_PAYLOAD: begin
                byte_mux=payload_word[payload_byte_index*8 +: 8];
            end
            ST_CRC: begin
                case(crc_index)
                    0: byte_mux=~frame_crc[31:24];
                    1: byte_mux=~frame_crc[23:16];
                    2: byte_mux=~frame_crc[15:8];
                    default: byte_mux=~frame_crc[7:0];
                endcase
            end
            default: byte_mux=8'h00;
        endcase
    end
    assign out_data=byte_mux;

    always @(posedge clk) begin
        if(rst) begin
            state<=ST_IDLE;
            header_index<=0;
            prefix_index<=0;
            crc_index<=0;
            packet_sequence<=0;
            packet_length<=0;
            active_session<=0;
            frame_sequence<=0;
            header_crc<=16'hffff;
            frame_crc<=32'hffffffff;
            payload_word<=0;
            payload_keep<=0;
            payload_eop<=0;
            payload_loaded<=0;
            payload_byte_index<=0;
            payload_bytes_seen<=0;
            next_frame_sequence<=0;
            frame_error<=0;
        end else begin
            if(state==ST_IDLE && in_valid && in_ready) begin
                if(!in_sop || !keep_is_contiguous(in_keep) ||
                   in_packet_length>4096 || in_packet_length==0 ||
                   session_id==0 ||
                   (!in_eop && in_keep!={KEEP_WIDTH{1'b1}})) begin
                    frame_error<=1'b1;
                end else begin
                    active_session<=session_id;
                    packet_sequence<=in_packet_sequence;
                    packet_length<=in_packet_length;
                    frame_sequence<=next_frame_sequence;
                    payload_word<=in_data;
                    payload_keep<=in_keep;
                    payload_eop<=in_eop;
                    payload_loaded<=1'b1;
                    payload_byte_index<=0;
                    payload_bytes_seen<=keep_count(in_keep);
                    if ((in_eop && keep_count(in_keep)!=in_packet_length) ||
                        (!in_eop && keep_count(in_keep)>=in_packet_length))
                        frame_error<=1'b1;
                    header_index<=0;
                    prefix_index<=0;
                    crc_index<=0;
                    header_crc<=16'hffff;
                    frame_crc<=32'hffffffff;
                    state<=ST_HEADER;
                end
            end

            if(out_valid && out_ready) begin
                case(state)
                    ST_HEADER: begin
                        if(header_index<22)
                            header_crc<=crc16_byte(header_crc,byte_mux);
                        frame_crc<=crc32c_byte(frame_crc,byte_mux);
                        if(header_index==23) begin
                            header_index<=0;
                            state<=ST_PREFIX;
                        end else header_index<=header_index+1'b1;
                    end
                    ST_PREFIX: begin
                        frame_crc<=crc32c_byte(frame_crc,byte_mux);
                        if(prefix_index==3) begin
                            prefix_index<=0;
                            state<=ST_PAYLOAD;
                        end else prefix_index<=prefix_index+1'b1;
                    end
                    ST_PAYLOAD: begin
                        frame_crc<=crc32c_byte(frame_crc,byte_mux);
                        if(payload_byte_index+1'b1 >= payload_keep) begin
                            payload_loaded<=1'b0;
                            payload_byte_index<=0;
                            if(payload_eop) begin
                                state<=ST_CRC;
                                crc_index<=0;
                            end
                        end else payload_byte_index<=payload_byte_index+1'b1;
                    end
                    ST_CRC: begin
                        if(crc_index==3) begin
                            state<=ST_IDLE;
                            next_frame_sequence<=next_frame_sequence+1'b1;
                        end else crc_index<=crc_index+1'b1;
                    end
                    default: state<=ST_IDLE;
                endcase
            end

            if(state==ST_PAYLOAD && !payload_loaded && in_valid && in_ready) begin
                if(in_sop || !keep_is_contiguous(in_keep) ||
                   (!in_eop && in_keep!={KEEP_WIDTH{1'b1}})) begin
                    frame_error<=1'b1;
                    state<=ST_IDLE;
                end else begin
                    payload_word<=in_data;
                    payload_keep<=in_keep;
                    payload_eop<=in_eop;
                    payload_loaded<=1'b1;
                    payload_byte_index<=0;
                    payload_bytes_seen<=payload_bytes_seen+keep_count(in_keep);
                    if ((in_eop && payload_bytes_seen+keep_count(in_keep)!=packet_length) ||
                        (!in_eop && payload_bytes_seen+keep_count(in_keep)>=packet_length))
                        frame_error<=1'b1;
                end
            end
        end
    end
endmodule
