// SPDX-License-Identifier: BSD-2-Clause
`timescale 1ns/1ps
module tb_bonded_lane_phy_session_flush;
    reg tx_clk=0,rx_clk=0;
    always #5 tx_clk=~tx_clk;
    always #7 rx_clk=~rx_clk;
    reg tx_rst_n=0,rx_rst_n=0,session_active=0;
    wire tx_byte_ready,tx_phy_valid,tx_error;
    wire [31:0] tx_phy_data;
    wire [3:0] tx_phy_ctrl;
    reg rx_phy_valid=0;
    wire rx_phy_ready,rx_byte_valid;
    reg [31:0] rx_phy_data=0;
    reg [3:0] rx_phy_ctrl=0;
    wire [7:0] rx_byte_data;
    wire rx_overflow,rx_symbol_error,rx_gearbox_error;

    bonded_lane_phy_word_bridge #(
        .SYMBOLS_PER_WORD(4),.RX_FIFO_DEPTH(8),.RX_PHY_STALLABLE(1)
    ) dut (
        .session_active(session_active),
        .tx_clk(tx_clk),.tx_rst_n(tx_rst_n),
        .tx_byte_valid(1'b0),.tx_byte_ready(tx_byte_ready),
        .tx_byte_data(8'd0),.tx_byte_sop(1'b0),.tx_byte_eop(1'b0),
        .tx_phy_valid(tx_phy_valid),.tx_phy_ready(1'b1),
        .tx_phy_data(tx_phy_data),.tx_phy_ctrl(tx_phy_ctrl),.tx_error(tx_error),
        .rx_clk(rx_clk),.rx_rst_n(rx_rst_n),
        .rx_phy_valid(rx_phy_valid),.rx_phy_ready(rx_phy_ready),
        .rx_phy_data(rx_phy_data),.rx_phy_ctrl(rx_phy_ctrl),
        .rx_byte_valid(rx_byte_valid),.rx_byte_ready(1'b1),.rx_byte_data(rx_byte_data),
        .rx_overflow(rx_overflow),.rx_symbol_error(rx_symbol_error),
        .rx_gearbox_error(rx_gearbox_error)
    );

    integer received=0;
    always @(posedge rx_clk) begin
        if(rx_byte_valid) begin
            case(received)
                0: if(rx_byte_data!==8'h11) $fatal(1,"initial frame byte 0");
                1: if(rx_byte_data!==8'h22) $fatal(1,"initial frame byte 1");
                2: if(rx_byte_data!==8'h33) $fatal(1,"initial frame byte 2");
                3: if(rx_byte_data!==8'ha1) $fatal(1,"post-flush frame byte 0 (stale data leaked)");
                4: if(rx_byte_data!==8'hc2) $fatal(1,"post-flush frame byte 1");
                5: if(rx_byte_data!==8'h33) $fatal(1,"post-flush frame byte 2");
                default: $fatal(1,"unexpected stale or duplicate byte %02x",rx_byte_data);
            endcase
            received=received+1;
        end
    end

    task send_phy_word(input [31:0] data,input [3:0] ctrl);
    begin
        @(negedge rx_clk);
        rx_phy_data=data;rx_phy_ctrl=ctrl;rx_phy_valid=1;
        while(rx_phy_ready !== 1'b1) @(negedge rx_clk);
        @(posedge rx_clk);
        @(negedge rx_clk);
        rx_phy_valid=0;
    end
    endtask

    initial begin
        #40;
        @(negedge tx_clk);tx_rst_n=1;
        @(negedge rx_clk);rx_rst_n=1;
        repeat(4) @(posedge rx_clk);
        session_active=1;
        repeat(4) @(posedge rx_clk);

        // Initial frame: K28.5 comma followed by three data characters.
        send_phy_word(32'h332211bc,4'b0001);
        wait(received==3);

        // Drop only the logical session; keep both physical clock domains and
        // the transceiver reset released. Old continuation words must be
        // drained until a fresh comma-marked SOP appears.
        @(negedge rx_clk);session_active=0;
        repeat(5) @(posedge rx_clk);
        send_phy_word(32'h77665544,4'b0000);

        @(negedge rx_clk);session_active=1;
        repeat(5) @(posedge rx_clk);
        send_phy_word(32'h88776655,4'b0000);
        send_phy_word(32'h33c2a1bc,4'b0001);
        wait(received==6);
        repeat(4) @(posedge rx_clk);
        if(received!=6 || rx_overflow || rx_symbol_error || rx_gearbox_error || tx_error)
            $fatal(1,"session flush recovery failed received=%0d",received);
        $display("PASS: PHY bridge drops stale continuation words across session reset and resumes at SOP");
        $finish;
    end
    initial begin #100000;$fatal(1,"timeout received=%0d",received);end
endmodule
