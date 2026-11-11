// SPDX-License-Identifier: BSD-2-Clause
// Bond-clock session gate. Lane reset release is synchronized into bond_clk;
// any lane reset assertion immediately disables application traffic.
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
    (* async_reg = "true" *) reg [1:0] lane0_tx_sync;
    (* async_reg = "true" *) reg [1:0] lane1_tx_sync;
    (* async_reg = "true" *) reg [1:0] lane0_rx_sync;
    (* async_reg = "true" *) reg [1:0] lane1_rx_sync;

    always @(posedge bond_clk or negedge bond_rst_n or negedge lane0_tx_rst_n) begin
        if (!bond_rst_n || !lane0_tx_rst_n) lane0_tx_sync <= 2'b00;
        else lane0_tx_sync <= {lane0_tx_sync[0],1'b1};
    end
    always @(posedge bond_clk or negedge bond_rst_n or negedge lane1_tx_rst_n) begin
        if (!bond_rst_n || !lane1_tx_rst_n) lane1_tx_sync <= 2'b00;
        else lane1_tx_sync <= {lane1_tx_sync[0],1'b1};
    end
    always @(posedge bond_clk or negedge bond_rst_n or negedge lane0_rx_rst_n) begin
        if (!bond_rst_n || !lane0_rx_rst_n) lane0_rx_sync <= 2'b00;
        else lane0_rx_sync <= {lane0_rx_sync[0],1'b1};
    end
    always @(posedge bond_clk or negedge bond_rst_n or negedge lane1_rx_rst_n) begin
        if (!bond_rst_n || !lane1_rx_rst_n) lane1_rx_sync <= 2'b00;
        else lane1_rx_sync <= {lane1_rx_sync[0],1'b1};
    end

    assign session_active = bond_rst_n && session_established &&
        lane0_tx_sync[1] && lane1_tx_sync[1] &&
        lane0_rx_sync[1] && lane1_rx_sync[1];
endmodule
