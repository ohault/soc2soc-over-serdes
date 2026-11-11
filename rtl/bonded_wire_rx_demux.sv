// SPDX-License-Identifier: BSD-2-Clause
// Frame-type demultiplexer. Buffers the four-byte prefix, replays it to the
// selected decoder, then streams the remainder with ready/valid backpressure.
module bonded_wire_rx_demux (
    input wire clk,
    input wire rst,
    input wire data_enable,
    input wire in_valid,
    output wire in_ready,
    input wire [7:0] in_data,
    input wire in_sop,
    input wire in_eop,

    output wire data_valid,
    input wire data_ready,
    output wire [7:0] data_data,
    output wire data_sop,
    output wire data_eop,

    output wire ctrl_valid,
    input wire ctrl_ready,
    output wire [7:0] ctrl_data,
    output wire ctrl_sop,
    output wire ctrl_eop,

    output reg frame_error
);
    localparam [1:0] ST_HEADER=2'd0, ST_REPLAY=2'd1,
                     ST_BODY=2'd2, ST_DROP=2'd3;
    reg [1:0] state;
    reg [7:0] header_mem[0:3];
    reg [1:0] header_count,replay_index;
    reg selected_control;
    wire selected_ready = selected_control ? ctrl_ready : (data_enable ? data_ready : 1'b1);
    wire replay_valid = (state==ST_REPLAY);
    wire body_valid = (state==ST_BODY) && in_valid;
    wire output_valid = replay_valid || body_valid;
    wire [7:0] output_data = replay_valid ? header_mem[replay_index] : in_data;
    wire output_sop = replay_valid ? (replay_index==0) : in_sop;
    wire output_eop = replay_valid ? 1'b0 : in_eop;
    wire output_ready = selected_ready;

    assign in_ready = !rst && ((state==ST_HEADER) || (state==ST_DROP) ||
                       ((state==ST_BODY) && selected_ready));
    assign data_valid = !rst && data_enable && output_valid && !selected_control;
    assign ctrl_valid = !rst && output_valid && selected_control;
    assign data_data = output_data;
    assign ctrl_data = output_data;
    assign data_sop = output_sop;
    assign ctrl_sop = output_sop;
    assign data_eop = output_eop;
    assign ctrl_eop = output_eop;

    always @(posedge clk) begin
        if(rst) begin
            state<=ST_HEADER;header_count<=0;replay_index<=0;
            selected_control<=0;frame_error<=0;
        end else begin
            if(state==ST_HEADER && in_valid && in_ready) begin
                if(header_count==0 && !in_sop) begin
                    frame_error<=1;
                    state<=in_eop ? ST_HEADER : ST_DROP;
                end else if(header_count!=0 && in_sop) begin
                    frame_error<=1;
                    header_mem[0]<=in_data;
                    header_count<=1;
                end else begin
                    header_mem[header_count]<=in_data;
                    if(header_count==3) begin
                        if(header_mem[0]==8'h53 && header_mem[1]==8'h42 &&
                           header_mem[2]==8'h01 && in_data==8'h01) begin
                            selected_control<=0;replay_index<=0;state<=data_enable ? ST_REPLAY : ST_DROP;
                        end else if(header_mem[0]==8'h53 && header_mem[1]==8'h42 &&
                                    header_mem[2]==8'h01 && in_data==8'h02) begin
                            selected_control<=1;replay_index<=0;state<=ST_REPLAY;
                        end else begin
                            frame_error<=1;state<=in_eop ? ST_HEADER : ST_DROP;
                        end
                        header_count<=0;
                    end else if(in_eop) begin
                        frame_error<=1;state<=ST_HEADER;header_count<=0;
                    end else header_count<=header_count+1'b1;
                end
            end
            if(state==ST_REPLAY && output_valid && output_ready) begin
                if(replay_index==3) begin
                    replay_index<=0;state<=(!selected_control && !data_enable) ? ST_DROP : ST_BODY;
                end else replay_index<=replay_index+1'b1;
            end
            if(state==ST_BODY && in_valid && in_ready && in_sop) begin
                // A new SOP while a frame is open means the previous frame
                // was truncated. Resynchronize regardless of DATA/CONTROL type.
                frame_error<=1'b1;
                header_mem[0]<=in_data;header_count<=1;state<=ST_HEADER;
            end else if(state==ST_BODY && !selected_control && !data_enable) begin
                // A session reset may abort DATA without a replacement SOP yet.
                state<=ST_DROP;header_count<=0;
            end else if(state==ST_BODY && in_valid && in_ready && in_eop) begin
                state<=ST_HEADER;header_count<=0;
            end
            if(state==ST_DROP && in_valid && in_ready) begin
                if(in_sop) begin
                    header_mem[0]<=in_data;header_count<=1;state<=ST_HEADER;
                end else if(in_eop) begin
                    state<=ST_HEADER;header_count<=0;
                end
            end
        end
    end
endmodule
