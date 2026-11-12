// SPDX-License-Identifier: BSD-2-Clause
// Bounded multi-lane packet collector and in-order delivery engine.
// Input is byte-stream data from independent, already CRC-validated lane RXs.
// One input byte is accepted per cycle globally; output preserves packet order.
module bonded_packet_rx #(
    parameter integer LANE_COUNT = 2,
    parameter integer WINDOW_SIZE = 4,
    parameter integer MAX_PACKET_BYTES = 4096,
    parameter integer WINDOW_BITS = $clog2(WINDOW_SIZE),
    parameter integer LANE_BITS = (LANE_COUNT <= 1) ? 1 : $clog2(LANE_COUNT),
    parameter integer INDEX_BITS = (MAX_PACKET_BYTES <= 1) ? 1 : $clog2(MAX_PACKET_BYTES)
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
    output reg packet_error,
    // One-cycle event when a complete packet has entered reorder storage.
    output reg packet_accept_valid,
    output reg [15:0] packet_accept_bytes,
    // One-cycle event when the application consumes a complete packet.
    output wire packet_consume_valid,
    output wire [15:0] packet_consume_bytes
);
    // Reorder storage: one flat byte array addressed by {slot, byte index},
    // with a single write port and a registered read port so that synthesis
    // maps it to block RAM.
    localparam integer MEM_ADDR_BITS = WINDOW_BITS + INDEX_BITS;
    reg [7:0] packet_mem [0:(1<<MEM_ADDR_BITS)-1];
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

    wire [WINDOW_BITS-1:0] sop_slot =
        lane_packet_sequence[selected_lane*32 +: WINDOW_BITS];
    wire sop_reject =
        lane_active[selected_lane] ||
        ({1'b0,lane_packet_sequence[selected_lane*32 +: 32]} < {1'b0,expected_packet_sequence}) ||
        ({1'b0,lane_packet_sequence[selected_lane*32 +: 32]} >=
         ({1'b0,expected_packet_sequence} + WINDOW_SIZE)) ||
        slot_valid[sop_slot] || slot_filling[sop_slot];

    // Payload write port: the first byte of an accepted packet goes to index 0
    // of its slot, later bytes to the lane's running count (same conditions as
    // the state update below).
    reg mem_we;
    reg [MEM_ADDR_BITS-1:0] mem_waddr;
    wire [7:0] mem_wdata = lane_data[selected_lane*8 +: 8];
    always @* begin
        mem_we = 1'b0;
        mem_waddr = {sop_slot, {INDEX_BITS{1'b0}}};
        if (selected_valid && lane_ready[selected_lane] && !lane_drop[selected_lane]) begin
            if (lane_sop[selected_lane]) begin
                mem_we = !sop_reject;
            end else if (lane_active[selected_lane] &&
                         !(lane_count[selected_lane] >= MAX_PACKET_BYTES)) begin
                mem_we = 1'b1;
                mem_waddr = {lane_slot[selected_lane],
                             lane_count[selected_lane][INDEX_BITS-1:0]};
            end
        end
    end

    // Read port: address the byte that will be presented in the next cycle
    // (next output slot/index) and register the RAM output. A same-cycle write
    // to that address is forwarded so out_data matches an asynchronous read.
    reg [WINDOW_BITS-1:0] mem_rd_slot;
    reg [12:0] mem_rd_index;
    wire [MEM_ADDR_BITS-1:0] mem_raddr = {mem_rd_slot, mem_rd_index[INDEX_BITS-1:0]};
    reg [7:0] mem_rd_data, mem_bypass_data;
    reg mem_bypass;
    always @* begin
        mem_rd_slot = output_slot;
        mem_rd_index = output_index;
        if (rst) begin
            mem_rd_slot = 0;
            mem_rd_index = 0;
        end else if (out_valid && out_ready) begin
            if (out_eop) begin
                mem_rd_index = 0;
                if (expected_packet_sequence != 32'hffffffff)
                    mem_rd_slot = output_slot + 1'b1;
            end else mem_rd_index = output_index + 1'b1;
        end
    end

    always @(posedge clk) begin
        if (mem_we)
            packet_mem[mem_waddr] <= mem_wdata;
    end

    always @(posedge clk) begin
        mem_rd_data <= packet_mem[mem_raddr];
        mem_bypass <= mem_we && (mem_waddr == mem_raddr);
        mem_bypass_data <= mem_wdata;
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
    assign out_data = mem_bypass ? mem_bypass_data : mem_rd_data;
    assign out_sop = out_valid && (output_index==0);
    assign out_eop = out_valid && (output_index+1'b1==slot_length[output_slot]);
    assign out_packet_sequence = expected_packet_sequence;
    assign packet_consume_valid = out_valid && out_ready && out_eop;
    assign packet_consume_bytes = slot_length[output_slot];

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
            packet_accept_valid <= 0;
            packet_accept_bytes <= 0;
            for (i=0;i<LANE_COUNT;i=i+1) begin
                lane_slot[i] <= 0;
                lane_count[i] <= 0;
            end
            for (i=0;i<WINDOW_SIZE;i=i+1)
                slot_length[i] <= 0;
        end else begin
            packet_accept_valid <= 0;
            if (selected_valid && lane_ready[selected_lane]) begin
                arbiter <= (selected_lane == LANE_COUNT-1) ? 0 : selected_lane + 1'b1;
                if (lane_drop[selected_lane]) begin
                    if (lane_eop[selected_lane]) lane_drop[selected_lane] <= 0;
                end else if (lane_sop[selected_lane]) begin
                    if (sop_reject) begin
                        packet_error <= 1;
                        if (lane_active[selected_lane])
                            slot_filling[lane_slot[selected_lane]] <= 0;
                        lane_active[selected_lane] <= 0;
                        lane_drop[selected_lane] <= !lane_eop[selected_lane];
                    end else if (lane_eop[selected_lane] && MAX_PACKET_BYTES >= 1) begin
                        // Empty payloads are represented upstream by one zero marker.
                        lane_slot[selected_lane] <= lane_packet_sequence[selected_lane*32 +: WINDOW_BITS];
                        lane_count[selected_lane] <= 1;
                        slot_length[lane_packet_sequence[selected_lane*32 +: WINDOW_BITS]] <= 1;
                        slot_valid[lane_packet_sequence[selected_lane*32 +: WINDOW_BITS]] <= 1;
                        packet_accept_valid <= 1;
                        packet_accept_bytes <= 1;
                    end else begin
                        lane_slot[selected_lane] <= lane_packet_sequence[selected_lane*32 +: WINDOW_BITS];
                        lane_count[selected_lane] <= 1;
                        lane_active[selected_lane] <= 1;
                        slot_filling[lane_packet_sequence[selected_lane*32 +: WINDOW_BITS]] <= 1;
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
                    lane_count[selected_lane] <= lane_count[selected_lane] + 1'b1;
                    if (lane_eop[selected_lane]) begin
                        slot_length[lane_slot[selected_lane]] <= lane_count[selected_lane] + 1'b1;
                        slot_valid[lane_slot[selected_lane]] <= 1;
                        packet_accept_valid <= 1;
                        packet_accept_bytes <= lane_count[selected_lane] + 1'b1;
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
