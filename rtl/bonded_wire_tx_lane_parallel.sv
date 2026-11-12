// SPDX-License-Identifier: BSD-2-Clause
// Parallel-word v0 DATA frame encoder. The logical wire format is unchanged:
// network-order envelope fields, little-endian byte lanes, byte 0 in [7:0].
// Supported widths are 8, 16 and 32 bits (one, two or four bytes per beat).
module bonded_wire_tx_lane_parallel #(
    parameter integer DATA_WIDTH = 32,
    parameter integer KEEP_WIDTH = DATA_WIDTH/8,
    parameter integer LANE_ID = 0
) (
    input wire clk, input wire rst,
    input wire [63:0] session_id,
    input wire frame_start_enable,
    input wire [31:0] frame_sequence,
    input wire in_valid, output wire in_ready,
    input wire [DATA_WIDTH-1:0] in_data,
    input wire [KEEP_WIDTH-1:0] in_keep,
    input wire in_sop, input wire in_eop,
    input wire [31:0] in_packet_sequence,
    input wire [15:0] in_packet_length,
    output wire out_valid, input wire out_ready,
    output reg [DATA_WIDTH-1:0] out_data,
    output reg [KEEP_WIDTH-1:0] out_keep,
    output wire out_sop, output wire out_eop,
    output reg frame_error
);
    localparam integer WORD_BYTES=DATA_WIDTH/8;
    localparam integer HEADER_WORDS=24/WORD_BYTES;
    localparam integer PREFIX_WORDS=4/WORD_BYTES;
    localparam integer CRC_WORDS=4/WORD_BYTES;
    localparam [2:0] ST_IDLE=0, ST_HEADER=1, ST_PREFIX=2,
                     ST_PAYLOAD=3, ST_CRC=4;

    reg [2:0] state;
    reg [7:0] header_mem[0:23];
    reg [7:0] header_tmp[0:23];
    reg [31:0] packet_sequence;
    reg [31:0] active_frame_sequence;
    reg [15:0] packet_length;
    reg [12:0] payload_bytes_seen;
    reg [DATA_WIDTH-1:0] payload_data;
    reg [KEEP_WIDTH-1:0] payload_keep;
    reg payload_eop, payload_valid;
    reg [5:0] header_word;
    reg [2:0] prefix_word;
    reg [2:0] crc_word;
    reg [31:0] frame_crc;
    reg [15:0] header_crc;
    reg [15:0] header_crc_tmp;
    reg [31:0] crc32_next;
    reg [15:0] unused_crc16;
    integer i;
    integer byte_count;
    integer byte_index;

    function [15:0] crc16_byte(input [15:0] ci,input [7:0] d);
        integer k; reg [15:0] c;
        begin
            c=ci^{d,8'h00};
            for(k=0;k<8;k=k+1)c=c[15]?((c<<1)^16'h1021):(c<<1);
            crc16_byte=c;
        end
    endfunction

    function keep_contiguous(input [KEEP_WIDTH-1:0] keep);
        begin keep_contiguous=(keep!=0)&&((keep&(keep+1'b1))==0); end
    endfunction

    function integer count_keep(input [KEEP_WIDTH-1:0] keep);
        integer n;
        begin
            count_keep=0;
            for(n=0;n<KEEP_WIDTH;n=n+1) count_keep=count_keep+keep[n];
        end
    endfunction

    wire payload_can_accept = (state==ST_PAYLOAD) &&
        (!payload_valid || (out_ready && payload_valid && !payload_eop));
    assign in_ready = !rst && (((state==ST_IDLE) && frame_start_enable) ||
                                payload_can_accept);
    assign out_valid = !rst && ((state==ST_HEADER)||(state==ST_PREFIX)||
                                ((state==ST_PAYLOAD)&&payload_valid)||(state==ST_CRC));
    assign out_sop = out_valid && (state==ST_HEADER) && (header_word==0);
    assign out_eop = out_valid && (state==ST_CRC) && (crc_word==CRC_WORDS-1);

    // Construct the selected output word. All multibyte fields are serialized
    // in network order; byte lane zero always occupies the least-significant byte.
    always @* begin
        out_data={DATA_WIDTH{1'b0}};
        out_keep={KEEP_WIDTH{1'b0}};
        byte_index=0;
        case(state)
            ST_HEADER: begin
                out_keep={KEEP_WIDTH{1'b1}};
                for(integer n=0;n<WORD_BYTES;n=n+1)
                    out_data[n*8 +: 8]=header_mem[header_word*WORD_BYTES+n];
            end
            ST_PREFIX: begin
                out_keep={KEEP_WIDTH{1'b1}};
                for(integer n=0;n<WORD_BYTES;n=n+1) begin
                    byte_index=prefix_word*WORD_BYTES+n;
                    if(byte_index<4)
                        out_data[n*8 +: 8]=packet_sequence[31-byte_index*8 -: 8];
                end
            end
            ST_PAYLOAD: begin
                out_data=payload_data;
                out_keep=payload_keep;
            end
            ST_CRC: begin
                out_keep={KEEP_WIDTH{1'b1}};
                for(integer n=0;n<WORD_BYTES;n=n+1) begin
                    byte_index=crc_word*WORD_BYTES+n;
                    if(byte_index<4)
                        out_data[n*8 +: 8]=~frame_crc[31-byte_index*8 -: 8];
                end
            end
            default: begin end
        endcase
    end

    bonded_crc_parallel #(.DATA_BYTES(WORD_BYTES)) crc_update (
        .data(out_data), .keep(out_keep),
        .crc16_in(16'hffff), .crc32c_in(frame_crc),
        .crc16_out(unused_crc16), .crc32c_out(crc32_next)
    );

    initial begin
        if((DATA_WIDTH!=8)&&(DATA_WIDTH!=16)&&(DATA_WIDTH!=32))
            $error("DATA_WIDTH must be 8, 16 or 32");
        if(KEEP_WIDTH!=WORD_BYTES)
            $error("KEEP_WIDTH must equal DATA_WIDTH/8");
        if(LANE_ID<0 || LANE_ID>255)
            $error("LANE_ID must fit in eight bits");
    end

    always @(posedge clk) begin
        if(rst) begin
            state<=ST_IDLE; packet_sequence<=0; active_frame_sequence<=0;
            packet_length<=0; payload_bytes_seen<=0;
            payload_data<=0; payload_keep<=0; payload_eop<=0; payload_valid<=0;
            header_word<=0; prefix_word<=0; crc_word<=0;
            frame_crc<=32'hffffffff; header_crc<=16'hffff; frame_error<=0;
        end else begin
            if(state==ST_IDLE && in_valid && in_ready) begin
                byte_count=count_keep(in_keep);
                if(!in_sop || !keep_contiguous(in_keep) ||
                   in_packet_length==0 || in_packet_length>4096 ||
                   session_id==0 || frame_sequence==32'hffffffff ||
                   (!in_eop && in_keep!={KEEP_WIDTH{1'b1}}) ||
                   (in_eop && byte_count!=in_packet_length) ||
                   (!in_eop && byte_count>=in_packet_length)) begin
                    frame_error<=1'b1;
                end else begin
                    header_tmp[0]=8'h53; header_tmp[1]=8'h42;
                    header_tmp[2]=8'h01; header_tmp[3]=8'h01;
                    header_tmp[4]=8'h00; header_tmp[5]=LANE_ID[7:0];
                    header_tmp[6]=8'h00; header_tmp[7]=8'h18;
                    header_tmp[8]=session_id[63:56]; header_tmp[9]=session_id[55:48];
                    header_tmp[10]=session_id[47:40]; header_tmp[11]=session_id[39:32];
                    header_tmp[12]=session_id[31:24]; header_tmp[13]=session_id[23:16];
                    header_tmp[14]=session_id[15:8]; header_tmp[15]=session_id[7:0];
                    header_tmp[16]=frame_sequence[31:24]; header_tmp[17]=frame_sequence[23:16];
                    header_tmp[18]=frame_sequence[15:8]; header_tmp[19]=frame_sequence[7:0];
                    header_tmp[20]=(in_packet_length+16'd4)>>8;
                    header_tmp[21]=(in_packet_length+16'd4);
                    header_crc_tmp=16'hffff;
                    for(i=0;i<22;i=i+1)
                        header_crc_tmp=crc16_byte(header_crc_tmp,header_tmp[i]);
                    header_tmp[22]=header_crc_tmp[15:8];
                    header_tmp[23]=header_crc_tmp[7:0];
                    for(i=0;i<24;i=i+1) header_mem[i]<=header_tmp[i];

                    packet_sequence<=in_packet_sequence;
                    active_frame_sequence<=frame_sequence;
                    packet_length<=in_packet_length;
                    payload_bytes_seen<=byte_count;
                    payload_data<=in_data; payload_keep<=in_keep;
                    payload_eop<=in_eop; payload_valid<=1'b1;
                    header_crc<=header_crc_tmp;
                    frame_crc<=32'hffffffff;
                    header_word<=0; prefix_word<=0; crc_word<=0;
                    state<=ST_HEADER;
                end
            end

            if(out_valid && out_ready) begin
                case(state)
                    ST_HEADER: begin
                        frame_crc<=crc32_next;
                        if(header_word==HEADER_WORDS-1) begin
                            header_word<=0; state<=ST_PREFIX;
                        end else header_word<=header_word+1'b1;
                    end
                    ST_PREFIX: begin
                        frame_crc<=crc32_next;
                        if(prefix_word==PREFIX_WORDS-1) begin
                            prefix_word<=0; state<=ST_PAYLOAD;
                        end else prefix_word<=prefix_word+1'b1;
                    end
                    ST_PAYLOAD: begin
                        frame_crc<=crc32_next;
                        if(payload_eop) begin
                            payload_valid<=0; crc_word<=0; state<=ST_CRC;
                        end else payload_valid<=0;
                    end
                    ST_CRC: begin
                        if(crc_word==CRC_WORDS-1) begin
                            state<=ST_IDLE; payload_valid<=0;
                        end else crc_word<=crc_word+1'b1;
                    end
                    default: state<=ST_IDLE;
                endcase
            end

            if(state==ST_PAYLOAD && in_valid && in_ready) begin
                byte_count=count_keep(in_keep);
                if(in_sop || !keep_contiguous(in_keep) ||
                   (!in_eop && in_keep!={KEEP_WIDTH{1'b1}}) ||
                   (in_eop && payload_bytes_seen+byte_count!=packet_length) ||
                   (!in_eop && payload_bytes_seen+byte_count>=packet_length)) begin
                    frame_error<=1'b1; state<=ST_IDLE; payload_valid<=0;
                end else begin
                    payload_data<=in_data; payload_keep<=in_keep;
                    payload_eop<=in_eop; payload_valid<=1'b1;
                    payload_bytes_seen<=payload_bytes_seen+byte_count;
                end
            end
        end
    end
endmodule
