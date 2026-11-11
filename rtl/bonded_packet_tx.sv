// SPDX-License-Identifier: BSD-2-Clause
// Packet-level round-robin TX distributor for the bonded transport.
// This is the payload scheduler boundary: the lane adapter/wire framer is
// responsible for adding the v0 DATA envelope, session/lane fields and CRCs.
module bonded_packet_tx #(
    parameter integer DATA_WIDTH = 32,
    parameter integer LANE_COUNT = 2,
    parameter integer MAX_PACKET_BYTES = 4096,
    parameter integer KEEP_WIDTH = DATA_WIDTH / 8,
    parameter integer MAX_PACKET_BEATS = (MAX_PACKET_BYTES + KEEP_WIDTH - 1) / KEEP_WIDTH,
    parameter integer BEAT_COUNT_WIDTH = $clog2(MAX_PACKET_BEATS + 1),
    parameter integer LANE_INDEX_WIDTH = (LANE_COUNT <= 1) ? 1 : $clog2(LANE_COUNT)
) (
    input  wire clk,
    input  wire rst,

    input  wire                  tx_valid,
    output wire                  tx_ready,
    input  wire [DATA_WIDTH-1:0] tx_data,
    input  wire [KEEP_WIDTH-1:0] tx_keep,
    input  wire                  tx_sop,
    input  wire                  tx_eop,

    output reg  [LANE_COUNT-1:0] lane_valid,
    input  wire [LANE_COUNT-1:0] lane_ready,
    output reg  [LANE_COUNT*DATA_WIDTH-1:0] lane_data,
    output reg  [LANE_COUNT*KEEP_WIDTH-1:0] lane_keep,
    output reg  [LANE_COUNT-1:0] lane_sop,
    output reg  [LANE_COUNT-1:0] lane_eop,
    output reg  [LANE_COUNT*32-1:0] lane_packet_sequence,

    output reg packet_error
);
    localparam integer PTR_WIDTH = (MAX_PACKET_BEATS <= 2) ? 1 : $clog2(MAX_PACKET_BEATS);
    reg [DATA_WIDTH-1:0] packet_data [0:MAX_PACKET_BEATS-1];
    reg [KEEP_WIDTH-1:0] packet_keep [0:MAX_PACKET_BEATS-1];

    reg collecting;
    reg sending;
    reg [BEAT_COUNT_WIDTH-1:0] stored_beats;
    reg [PTR_WIDTH-1:0] send_index;
    reg [LANE_INDEX_WIDTH-1:0] selected_lane;
    reg [LANE_INDEX_WIDTH-1:0] next_lane;
    reg [31:0] next_packet_sequence;
    reg [31:0] active_packet_sequence;
    reg [KEEP_WIDTH-1:0] final_keep;
    integer i;

    assign tx_ready = !sending && (stored_beats < MAX_PACKET_BEATS);

    initial begin
        if (DATA_WIDTH < 8 || (DATA_WIDTH % 8) != 0)
            $error("DATA_WIDTH must be a positive multiple of 8");
        if (LANE_COUNT < 1)
            $error("LANE_COUNT must be positive");
        if (MAX_PACKET_BYTES < 1 || MAX_PACKET_BYTES > 4096)
            $error("MAX_PACKET_BYTES must be in range 1..4096");
    end

    always @* begin
        lane_valid = {LANE_COUNT{1'b0}};
        lane_data = {(LANE_COUNT*DATA_WIDTH){1'b0}};
        lane_keep = {(LANE_COUNT*KEEP_WIDTH){1'b0}};
        lane_sop = {LANE_COUNT{1'b0}};
        lane_eop = {LANE_COUNT{1'b0}};
        lane_packet_sequence = {(LANE_COUNT*32){1'b0}};
        if (sending) begin
            lane_valid[selected_lane] = 1'b1;
            lane_data[selected_lane*DATA_WIDTH +: DATA_WIDTH] = packet_data[send_index];
            lane_keep[selected_lane*KEEP_WIDTH +: KEEP_WIDTH] = packet_keep[send_index];
            lane_sop[selected_lane] = (send_index == 0);
            lane_eop[selected_lane] = (send_index == stored_beats-1);
            lane_packet_sequence[selected_lane*32 +: 32] = active_packet_sequence;
        end
    end

    always @(posedge clk) begin
        if (rst) begin
            collecting <= 1'b0;
            sending <= 1'b0;
            stored_beats <= 0;
            send_index <= 0;
            selected_lane <= 0;
            next_lane <= 0;
            next_packet_sequence <= 0;
            active_packet_sequence <= 0;
            packet_error <= 1'b0;
            final_keep <= 0;
        end else begin
            if (tx_valid && tx_ready) begin
                if ((!collecting && !tx_sop) || (collecting && tx_sop) ||
                    tx_keep == 0 ||
                    ((tx_keep & (tx_keep + 1'b1)) != 0) ||
                    (!tx_eop && tx_keep != {KEEP_WIDTH{1'b1}})) begin
                    collecting <= 1'b0;
                    stored_beats <= 0;
                    packet_error <= 1'b1;
                end else begin
                    packet_data[stored_beats] <= tx_data;
                    packet_keep[stored_beats] <= tx_keep;
                    stored_beats <= stored_beats + 1'b1;
                    collecting <= !tx_eop;
                    if (tx_eop) begin
                        // Complete packets are scheduled only after their final
                        // beat has been accepted and the buffer is complete.
                        sending <= 1'b1;
                        send_index <= 0;
                        selected_lane <= next_lane;
                        active_packet_sequence <= next_packet_sequence;
                        next_packet_sequence <= next_packet_sequence + 1'b1;
                    end
                end
            end

            if (sending && lane_ready[selected_lane]) begin
                if (send_index == stored_beats-1) begin
                    sending <= 1'b0;
                    stored_beats <= 0;
                    send_index <= 0;
                    collecting <= 1'b0;
                    if (next_lane == LANE_COUNT-1)
                        next_lane <= 0;
                    else
                        next_lane <= next_lane + 1'b1;
                end else begin
                    send_index <= send_index + 1'b1;
                end
            end
        end
    end
endmodule
