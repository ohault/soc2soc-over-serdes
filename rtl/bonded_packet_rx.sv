// SPDX-License-Identifier: BSD-2-Clause
// Bounded multi-lane packet collector and in-order delivery engine.
// Input is byte-stream data from independent, already CRC-validated lane RXs.
// One input byte is accepted per cycle globally; output preserves packet order.
module bonded_packet_rx #(
    parameter integer LANE_COUNT = 2,
    parameter integer WINDOW_SIZE = 4,
    parameter integer MAX_PACKET_BYTES = 4096,
    parameter integer WINDOW_BITS = $clog2(WINDOW_SIZE),
    parameter integer LANE_BITS = (LANE_COUNT <= 1) ? 1 : $clog2(LANE_COUNT)
) (
    input wire clk, input wire rst,
    input wire [LANE_COUNT-1:0] lane_valid,
    output reg [LANE_COUNT-1:0] lane_ready,
    input wire [LANE_COUNT*8-1:0] lane_data,
    input wire [LANE_COUNT-1:0] lane_sop,
    input wire [LANE_COUNT-1:0] lane_eop,
    input wire [LANE_COUNT*32-1:0] lane_packet_sequence,

    output wire out_valid, input wire out_ready,
    output wire [7:0] out_data,
    output wire out_sop, output wire out_eop,
    output wire [31:0] out_packet_sequence,

    output reg [31:0] expected_packet_sequence,
    output reg packet_error
);
    reg [7:0] packet_mem [0:WINDOW_SIZE-1][0:MAX_PACKET_BYTES-1];
    reg [12:0] slot_length [0:WINDOW_SIZE-1];
    reg [WINDOW_SIZE-1:0] slot_valid;
    reg [WINDOW_SIZE-1:0] slot_filling;
    reg [WINDOW_BITS-1:0] lane_slot [0:LANE_COUNT-1];
    reg [12:0] lane_count [0:LANE_COUNT-1];
    reg [LANE_COUNT-1:0] lane_active;
    reg [LANE_COUNT-1:0] lane_drop;

    reg [LANE_BITS-1:0] arbiter;
    reg [LANE_BITS-1:0] selected_lane;
    reg selected_valid;
    reg [WINDOW_BITS-1:0] output_slot;
    reg [12:0] output_index;
    integer i, candidate;
    reg found;

    initial begin
        if (LANE_COUNT < 1) $error("LANE_COUNT must be positive");
        if (WINDOW_SIZE < 2 || (WINDOW_SIZE & (WINDOW_SIZE-1)) != 0)
            $error("WINDOW_SIZE must be a power of two >= 2");
        if (MAX_PACKET_BYTES < 1 || MAX_PACKET_BYTES > 4096)
            $error("MAX_PACKET_BYTES must be in range 1..4096");
    end

    always @* begin
        lane_ready = {LANE_COUNT{1'b0}};
        selected_lane = arbiter;
        selected_valid = 1'b0;
        found = 1'b0;
        candidate = 0;
        for (i=0;i<LANE_COUNT;i=i+1) begin
            candidate = arbiter + i;
            if (candidate >= LANE_COUNT) candidate = candidate - LANE_COUNT;
            if (!found && lane_valid[candidate]) begin
                selected_lane = candidate[LANE_BITS-1:0];
                selected_valid = 1'b1;
                found = 1'b1;
            end
        end
        if (!rst && selected_valid)
            lane_ready[selected_lane] = 1'b1;
    end

    assign output_slot = expected_packet_sequence[WINDOW_BITS-1:0];
    assign out_valid = !rst && slot_valid[output_slot];
    assign out_data = packet_mem[output_slot][output_index];
    assign out_sop = out_valid && (output_index==0);
    assign out_eop = out_valid && (output_index+1'b1==slot_length[output_slot]);
    assign out_packet_sequence = expected_packet_sequence;

    always @(posedge clk) begin
        if (rst) begin
            slot_valid <= 0;
            slot_filling <= 0;
            lane_active <= 0;
            lane_drop <= 0;
            arbiter <= 0;
            output_index <= 0;
            expected_packet_sequence <= 0;
            packet_error <= 0;
            for (i=0;i<LANE_COUNT;i=i+1) begin
                lane_slot[i] <= 0;
                lane_count[i] <= 0;
            end
            for (i=0;i<WINDOW_SIZE;i=i+1)
                slot_length[i] <= 0;
        end else begin
            if (selected_valid && lane_ready[selected_lane]) begin
                arbiter <= (selected_lane == LANE_COUNT-1) ? 0 : selected_lane + 1'b1;
                if (lane_drop[selected_lane]) begin
                    if (lane_eop[selected_lane]) lane_drop[selected_lane] <= 0;
                end else if (lane_sop[selected_lane]) begin
                    if (lane_active[selected_lane] ||
                        ({1'b0,lane_packet_sequence[selected_lane*32 +: 32]} < {1'b0,expected_packet_sequence}) ||
                        ({1'b0,lane_packet_sequence[selected_lane*32 +: 32]} >=
                         ({1'b0,expected_packet_sequence} + WINDOW_SIZE)) ||
                        slot_valid[lane_packet_sequence[selected_lane*32 +: WINDOW_BITS]] ||
                        slot_filling[lane_packet_sequence[selected_lane*32 +: WINDOW_BITS]]) begin
                        packet_error <= 1;
                        lane_active[selected_lane] <= 0;
                        lane_drop[selected_lane] <= !lane_eop[selected_lane];
                    end else if (lane_eop[selected_lane] && MAX_PACKET_BYTES >= 1) begin
                        // Empty payloads are represented upstream by one zero marker.
                        lane_slot[selected_lane] <= lane_packet_sequence[selected_lane*32 +: WINDOW_BITS];
                        lane_count[selected_lane] <= 1;
                        packet_mem[lane_packet_sequence[selected_lane*32 +: WINDOW_BITS]][0]
                            <= lane_data[selected_lane*8 +: 8];
                        slot_length[lane_packet_sequence[selected_lane*32 +: WINDOW_BITS]] <= 1;
                        slot_valid[lane_packet_sequence[selected_lane*32 +: WINDOW_BITS]] <= 1;
                    end else begin
                        lane_slot[selected_lane] <= lane_packet_sequence[selected_lane*32 +: WINDOW_BITS];
                        lane_count[selected_lane] <= 1;
                        lane_active[selected_lane] <= 1;
                        slot_filling[lane_packet_sequence[selected_lane*32 +: WINDOW_BITS]] <= 1;
                        packet_mem[lane_packet_sequence[selected_lane*32 +: WINDOW_BITS]][0]
                            <= lane_data[selected_lane*8 +: 8];
                    end
                end else if (!lane_active[selected_lane]) begin
                    packet_error <= 1;
                    lane_drop[selected_lane] <= !lane_eop[selected_lane];
                end else if (lane_count[selected_lane] >= MAX_PACKET_BYTES) begin
                    packet_error <= 1;
                    slot_filling[lane_slot[selected_lane]] <= 0;
                    lane_active[selected_lane] <= 0;
                    lane_drop[selected_lane] <= !lane_eop[selected_lane];
                end else begin
                    packet_mem[lane_slot[selected_lane]][lane_count[selected_lane]]
                        <= lane_data[selected_lane*8 +: 8];
                    lane_count[selected_lane] <= lane_count[selected_lane] + 1'b1;
                    if (lane_eop[selected_lane]) begin
                        slot_length[lane_slot[selected_lane]] <= lane_count[selected_lane] + 1'b1;
                        slot_valid[lane_slot[selected_lane]] <= 1;
                        slot_filling[lane_slot[selected_lane]] <= 0;
                        lane_active[selected_lane] <= 0;
                    end
                end
            end

            if (out_valid && out_ready) begin
                if (out_eop) begin
                    slot_valid[output_slot] <= 0;
                    output_index <= 0;
                    if (expected_packet_sequence != 32'hffffffff)
                        expected_packet_sequence <= expected_packet_sequence + 1'b1;
                    else
                        packet_error <= 1;
                end else output_index <= output_index + 1'b1;
            end
        end
    end
endmodule
