// SPDX-License-Identifier: BSD-2-Clause
// Per-lane 8b/10b PHY word bridge with session-drop flushing.
// Control traffic remains available while session_active is low. A falling
// session_active edge generates a one-cycle local flush in each lane clock
// domain; TX continues to emit idle K-characters and RX drains/discards the
// physical FIFO for that flush cycle.
module bonded_lane_phy_word_bridge #(
    parameter integer SYMBOLS_PER_WORD=4,
    parameter integer DATA_BYTES_PER_WORD=1,
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
    output reg tx_error,

    input wire rx_clk,
    input wire rx_rst_n,
    input wire rx_phy_valid,
    output wire rx_phy_ready,
    input wire [SYMBOLS_PER_WORD*8-1:0] rx_phy_data,
    input wire [SYMBOLS_PER_WORD-1:0] rx_phy_ctrl,
    output wire rx_byte_valid,
    input wire rx_byte_ready,
    output wire [7:0] rx_byte_data,
    output reg rx_overflow,
    output reg rx_symbol_error,
    output reg rx_gearbox_error
);
    initial begin
        if(DATA_BYTES_PER_WORD<1 || DATA_BYTES_PER_WORD>SYMBOLS_PER_WORD)
            $error("DATA_BYTES_PER_WORD must be between 1 and SYMBOLS_PER_WORD");
    end

    (* async_reg = "true" *) reg [1:0] tx_active_sync,rx_active_sync;
    reg tx_active_d,rx_active_d;
    wire tx_flush=tx_active_d && !tx_active_sync[1];
    wire rx_flush=rx_active_d && !rx_active_sync[1];
    wire tx_packer_rst=!tx_rst_n || tx_flush;
    wire rx_adapter_rst=!rx_rst_n || rx_flush;

    always @(posedge tx_clk or negedge tx_rst_n) begin
        if(!tx_rst_n) begin
            tx_active_sync<=0;
            tx_active_d<=0;
        end else begin
            tx_active_sync<={tx_active_sync[0],session_active};
            tx_active_d<=tx_active_sync[1];
        end
    end

    always @(posedge rx_clk or negedge rx_rst_n) begin
        if(!rx_rst_n) begin
            rx_active_sync<=0;
            rx_active_d<=0;
        end else begin
            rx_active_sync<={rx_active_sync[0],session_active};
            rx_active_d<=rx_active_sync[1];
        end
    end

    wire tx_word_valid,tx_word_ready,tx_word_sop;
    wire [SYMBOLS_PER_WORD*8-1:0] tx_word_data;
    wire [SYMBOLS_PER_WORD-1:0] tx_word_keep;
    wire tx_packer_error,tx_symbol_error;
    wire rx_word_valid,rx_word_ready,rx_word_sop;
    wire [SYMBOLS_PER_WORD*8-1:0] rx_word_data;
    wire [SYMBOLS_PER_WORD-1:0] rx_word_keep;
    wire rx_overflow_int,rx_symbol_error_int,rx_gearbox_error_int;
    wire rx_phy_ready_int;
    wire rx_unpacker_ready;
    reg rx_drop_until_sop;
    wire rx_word_to_unpacker_valid=rx_word_valid && (!rx_drop_until_sop || rx_word_sop);

    bonded_byte_to_phy_word #(.SYMBOLS_PER_WORD(SYMBOLS_PER_WORD),
        .DATA_BYTES_PER_WORD(DATA_BYTES_PER_WORD)) tx_packer (
        .clk(tx_clk),.rst(tx_packer_rst),
        .byte_valid(tx_byte_valid),.byte_ready(tx_byte_ready),
        .byte_data(tx_byte_data),.byte_sop(tx_byte_sop),.byte_eop(tx_byte_eop),
        .word_valid(tx_word_valid),.word_ready(tx_word_ready),
        .word_data(tx_word_data),.word_keep(tx_word_keep),.word_sop(tx_word_sop),
        .packet_error(tx_packer_error)
    );

    // The PHY TX side is reset only by the physical lane reset, not by a
    // session drop, so it continues to transmit comma/empty idles for CDR.
    bonded_phy_8b10b_word_adapter #(
        .SYMBOLS_PER_WORD(SYMBOLS_PER_WORD),
        .RX_FIFO_DEPTH(RX_FIFO_DEPTH),
        .RX_PHY_STALLABLE(RX_PHY_STALLABLE)
    ) symbol_adapter (
        .tx_clk(tx_clk),.tx_rst(!tx_rst_n),
        .rx_clk(rx_clk),.rx_rst(rx_adapter_rst),
        .tx_valid(tx_word_valid),.tx_ready(tx_word_ready),
        .tx_data(tx_word_data),.tx_keep(tx_word_keep),.tx_sop(tx_word_sop),
        .tx_phy_valid(tx_phy_valid),.tx_phy_ready(tx_phy_ready),
        .tx_phy_data(tx_phy_data),.tx_phy_ctrl(tx_phy_ctrl),.tx_error(tx_symbol_error),
        .rx_phy_valid(rx_phy_valid && !rx_flush),.rx_phy_ready(rx_phy_ready_int),
        .rx_phy_data(rx_phy_data),.rx_phy_ctrl(rx_phy_ctrl),
        .rx_valid(rx_word_valid),.rx_ready(rx_word_ready),
        .rx_data(rx_word_data),.rx_keep(rx_word_keep),.rx_sop(rx_word_sop),
        .rx_overflow(rx_overflow_int),.rx_symbol_error(rx_symbol_error_int)
    );

    // After a session drop, discard continuation words until the next
    // comma-marked SOP. This drains the old frame tail but still permits
    // HELLO/READY CONTROL frames while the session is being re-established.
    assign rx_word_ready=(rx_drop_until_sop && !rx_word_sop) ? 1'b1 : rx_unpacker_ready;

    bonded_phy_word_to_byte #(.SYMBOLS_PER_WORD(SYMBOLS_PER_WORD)) rx_unpacker (
        .clk(rx_clk),.rst(rx_adapter_rst),
        .word_valid(rx_word_to_unpacker_valid),.word_ready(rx_unpacker_ready),
        .word_data(rx_word_data),.word_keep(rx_word_keep),.word_sop(rx_word_sop),
        .byte_valid(rx_byte_valid),.byte_ready(rx_byte_ready),
        .byte_data(rx_byte_data),.byte_sop(),
        .word_error(rx_gearbox_error_int)
    );

    // While a session-drop pulse flushes the decoder, drain and discard the
    // vendor RX FIFO so pre-drop symbols cannot leak into the next session.
    assign rx_phy_ready=rx_rst_n && (rx_flush ? 1'b1 : rx_phy_ready_int);

    always @(posedge rx_clk or negedge rx_rst_n) begin
        if(!rx_rst_n)
            rx_drop_until_sop<=1'b0;
        else if(rx_flush)
            rx_drop_until_sop<=1'b1;
        else if(rx_word_valid && rx_word_ready && rx_word_sop)
            rx_drop_until_sop<=1'b0;
    end

    // Fault indications are sticky until the physical RX reset. They therefore
    // remain asserted long enough for the bonding-clock control manager to
    // sample them, even though the decoder is flushed on session drop.
    always @(posedge tx_clk or negedge tx_rst_n) begin
        if(!tx_rst_n)
            tx_error<=1'b0;
        else if(tx_packer_error || tx_symbol_error)
            tx_error<=1'b1;
    end

    always @(posedge rx_clk or negedge rx_rst_n) begin
        if(!rx_rst_n) begin
            rx_overflow<=1'b0;
            rx_symbol_error<=1'b0;
            rx_gearbox_error<=1'b0;
        end else begin
            if(rx_overflow_int) rx_overflow<=1'b1;
            if(rx_symbol_error_int) rx_symbol_error<=1'b1;
            if(rx_gearbox_error_int) rx_gearbox_error<=1'b1;
        end
    end
endmodule
