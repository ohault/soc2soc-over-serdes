// SPDX-License-Identifier: BSD-2-Clause
// Ready/valid boundary adapter for the Gowin Customized PHY FIFO interface.
// The module is independent of the Gowin primitive/IP instance itself.
module bonded_gowin_phy_fifo_adapter #(
    parameter integer SYMBOLS_PER_WORD=4,
    parameter integer RX_FIFO_DEPTH=8
) (
    input wire tx_clk,
    input wire tx_rst,
    input wire tx_phy_valid,
    output wire tx_phy_ready,
    input wire [SYMBOLS_PER_WORD*8-1:0] tx_phy_data,
    input wire [SYMBOLS_PER_WORD-1:0] tx_phy_ctrl,
    output wire tx_fifo_wren,
    input wire tx_fifo_afull,
    output wire [SYMBOLS_PER_WORD*10-1:0] tx_fifo_data,

    input wire rx_clk,
    input wire rx_rst,
    input wire rx_fifo_aempty,
    output wire rx_fifo_rden,
    input wire rx_fifo_data_valid,
    input wire [SYMBOLS_PER_WORD*11-1:0] rx_fifo_data,
    output wire rx_phy_valid,
    input wire rx_phy_ready,
    output wire [SYMBOLS_PER_WORD*8-1:0] rx_phy_data,
    output wire [SYMBOLS_PER_WORD-1:0] rx_phy_ctrl,
    output wire [SYMBOLS_PER_WORD-1:0] rx_disparity_error,
    output wire [SYMBOLS_PER_WORD-1:0] rx_decoder_error,
    output wire rx_symbol_error,
    output wire rx_fifo_overflow,
    output wire rx_fifo_protocol_error
);
    wire [SYMBOLS_PER_WORD*11-1:0] rx_fifo_word;
    wire rx_fifo_word_valid;
    wire mapper_error;

    assign tx_phy_ready=!tx_rst && !tx_fifo_afull;
    assign tx_fifo_wren=tx_phy_valid && tx_phy_ready;

    bonded_gowin_8b10b_word_adapter #(
        .SYMBOLS_PER_WORD(SYMBOLS_PER_WORD)
    ) symbol_mapper (
        .tx_data(tx_phy_data),
        .tx_ctrl(tx_phy_ctrl),
        .gowin_tx_data(tx_fifo_data),
        .gowin_rx_data(rx_fifo_word),
        .rx_data(rx_phy_data),
        .rx_ctrl(rx_phy_ctrl),
        .rx_disparity_error(rx_disparity_error),
        .rx_decoder_error(rx_decoder_error),
        .rx_symbol_error(mapper_error)
    );

    bonded_phy_fifo_read_adapter #(
        .DATA_WIDTH(SYMBOLS_PER_WORD*11),
        .DEPTH(RX_FIFO_DEPTH)
    ) rx_fifo_adapter (
        .clk(rx_clk),.rst(rx_rst),
        .fifo_empty(rx_fifo_aempty),.fifo_rdreq(rx_fifo_rden),
        .fifo_data_valid(rx_fifo_data_valid),.fifo_data(rx_fifo_data),
        .out_valid(rx_fifo_word_valid),.out_ready(rx_phy_ready),
        .out_data(rx_fifo_word),
        .overflow(rx_fifo_overflow),
        .protocol_error(rx_fifo_protocol_error)
    );

    assign rx_phy_valid=rx_fifo_word_valid;
    assign rx_symbol_error=rx_phy_valid && mapper_error;
endmodule
