// SPDX-License-Identifier: BSD-2-Clause
// Frame-atomic CONTROL-priority arbiter for one physical lane.
// A selected frame is never interrupted: CONTROL wins at the next boundary.
module bonded_lane_frame_arbiter (
    input wire clk,
    input wire rst,
    input wire data_abort,

    input wire ctrl_valid,
    output wire ctrl_ready,
    input wire [7:0] ctrl_data,
    input wire ctrl_sop,
    input wire ctrl_eop,

    input wire data_valid,
    output wire data_ready,
    input wire [7:0] data_data,
    input wire data_sop,
    input wire data_eop,

    output wire out_valid,
    input wire out_ready,
    output wire [7:0] out_data,
    output wire out_sop,
    output wire out_eop,
    output wire frame_idle,
    output reg protocol_error
);
    localparam [1:0] SEL_IDLE=2'd0, SEL_CONTROL=2'd1, SEL_DATA=2'd2;
    reg [1:0] selected;
    wire choose_control = (selected==SEL_IDLE) && ctrl_valid && ctrl_sop;
    wire choose_data = (selected==SEL_IDLE) && !choose_control && data_valid && data_sop;
    wire control_active = (selected==SEL_CONTROL) || choose_control;
    wire data_active = (selected==SEL_DATA) || choose_data;

    assign frame_idle = (selected==SEL_IDLE);
    assign ctrl_ready = !rst && control_active && out_ready;
    assign data_ready = !rst && data_active && out_ready;
    assign out_valid = !rst && ((control_active && ctrl_valid) ||
                                (data_active && data_valid));
    assign out_data = control_active ? ctrl_data : data_data;
    assign out_sop = out_valid && (control_active ? ctrl_sop : data_sop);
    assign out_eop = out_valid && (control_active ? ctrl_eop : data_eop);

    always @(posedge clk) begin
        if (rst) begin
            selected <= SEL_IDLE;
            protocol_error <= 1'b0;
        end else if (data_abort && selected==SEL_DATA) begin
            selected <= SEL_IDLE;
        end else begin
            if (selected==SEL_IDLE) begin
                if ((ctrl_valid && !ctrl_sop) ||
                    (!ctrl_valid && data_valid && !data_sop))
                    protocol_error <= 1'b1;
            end
            if (out_valid && selected==SEL_IDLE && out_sop)
                selected <= control_active ? SEL_CONTROL : SEL_DATA;
            if (out_valid && out_ready) begin
                if (out_sop && selected!=SEL_IDLE && !((selected==SEL_IDLE)))
                    protocol_error <= 1'b1;
                if (out_eop) begin
                    selected <= SEL_IDLE;
                end
            end
        end
    end
endmodule
