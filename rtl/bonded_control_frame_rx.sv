// SPDX-License-Identifier: BSD-2-Clause
// Standalone v0 CONTROL frame decoder. Validated bodies are held until consumed.
module bonded_control_frame_rx #(
    parameter integer LANE_ID = 0,
    parameter integer DYNAMIC_LANE_ID = 0
) (
    input wire clk,
    input wire rst,
    input wire [63:0] expected_session_id,
    input wire [31:0] expected_frame_sequence_override,
    input wire [7:0] expected_lane_id,
    input wire in_valid,
    output wire in_ready,
    input wire [7:0] in_data,
    input wire in_sop,
    input wire in_eop,
    output wire ctrl_valid,
    input wire ctrl_ready,
    output reg [207:0] ctrl_body,
    output reg [5:0] ctrl_body_length,
    output reg [31:0] received_frame_sequence,
    output reg [7:0] received_lane_id,
    output reg [63:0] received_session_id,
    output reg new_session_hello_pulse,
    output reg [31:0] expected_frame_sequence,
    output reg frame_valid_pulse,
    output reg frame_error
);
    localparam [1:0] ST_IDLE=2'd0, ST_COLLECT=2'd1,
                     ST_CHECK=2'd2, ST_OUTPUT=2'd3;
    reg [1:0] state;
    reg [7:0] frame_mem [0:53];
    reg [6:0] rx_count;
    reg [7:0] tail0,tail1,tail2,tail3;
    reg [15:0] header_crc;
    reg [31:0] frame_crc;
    reg [63:0] active_session;
    reg [5:0] body_length;
    integer i;

    function [15:0] crc16_byte(input [15:0] ci,input [7:0] d);
        integer k; reg [15:0] c;
        begin c=ci^{d,8'h00}; for(k=0;k<8;k=k+1)c=c[15]?((c<<1)^16'h1021):(c<<1); crc16_byte=c; end
    endfunction
    function [31:0] crc32c_byte(input [31:0] ci,input [7:0] d);
        integer k; reg [31:0] c;
        begin c=ci^d; for(k=0;k<8;k=k+1)c=c[0]?((c>>1)^32'h82f63b78):(c>>1); crc32c_byte=c; end
    endfunction
    function body_valid(input [7:0] opcode,input [5:0] length);
        begin
            case(opcode)
                8'h01: body_valid=(length==26);
                8'h02: body_valid=(length==12);
                8'h03: body_valid=(length==13);
                8'h04,8'h05,8'h07: body_valid=(length==5);
                8'h06: body_valid=(length==3);
                default: body_valid=1'b0;
            endcase
        end
    endfunction

    assign in_ready = !rst && (state==ST_IDLE || state==ST_COLLECT);
    assign ctrl_valid = !rst && (state==ST_OUTPUT);

    always @(posedge clk) begin
        if(rst) begin
            state<=ST_IDLE; rx_count<=0;
            tail0<=0;tail1<=0;tail2<=0;tail3<=0;
            header_crc<=16'hffff;frame_crc<=32'hffffffff;
            active_session<=0;body_length<=0;
            ctrl_body<=0;ctrl_body_length<=0;
            received_frame_sequence<=0;received_lane_id<=0;received_session_id<=0;
            expected_frame_sequence<=0;frame_valid_pulse<=0;new_session_hello_pulse<=0;
            frame_error<=0;
        end else begin
            frame_valid_pulse<=0;new_session_hello_pulse<=0;
            if(in_valid && in_ready) begin
                if(state==ST_IDLE) begin
                    if(!in_sop || in_eop) begin
                        frame_error<=1;
                    end else begin
                        state<=ST_COLLECT;rx_count<=1;frame_mem[0]<=in_data;
                        tail0<=in_data;tail1<=0;tail2<=0;tail3<=0;
                        header_crc<=crc16_byte(16'hffff,in_data);
                        frame_crc<=32'hffffffff;active_session<=expected_session_id;
                    end
                end else if(in_sop) begin
                    frame_error<=1;state<=ST_COLLECT;rx_count<=1;
                    frame_mem[0]<=in_data;tail0<=in_data;tail1<=0;tail2<=0;tail3<=0;
                    header_crc<=crc16_byte(16'hffff,in_data);
                    frame_crc<=32'hffffffff;active_session<=expected_session_id;
                end else if(rx_count>=54) begin
                    frame_error<=1;state<=ST_IDLE;rx_count<=0;
                end else begin
                    frame_mem[rx_count]<=in_data;
                    if(rx_count<22) header_crc<=crc16_byte(header_crc,in_data);
                    if(rx_count>=4) frame_crc<=crc32c_byte(frame_crc,tail3);
                    tail3<=tail2;tail2<=tail1;tail1<=tail0;tail0<=in_data;
                    rx_count<=rx_count+1'b1;
                    if(in_eop) state<=ST_CHECK;
                end
            end
            if(state==ST_CHECK) begin
                body_length<=frame_mem[21][5:0];
                if(frame_mem[0]!=8'h53 || frame_mem[1]!=8'h42 ||
                   frame_mem[2]!=8'h01 || frame_mem[3]!=8'h02 ||
                   frame_mem[4]!=8'h00 || frame_mem[5]>8'd1 ||
                   (DYNAMIC_LANE_ID ? ((expected_lane_id!=8'hff) && (frame_mem[5]!=expected_lane_id)) : (frame_mem[5]!=LANE_ID[7:0])) ||
                   frame_mem[6]!=8'h00 || frame_mem[7]!=8'h18 ||
                   active_session==0 ||
                   frame_mem[20]!=0 || frame_mem[21]>26 ||
                   {frame_mem[22],frame_mem[23]}!=header_crc ||
                   rx_count!=(24+frame_mem[21]+4) ||
                   {tail3,tail2,tail1,tail0}!=~frame_crc ||
                   !body_valid(frame_mem[24],frame_mem[21][5:0])) begin
                    frame_error<=1;state<=ST_IDLE;rx_count<=0;
                end else if(active_session!=expected_session_id &&
                            !(active_session>expected_session_id && frame_mem[24]==8'h01)) begin
                    // Complete frames from older epochs and non-HELLO frames
                    // from an unadopted newer epoch are stale, not PHY errors.
                    state<=ST_IDLE;rx_count<=0;
                end else if(active_session==expected_session_id &&
                            ({frame_mem[16],frame_mem[17],frame_mem[18],frame_mem[19]}!=expected_frame_sequence_override ||
                             expected_frame_sequence_override==32'hffffffff) &&
                            !(frame_mem[24]==8'h01 &&
                              {frame_mem[16],frame_mem[17],frame_mem[18],frame_mem[19]}==0 &&
                              expected_frame_sequence_override!=32'hffffffff)) begin
                    frame_error<=1;state<=ST_IDLE;rx_count<=0;
                end else begin
                    ctrl_body<=0;
                    for(i=0;i<26;i=i+1)
                        if(i<frame_mem[21])
                            ctrl_body[207-i*8 -: 8]<=frame_mem[24+i];
                    ctrl_body_length<=frame_mem[21][5:0];
                    received_frame_sequence<={frame_mem[16],frame_mem[17],frame_mem[18],frame_mem[19]};
                    received_lane_id<=frame_mem[5];
                    received_session_id<=active_session;
                    expected_frame_sequence<= {frame_mem[16],frame_mem[17],frame_mem[18],frame_mem[19]}+1'b1;
                    if(frame_mem[24]==8'h01 &&
                       ((active_session>expected_session_id) ||
                        (active_session==expected_session_id &&
                         {frame_mem[16],frame_mem[17],frame_mem[18],frame_mem[19]}==0 &&
                         expected_frame_sequence_override!=0)))
                        new_session_hello_pulse<=1'b1;
                    frame_valid_pulse<=1'b1;
                    state<=ST_OUTPUT;
                end
            end
            if(state==ST_OUTPUT && ctrl_valid && ctrl_ready) begin
                state<=ST_IDLE;rx_count<=0;
            end
        end
    end
endmodule
