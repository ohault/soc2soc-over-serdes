// SPDX-License-Identifier: BSD-2-Clause
// Complete, board-neutral 8b/10b lane adapter.
// TX runs on the local transmitter user clock; RX runs on the recovered
// receiver user clock. The vendor PHY wrapper translates its native FIFO
// semantics into these ready/valid interfaces.
module bonded_phy_8b10b_lane_adapter #(
    parameter integer SYMBOLS_PER_WORD=4,
    parameter integer RX_FIFO_DEPTH=16,
    parameter integer RX_PHY_STALLABLE=0
) (
    input wire tx_clk,
    input wire tx_rst,
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
    input wire rx_rst,
    input wire rx_phy_valid,
    output wire rx_phy_ready,
    input wire [SYMBOLS_PER_WORD*8-1:0] rx_phy_data,
    input wire [SYMBOLS_PER_WORD-1:0] rx_phy_ctrl,
    output wire rx_byte_valid,
    input wire rx_byte_ready,
    output wire [7:0] rx_byte_data,
    output wire rx_byte_sop,
    output wire rx_fault
);
    wire tx_word_valid,tx_word_ready,tx_word_sop;
    wire [SYMBOLS_PER_WORD*8-1:0] tx_word_data;
    wire [SYMBOLS_PER_WORD-1:0] tx_word_keep;
    wire tx_packer_error,tx_symbol_error;
    wire rx_word_valid,rx_word_ready,rx_word_sop;
    wire [SYMBOLS_PER_WORD*8-1:0] rx_word_data;
    wire [SYMBOLS_PER_WORD-1:0] rx_word_keep;
    wire rx_overflow,rx_phy_symbol_error,rx_unpacker_error;

    bonded_byte_to_phy_word #(.SYMBOLS_PER_WORD(SYMBOLS_PER_WORD)) tx_packer (
        .clk(tx_clk),.rst(tx_rst),
        .byte_valid(tx_byte_valid),.byte_ready(tx_byte_ready),
        .byte_data(tx_byte_data),.byte_sop(tx_byte_sop),.byte_eop(tx_byte_eop),
        .word_valid(tx_word_valid),.word_ready(tx_word_ready),
        .word_data(tx_word_data),.word_keep(tx_word_keep),.word_sop(tx_word_sop),
        .packet_error(tx_packer_error)
    );

    bonded_phy_8b10b_word_adapter #(
        .SYMBOLS_PER_WORD(SYMBOLS_PER_WORD),
        .RX_FIFO_DEPTH(RX_FIFO_DEPTH),
        .RX_PHY_STALLABLE(RX_PHY_STALLABLE)
    ) symbol_adapter (
        .tx_clk(tx_clk),.tx_rst(tx_rst),.rx_clk(rx_clk),.rx_rst(rx_rst),
        .tx_valid(tx_word_valid),.tx_ready(tx_word_ready),
        .tx_data(tx_word_data),.tx_keep(tx_word_keep),.tx_sop(tx_word_sop),
        .tx_phy_valid(tx_phy_valid),.tx_phy_ready(tx_phy_ready),
        .tx_phy_data(tx_phy_data),.tx_phy_ctrl(tx_phy_ctrl),.tx_error(tx_symbol_error),
        .rx_phy_valid(rx_phy_valid),.rx_phy_ready(rx_phy_ready),
        .rx_phy_data(rx_phy_data),.rx_phy_ctrl(rx_phy_ctrl),
        .rx_valid(rx_word_valid),.rx_ready(rx_word_ready),
        .rx_data(rx_word_data),.rx_keep(rx_word_keep),.rx_sop(rx_word_sop),
        .rx_overflow(rx_overflow),.rx_symbol_error(rx_phy_symbol_error)
    );

    bonded_phy_word_to_byte #(.SYMBOLS_PER_WORD(SYMBOLS_PER_WORD)) rx_unpacker (
        .clk(rx_clk),.rst(rx_rst),
        .word_valid(rx_word_valid),.word_ready(rx_word_ready),
        .word_data(rx_word_data),.word_keep(rx_word_keep),.word_sop(rx_word_sop),
        .byte_valid(rx_byte_valid),.byte_ready(rx_byte_ready),
        .byte_data(rx_byte_data),.byte_sop(rx_byte_sop),
        .word_error(rx_unpacker_error)
    );

    assign tx_error=tx_packer_error | tx_symbol_error;
    assign rx_fault=rx_overflow | rx_phy_symbol_error | rx_unpacker_error;
endmodule
