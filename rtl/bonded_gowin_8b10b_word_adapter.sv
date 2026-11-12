// SPDX-License-Identifier: BSD-2-Clause
// Gowin Customized PHY 8b/10b interface mapper for an 80-bit TX / 88-bit RX
// fabric word (eight 10-bit symbols plus eight RX decoder-error flags).
// The generic side is eight decoded bytes plus eight K-character flags.
module bonded_gowin_8b10b_word_adapter (
    input wire [63:0] tx_data,
    input wire [7:0] tx_ctrl,
    output wire [79:0] gowin_tx_data,

    input wire [87:0] gowin_rx_data,
    output wire [63:0] rx_data,
    output wire [7:0] rx_ctrl,
    output wire [7:0] rx_disparity_error,
    output wire [7:0] rx_decoder_error,
    output wire rx_symbol_error
);
    genvar i;
    generate for(i=0;i<8;i=i+1) begin: symbol_map
        // Gowin TX table 3-6: Code[7:0], K[8], bit[9] reserved.
        assign gowin_tx_data[10*i +: 8]=tx_data[8*i +: 8];
        assign gowin_tx_data[10*i + 8]=tx_ctrl[i];
        assign gowin_tx_data[10*i + 9]=1'b0;

        // Gowin RX table 3-9: Code[7:0], K[8], disparity error[9].
        // Decoder-error flags are packed separately at bits [87:80].
        assign rx_data[8*i +: 8]=gowin_rx_data[10*i +: 8];
        assign rx_ctrl[i]=gowin_rx_data[10*i + 8];
        assign rx_disparity_error[i]=gowin_rx_data[10*i + 9];
        assign rx_decoder_error[i]=gowin_rx_data[80+i];
    end endgenerate

    assign rx_symbol_error=(|rx_disparity_error) || (|rx_decoder_error);
endmodule
