// SPDX-License-Identifier: BSD-2-Clause
`timescale 1ns/1ps
module tb_bonded_lane_phy_word_bridge;
    reg tx_clk=0,rx_clk=0;
    always #5 tx_clk=~tx_clk;
    always #7 rx_clk=~rx_clk;
    reg tx_rst_n=0,rx_rst_n=0,session_active=0;

    reg tx_valid=0,tx_sop=0,tx_eop=0;
    reg [7:0] tx_data=0;
    wire tx_ready;
    wire phy_tx_valid,phy_tx_ready;
    wire [31:0] phy_tx_data;
    wire [3:0] phy_tx_ctrl;
    wire tx_error;

    wire phy_rx_valid,phy_rx_ready;
    wire [31:0] phy_rx_data;
    wire [3:0] phy_rx_ctrl;
    wire rx_valid;
    reg rx_ready=0;
    wire [7:0] rx_data;
    wire rx_overflow,rx_symbol_error,rx_gearbox_error;

    bonded_lane_phy_word_bridge #(
        .SYMBOLS_PER_WORD(4),.RX_FIFO_DEPTH(8),.RX_PHY_STALLABLE(1)
    ) dut (
        .session_active(session_active),
        .tx_clk(tx_clk),.tx_rst_n(tx_rst_n),
        .tx_byte_valid(tx_valid),.tx_byte_ready(tx_ready),
        .tx_byte_data(tx_data),.tx_byte_sop(tx_sop),.tx_byte_eop(tx_eop),
        .tx_phy_valid(phy_tx_valid),.tx_phy_ready(phy_tx_ready),
        .tx_phy_data(phy_tx_data),.tx_phy_ctrl(phy_tx_ctrl),.tx_error(tx_error),
        .rx_clk(rx_clk),.rx_rst_n(rx_rst_n),
        .rx_phy_valid(phy_rx_valid),.rx_phy_ready(phy_rx_ready),
        .rx_phy_data(phy_rx_data),.rx_phy_ctrl(phy_rx_ctrl),
        .rx_byte_valid(rx_valid),.rx_byte_ready(rx_ready),.rx_byte_data(rx_data),
        .rx_overflow(rx_overflow),.rx_symbol_error(rx_symbol_error),
        .rx_gearbox_error(rx_gearbox_error)
    );

    // A dual-clock FIFO models the physical lane and its independent recovered
    // RX user clock. It carries decoded symbols plus their K-character flags.
    bonded_async_fifo #(.DATA_WIDTH(36),.DEPTH(8)) channel (
        .wr_clk(tx_clk),.wr_rst_n(tx_rst_n && session_active),
        .wr_valid(phy_tx_valid),.wr_ready(phy_tx_ready),
        .wr_data({phy_tx_ctrl,phy_tx_data}),
        .rd_clk(rx_clk),.rd_rst_n(rx_rst_n && session_active),
        .rd_valid(phy_rx_valid),.rd_ready(phy_rx_ready),
        .rd_data({phy_rx_ctrl,phy_rx_data})
    );

    reg [7:0] expected[0:12];
    integer received=0,cycles=0;

    always @(posedge rx_clk) begin
        if(!rx_rst_n || !session_active) begin
            received<=0;
            cycles<=0;
        end else begin
            cycles<=cycles+1;
            rx_ready<=((cycles%9)!=3 && (cycles%9)!=4 && (cycles%9)!=5);
            if(rx_valid && rx_ready) begin
                if(received>=13 || rx_data!==expected[received])
                    $fatal(1,"byte mismatch at %0d: got %02x",received,rx_data);
                received<=received+1;
            end
        end
    end

    task send_byte(input [7:0] d,input s,input e);
    begin
        @(negedge tx_clk);
        tx_data=d;tx_sop=s;tx_eop=e;tx_valid=1;
        while(!tx_ready) @(negedge tx_clk);
        @(posedge tx_clk);
        @(negedge tx_clk);
        tx_valid=0;tx_sop=0;tx_eop=0;
    end
    endtask

    initial begin
        expected[0]=8'h53;expected[1]=8'h42;expected[2]=8'hbc;
        expected[3]=8'h1c;expected[4]=8'h00;expected[5]=8'hff;
        expected[6]=8'h10;expected[7]=8'h20;expected[8]=8'h30;
        expected[9]=8'h40;expected[10]=8'h50;expected[11]=8'h60;
        expected[12]=8'h7e;

        #50;
        @(negedge tx_clk);tx_rst_n=1;
        @(negedge rx_clk);rx_rst_n=1;
        repeat(4) @(posedge tx_clk);
        session_active=1;
        repeat(5) @(posedge rx_clk);

        send_byte(expected[0],1,0);
        send_byte(expected[1],0,0);
        send_byte(expected[2],0,0);
        send_byte(expected[3],0,0);
        send_byte(expected[4],0,0);
        send_byte(expected[5],0,0);
        send_byte(expected[6],0,0);
        send_byte(expected[7],0,0);
        send_byte(expected[8],0,0);
        send_byte(expected[9],0,0);
        send_byte(expected[10],0,0);
        send_byte(expected[11],0,0);
        send_byte(expected[12],0,1);

        wait(received==13);
        repeat(6) @(posedge rx_clk);
        if(tx_error || rx_overflow || rx_symbol_error || rx_gearbox_error)
            $fatal(1,"bridge asserted an unexpected error");
        $display("PASS: lane bridge crosses independent TX/RX clocks and preserves bytes");
        $finish;
    end
    initial begin #100000;$fatal(1,"timeout");end
endmodule
