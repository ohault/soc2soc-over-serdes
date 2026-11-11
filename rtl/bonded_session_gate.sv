// SPDX-License-Identifier: BSD-2-Clause
// Bond-clock session gate.
//
// All four physical directions participate in one bonded session. Any lane
// reset asynchronously drops the gate and clears the re-arm latch. After all
// lanes return, the external session controller MUST deassert
// session_established and then assert it again after peer renegotiation.
module bonded_session_gate (
    input wire bond_clk,
    input wire bond_rst_n,
    input wire session_established,
    input wire lane0_tx_rst_n,
    input wire lane1_tx_rst_n,
    input wire lane0_rx_rst_n,
    input wire lane1_rx_rst_n,
    output wire session_active
);
    wire all_lanes_rst_n = bond_rst_n &&
        lane0_tx_rst_n && lane1_tx_rst_n &&
        lane0_rx_rst_n && lane1_rx_rst_n;

    (* async_reg = "true" *) reg [1:0] lane_release_sync;
    reg session_rearm_armed;

    // Asynchronous assertion; two-cycle synchronous release.
    always @(posedge bond_clk or negedge all_lanes_rst_n) begin
        if (!all_lanes_rst_n)
            lane_release_sync <= 2'b00;
        else
            lane_release_sync <= {lane_release_sync[0], 1'b1};
    end

    // A lane fault invalidates the previous session even if the lane later
    // recovers. Require an explicit low->high session_established transition.
    always @(posedge bond_clk or negedge all_lanes_rst_n) begin
        if (!all_lanes_rst_n)
            session_rearm_armed <= 1'b0;
        else if (!session_established)
            session_rearm_armed <= 1'b1;
    end

    assign session_active = all_lanes_rst_n &&
                            lane_release_sync[1] &&
                            session_rearm_armed &&
                            session_established;
endmodule
