// SPDX-License-Identifier: BSD-2-Clause
// Standalone v0 CONTROL frame encoder. Framework-, board- and SoC-neutral.
// Body bytes are packed network-order: ctrl_body[207:200] is byte zero.
module bonded_control_frame_tx #(
    parameter integer LANE_ID = 0
) (
    input wire clk,
    input wire rst,
    input wire [63:0] session_id,
    input wire ctrl_valid,
    output wire ctrl_ready,
    input wire [207:0] ctrl_body,
    input wire [5:0] ctrl_body_length,
    output wire out_valid,
    input wire out_ready,
    output wire [7:0] out_data,
    output wire out_sop,
    output wire out_eop,
    output reg [31:0] next_frame_sequence,
    output reg frame_error
);
    localparam [1:0] ST_IDLE=2'd0, ST_HEADER=2'd1,
                     ST_BODY=2'd2, ST_CRC=2'd3;
    reg [1:0] state;
    reg [5:0] header_index;
    reg [5:0] body_index;
    reg [2:0] crc_index;
    reg [5:0] body_length;
    reg [63:0] active_session;
    reg [31:0] active_sequence;
    reg [7:0] body_mem [0:25];
    reg [15:0] header_crc;
    reg [31:0] frame_crc;
    integer i;

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

    function control_body_valid(input [207:0] body,input [5:0] length);
        reg [7:0] opcode;
        begin
            opcode=body[207:200];
            case(opcode)
                8'h01: control_body_valid=(length==26); // HELLO
                8'h02: control_body_valid=(length==12); // READY
                8'h03: control_body_valid=(length==13); // CREDIT
                8'h04: control_body_valid=(length==5);  // PING
                8'h05: control_body_valid=(length==5);  // PONG
                8'h06: control_body_valid=(length==3);  // RESET
                8'h07: control_body_valid=(length==5);  // ERROR
                default: control_body_valid=1'b0;
            endcase
        end
    endfunction

    assign ctrl_ready = !rst && (state==ST_IDLE);
    assign out_valid = !rst && (state!=ST_IDLE);
    assign out_sop = out_valid && (state==ST_HEADER) && (header_index==0);
    assign out_eop = out_valid && (state==ST_CRC) && (crc_index==3);

    reg [7:0] byte_mux;
    always @* begin
        byte_mux=8'h00;
        case(state)
            ST_HEADER: begin
                case(header_index)
                    0: byte_mux=8'h53;
                    1: byte_mux=8'h42;
                    2: byte_mux=8'h01;
                    3: byte_mux=8'h02; // CONTROL
                    4: byte_mux=8'h00;
                    5: byte_mux=LANE_ID[7:0];
                    6: byte_mux=8'h00;
                    7: byte_mux=8'h18;
                    8: byte_mux=active_session[63:56];
                    9: byte_mux=active_session[55:48];
                    10: byte_mux=active_session[47:40];
                    11: byte_mux=active_session[39:32];
                    12: byte_mux=active_session[31:24];
                    13: byte_mux=active_session[23:16];
                    14: byte_mux=active_session[15:8];
                    15: byte_mux=active_session[7:0];
                    16: byte_mux=active_sequence[31:24];
                    17: byte_mux=active_sequence[23:16];
                    18: byte_mux=active_sequence[15:8];
                    19: byte_mux=active_sequence[7:0];
                    20: byte_mux=8'h00;
                    21: byte_mux=body_length;
                    22: byte_mux=header_crc[15:8];
                    default: byte_mux=header_crc[7:0];
                endcase
            end
            ST_BODY: byte_mux=body_mem[body_index];
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
            body_index<=0;
            crc_index<=0;
            body_length<=0;
            active_session<=0;
            active_sequence<=0;
            header_crc<=16'hffff;
            frame_crc<=32'hffffffff;
            next_frame_sequence<=0;
            frame_error<=0;
        end else begin
            if(state==ST_IDLE && ctrl_valid && ctrl_ready) begin
                if(session_id==0 || next_frame_sequence==32'hffff_ffff ||
                   !control_body_valid(ctrl_body,ctrl_body_length)) begin
                    frame_error<=1'b1;
                end else begin
                    active_session<=session_id;
                    active_sequence<=next_frame_sequence;
                    body_length<=ctrl_body_length;
                    for(i=0;i<26;i=i+1)
                        if(i<ctrl_body_length)
                            body_mem[i]<=ctrl_body[207-i*8 -: 8];
                    header_index<=0;
                    body_index<=0;
                    crc_index<=0;
                    header_crc<=16'hffff;
                    frame_crc<=32'hffffffff;
                    state<=ST_HEADER;
                end
            end else if(out_valid && out_ready) begin
                case(state)
                    ST_HEADER: begin
                        frame_crc<=crc32c_byte(frame_crc,byte_mux);
                        if(header_index<22)
                            header_crc<=crc16_byte(header_crc,byte_mux);
                        if(header_index==23) begin
                            header_index<=0;
                            body_index<=0;
                            state<=ST_BODY;
                        end else header_index<=header_index+1'b1;
                    end
                    ST_BODY: begin
                        frame_crc<=crc32c_byte(frame_crc,byte_mux);
                        if(body_index==body_length-1'b1) begin
                            crc_index<=0;
                            state<=ST_CRC;
                        end else body_index<=body_index+1'b1;
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
        end
    end
endmodule
