// SPDX-License-Identifier: BSD-2-Clause
`timescale 1ns/1ps
module tb_bonded_gowin_8b10b_word_adapter;
    reg [63:0] tx_data=0;
    reg [7:0] tx_ctrl=0;
    wire [79:0] gowin_tx_data;
    reg [87:0] gowin_rx_data=0;
    wire [63:0] rx_data;
    wire [7:0] rx_ctrl,rx_disparity_error,rx_decoder_error;
    wire rx_symbol_error;

    bonded_gowin_8b10b_word_adapter dut(
        .tx_data(tx_data),.tx_ctrl(tx_ctrl),.gowin_tx_data(gowin_tx_data),
        .gowin_rx_data(gowin_rx_data),.rx_data(rx_data),.rx_ctrl(rx_ctrl),
        .rx_disparity_error(rx_disparity_error),
        .rx_decoder_error(rx_decoder_error),.rx_symbol_error(rx_symbol_error)
    );

    integer i;
    reg [63:0] expected_data;
    reg [7:0] expected_ctrl;

    initial begin
        expected_data=0;
        expected_ctrl=8'b10010001;
        for(i=0;i<8;i=i+1) begin
            expected_data[8*i +: 8]=8'h31+i*7;
            tx_data[8*i +: 8]=8'h31+i*7;
        end
        tx_ctrl=expected_ctrl;
        #1;
        for(i=0;i<8;i=i+1) begin
            if(gowin_tx_data[10*i +: 8]!==tx_data[8*i +: 8] ||
               gowin_tx_data[10*i+8]!==tx_ctrl[i] ||
               gowin_tx_data[10*i+9]!==1'b0)
                $fatal(1,"Gowin TX symbol %0d mapping incorrect",i);
        end

        // RX table 3-9: eight 10-bit symbol groups plus decoder flags [87:80].
        gowin_rx_data=0;
        for(i=0;i<8;i=i+1) begin
            gowin_rx_data[10*i +: 8]=8'hA0+i;
            gowin_rx_data[10*i+8]=((i%2)==0);
        end
        #1;
        for(i=0;i<8;i=i+1) begin
            if(rx_data[8*i +: 8] !== (8'hA0+i) ||
               rx_ctrl[i] !== ((i%2)==0))
                $fatal(1,"Gowin RX symbol %0d data/K mapping incorrect",i);
        end
        if(rx_symbol_error || rx_disparity_error!==0 || rx_decoder_error!==0)
            $fatal(1,"clean RX word incorrectly reported an error");

        gowin_rx_data[10*3+9]=1'b1;
        #1;
        if(!rx_symbol_error || !rx_disparity_error[3])
            $fatal(1,"RX disparity error bit not propagated");

        gowin_rx_data[10*3+9]=1'b0;
        gowin_rx_data[80+6]=1'b1;
        #1;
        if(!rx_symbol_error || !rx_decoder_error[6])
            $fatal(1,"RX decoder error bit not propagated");

        $display("PASS: Gowin 80/88-bit TX/RX symbol and error-bit mapping");
        $finish;
    end
endmodule
