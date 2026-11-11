// SPDX-License-Identifier: BSD-2-Clause
// One physical lane's byte-stream <-> parallel 8b/10b PHY boundary.
// TX uses the native TX user clock; RX uses that lane's recovered RX clock.
// This module contains no board primitive, transceiver IP or LiteX dependency.
module bonded_lane_phy_word_bridge #(
    parameter integer SYMBOLS_PER_WORD=4,
    parameter integer RX_FIFO_DEPTH=16,
    parameter integer RX_PHY_STALLABLE=0
) (
    input wire session_active,

    input wire tx_clk,
    input wire tx_rst_n,
    input wire tx_byte_valid,
    output wire tx_byte_ready,
    input wire [7:0] tx_byte_data,
    input wire tx_byte_sop,
    input wire tx_byte_eop,

    output wire tx_phy_valid,
    input wire tx_phy_ready,
    output wire [SYMBOLS_PER_WORD*8-1:0] tx_phy_data,
    output wire [SYMBOLS_PER_WORD-1:0] tx_phy_ctrl,
    output wire tx_error,

    input wire rx_clk,
    input wire rx_rst_n,
    input wire rx_phy_valid,
    output wire rx_phy_ready,
    input wire [SYMBOLS_PER_WORD*8-1:0] rx_phy_data,
    input wire [SYMBOLS_PER_WORD-1:0] rx_phy_ctrl,

    output wire rx_byte_valid,
    input wire rx_byte_ready,
    output wire [7:0] rx_byte_data,
    output wire rx_overflow,
    output wire rx_symbol_error,
    output wire rx_gearbox_error
);
    // session_active is generated in the bonding clock domain. Treat its
    // falling edge as an asynchronous reset assertion, but synchronize reset
    // release separately into the two unrelated PHY user-clock domains.
    wire tx_async_rst_n=tx_rst_n && session_active;
    wire rx_async_rst_n=rx_rst_n && session_active;
    (* async_reg = "true" *) reg [1:0] tx_reset_release;
    (* async_reg = "true" *) reg [1:0] rx_reset_release;

    always @(posedge tx_clk or negedge tx_async_rst_n) begin
        if(!tx_async_rst_n) tx_reset_release<=2'b00;
        else tx_reset_release<={tx_reset_release[0],1'b1};
    end
    always @(posedge rx_clk or negedge rx_async_rst_n) begin
        if(!rx_async_rst_n) rx_reset_release<=2'b00;
        else rx_reset_release<={rx_reset_release[0],1'b1};
    end

    wire tx_rst=!tx_reset_release[1];
    wire rx_rst=!rx_reset_release[1];

    wire word_valid,word_ready,word_sop,pack_error;
    wire [SYMBOLS_PER_WORD*8-1:0] word_data;
    wire [SYMBOLS_PER_WORD-1:0] word_keep;
    wire phy_rx_word_valid,phy_rx_word_ready,phy_rx_word_sop;
    wire [SYMBOLS_PER_WORD*8-1:0] phy_rx_word_data;
    wire [SYMBOLS_PER_WORD-1:0] phy_rx_word_keep;
    wire unpack_error;
    wire adapter_tx_error,adapter_rx_overflow,adapter_rx_symbol_error;

    bonded_byte_to_phy_word #(.SYMBOLS_PER_WORD(SYMBOLS_PER_WORD)) tx_packer (
        .clk(tx_clk),.rst(tx_rst),
        .byte_valid(tx_byte_valid),.byte_ready(tx_byte_ready),
        .byte_data(tx_byte_data),.byte_sop(tx_byte_sop),.byte_eop(tx_byte_eop),
        .word_valid(word_valid),.word_ready(word_ready),
        .word_data(word_data),.word_keep(word_keep),.word_sop(word_sop),
        .packet_error(pack_error)
    );

    bonded_phy_8b10b_word_adapter #(
        .SYMBOLS_PER_WORD(SYMBOLS_PER_WORD),
        .RX_FIFO_DEPTH(RX_FIFO_DEPTH),
        .RX_PHY_STALLABLE(RX_PHY_STALLABLE)
    ) phy_adapter (
        .tx_clk(tx_clk),.tx_rst(tx_rst),
        .rx_clk(rx_clk),.rx_rst(rx_rst),
        .tx_valid(word_valid),.tx_ready(word_ready),
        .tx_data(word_data),.tx_keep(word_keep),.tx_sop(word_sop),
        .tx_phy_valid(tx_phy_valid),.tx_phy_ready(tx_phy_ready),
        .tx_phy_data(tx_phy_data),.tx_phy_ctrl(tx_phy_ctrl),
        .tx_error(adapter_tx_error),
        .rx_phy_valid(rx_phy_valid),.rx_phy_ready(rx_phy_ready),
        .rx_phy_data(rx_phy_data),.rx_phy_ctrl(rx_phy_ctrl),
        .rx_valid(phy_rx_word_valid),.rx_ready(phy_rx_word_ready),
        .rx_data(phy_rx_word_data),.rx_keep(phy_rx_word_keep),
        .rx_sop(phy_rx_word_sop),
        .rx_overflow(adapter_rx_overflow),
        .rx_symbol_error(adapter_rx_symbol_error)
    );

    bonded_phy_word_to_byte #(.SYMBOLS_PER_WORD(SYMBOLS_PER_WORD)) rx_unpacker (
        .clk(rx_clk),.rst(rx_rst),
        .word_valid(phy_rx_word_valid),.word_ready(phy_rx_word_ready),
        .word_data(phy_rx_word_data),.word_keep(phy_rx_word_keep),
        .word_sop(phy_rx_word_sop),
        .byte_valid(rx_byte_valid),.byte_ready(rx_byte_ready),
        .byte_data(rx_byte_data),.byte_sop(),.word_error(unpack_error)
    );

    assign tx_error=pack_error | adapter_tx_error;
    assign rx_overflow=adapter_rx_overflow;
    assign rx_symbol_error=adapter_rx_symbol_error;
    assign rx_gearbox_error=unpack_error;
endmodule
