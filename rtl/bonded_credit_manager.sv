// SPDX-License-Identifier: BSD-2-Clause
// Cumulative byte and packet credit accounting for one bonded session.
// All counters are session-scoped and must be reset before wraparound.
module bonded_credit_manager #(
    parameter [63:0] INITIAL_RX_BYTES = 64'd16384,
    parameter [31:0] INITIAL_RX_PACKETS = 32'd64
) (
    input wire clk,
    input wire rst,

    // Sender: reserve one complete packet before assigning its sequence.
    input wire tx_reserve_valid,
    input wire [15:0] tx_reserve_bytes,
    output wire tx_reserve_ready,
    input wire [63:0] remote_byte_limit,
    input wire [31:0] remote_packet_limit,
    output reg [63:0] tx_reserved_bytes,
    output reg [31:0] tx_reserved_packets,

    // Receiver: count a verified DATA packet before admitting it to reorder.
    input wire rx_accept_valid,
    input wire [15:0] rx_accept_bytes,
    output wire rx_accept_ready,
    input wire rx_consume_valid,
    input wire [15:0] rx_consume_bytes,
    output reg [63:0] rx_accepted_bytes,
    output reg [31:0] rx_accepted_packets,
    output reg [63:0] rx_consumed_bytes,
    output reg [31:0] rx_consumed_packets,
    output wire [63:0] local_byte_limit,
    output wire [31:0] local_packet_limit,

    output reg credit_error
);
    wire [64:0] tx_bytes_sum = {1'b0,tx_reserved_bytes} + tx_reserve_bytes;
    wire [32:0] tx_packets_sum = {1'b0,tx_reserved_packets} + 33'd1;
    wire [64:0] rx_bytes_sum = {1'b0,rx_accepted_bytes} + rx_accept_bytes;
    wire [32:0] rx_packets_sum = {1'b0,rx_accepted_packets} + 33'd1;
    wire [64:0] consume_bytes_sum = {1'b0,rx_consumed_bytes} + rx_consume_bytes;
    wire [32:0] consume_packets_sum = {1'b0,rx_consumed_packets} + 33'd1;
    // A one-byte packet can become visible immediately after its admission
    // pulse. Permit its acceptance and application-consumption events to be
    // accounted on the same clock edge.
    wire [64:0] accepted_bytes_with_current =
        {1'b0,rx_accepted_bytes} +
        ((rx_accept_valid && rx_accept_ready) ? rx_accept_bytes : 16'd0);
    wire [32:0] accepted_packets_with_current =
        {1'b0,rx_accepted_packets} +
        ((rx_accept_valid && rx_accept_ready) ? 33'd1 : 33'd0);

    assign tx_reserve_ready = (tx_bytes_sum[64] == 1'b0) &&
        (tx_packets_sum[32] == 1'b0) &&
        (tx_bytes_sum[63:0] <= remote_byte_limit) &&
        (tx_packets_sum[31:0] <= remote_packet_limit) &&
        (tx_reserved_packets < 32'hffff_ffff);
    assign rx_accept_ready = (rx_bytes_sum[64] == 1'b0) &&
        (rx_packets_sum[32] == 1'b0) &&
        (rx_bytes_sum[63:0] <= local_byte_limit) &&
        (rx_packets_sum[31:0] <= local_packet_limit) &&
        (rx_accepted_packets < 32'hffff_ffff);

    // Cumulative grants are independent and monotonic. Saturate at the
    // counter maximum; the protocol requires session restart before wrap.
    assign local_byte_limit =
        (INITIAL_RX_BYTES + rx_consumed_bytes < INITIAL_RX_BYTES) ?
        64'hffff_ffff_ffff_ffff : INITIAL_RX_BYTES + rx_consumed_bytes;
    assign local_packet_limit =
        (INITIAL_RX_PACKETS + rx_consumed_packets < INITIAL_RX_PACKETS) ?
        32'hffff_ffff : INITIAL_RX_PACKETS + rx_consumed_packets;

    always @(posedge clk) begin
        if (rst) begin
            tx_reserved_bytes <= 0;
            tx_reserved_packets <= 0;
            rx_accepted_bytes <= 0;
            rx_accepted_packets <= 0;
            rx_consumed_bytes <= 0;
            rx_consumed_packets <= 0;
            credit_error <= 0;
        end else begin
            // READY/VALID backpressure is not a protocol violation. Account
            // only accepted handshakes; upstream must hold VALID and payload
            // stable until READY is observed.
            if (tx_reserve_valid && tx_reserve_ready) begin
                tx_reserved_bytes <= tx_bytes_sum[63:0];
                tx_reserved_packets <= tx_packets_sum[31:0];
            end
            if (rx_accept_valid && rx_accept_ready) begin
                rx_accepted_bytes <= rx_bytes_sum[63:0];
                rx_accepted_packets <= rx_packets_sum[31:0];
            end else if (rx_accept_valid && !rx_accept_ready) begin
                // Unlike sender-side reservation backpressure, this event is
                // emitted after the reorder buffer has stored the packet. It
                // therefore indicates that the peer exceeded its grant.
                credit_error <= 1'b1;
            end
            if (rx_consume_valid) begin
                if ((consume_bytes_sum[64] == 1'b0) &&
                    (consume_packets_sum[32] == 1'b0) &&
                    (consume_bytes_sum <= accepted_bytes_with_current) &&
                    (consume_packets_sum <= accepted_packets_with_current)) begin
                    rx_consumed_bytes <= consume_bytes_sum[63:0];
                    rx_consumed_packets <= consume_packets_sum[31:0];
                end else begin
                    credit_error <= 1'b1;
                end
            end
        end
    end
endmodule
