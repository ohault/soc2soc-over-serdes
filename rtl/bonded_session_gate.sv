// SPDX-License-Identifier: BSD-2-Clause
// Bond-clock session gate.
//
// All four physical directions participate in one bonded session. Any lane
// reset asynchronously asserts the common gate reset; release is synchronized
// into bond_clk. The endpoint uses session_active to flush BOTH datapaths,
// preventing stale packets/sequence state from surviving a partial lane reset.
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

    // One asynchronous reset input is used for portable FPGA synthesis.
    // Assertion is immediate; deassertion takes two bond_clk edges.
    always @(posedge bond_clk or negedge all_lanes_rst_n) begin
        if (!all_lanes_rst_n)
            lane_release_sync <= 2'b00;
        else
            lane_release_sync <= {lane_release_sync[0], 1'b1};
    end

    assign session_active = all_lanes_rst_n &&
                            lane_release_sync[1] &&
                            session_established;
endmodule
