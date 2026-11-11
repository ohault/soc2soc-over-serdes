// SPDX-License-Identifier: BSD-2-Clause
// Board/SoC-agnostic adapter between a byte stream and a decoded 8b/10b
// PHY word containing two or four symbols. One data byte is carried in
// symbol 0 is a K28.5 alignment comma; symbol 1 carries data or K28.0
// empty; remaining symbols are zero-valued data fillers. This is a bring-up adapter,
// not a full-rate multi-byte datapath.
module bonded_phy_8b10b_adapter #(
    parameter integer SYMBOLS_PER_WORD=2,
    parameter integer RX_FIFO_DEPTH=64,
    parameter integer RX_PHY_STALLABLE=0,
    parameter [7:0] IDLE_K=8'hbc,
    parameter [7:0] EMPTY_K=8'h1c,
    parameter [7:0] FILL_BYTE=8'h00,
    parameter integer DATA_SYMBOL_INDEX=1,
    parameter integer PTR_WIDTH=(RX_FIFO_DEPTH<=2)?1:$clog2(RX_FIFO_DEPTH)
) (
    input wire clk,
    input wire rst,

    input wire tx_byte_valid,
    output wire tx_byte_ready,
    input wire [7:0] tx_byte_data,
    output wire tx_phy_valid,
    input wire tx_phy_ready,
    output wire [SYMBOLS_PER_WORD*8-1:0] tx_phy_data,
    output wire [SYMBOLS_PER_WORD-1:0] tx_phy_ctrl,

    input wire rx_phy_valid,
    output wire rx_phy_ready,
    input wire [SYMBOLS_PER_WORD*8-1:0] rx_phy_data,
    input wire [SYMBOLS_PER_WORD-1:0] rx_phy_ctrl,
    output wire rx_byte_valid,
    input wire rx_byte_ready,
    output wire [7:0] rx_byte_data,
    output reg rx_overflow,
    output reg rx_symbol_error
);
    localparam [7:0] IDLE=IDLE_K;
    reg [7:0] rx_mem[0:RX_FIFO_DEPTH-1];
    reg [PTR_WIDTH-1:0] wr_ptr,rd_ptr;
    reg [PTR_WIDTH:0] count;

    wire rx_word_has_data=!rx_phy_ctrl[DATA_SYMBOL_INDEX];
    reg rx_word_malformed;
    integer i;

    always @* begin
        rx_word_malformed=1'b0;
        // A unique K28.5 comma in symbol 0 establishes word alignment.
        if(!rx_phy_ctrl[0] || rx_phy_data[7:0]!=IDLE)
            rx_word_malformed=1'b1;
        for(i=1;i<SYMBOLS_PER_WORD;i=i+1) begin
            if(i==DATA_SYMBOL_INDEX) begin
                if(rx_phy_ctrl[i] && rx_phy_data[8*i +: 8]!=EMPTY_K)
                    rx_word_malformed=1'b1;
            end else begin
                if(rx_phy_ctrl[i] || rx_phy_data[8*i +: 8]!=FILL_BYTE)
                    rx_word_malformed=1'b1;
            end
        end
    end

    wire rx_pop=rx_byte_valid && rx_byte_ready;
    wire rx_space=(count<RX_FIFO_DEPTH) || rx_pop;
    assign rx_phy_ready=!rst &&
        (!RX_PHY_STALLABLE || !rx_phy_valid || !rx_word_has_data || rx_space || rx_word_malformed);
    wire rx_accept=rx_phy_valid && rx_phy_ready;
    wire rx_push=rx_accept && rx_word_has_data && !rx_word_malformed && rx_space;

    assign rx_byte_valid=!rst && (count!=0);
    assign rx_byte_data=rx_mem[rd_ptr];

    // The PHY side is a continuous symbol stream: transmit K28.5 idles when
    // no application byte is available. Symbol 0 always carries K28.5 so the
    // receiver can align each PHY word unambiguously.
    assign tx_phy_valid=!rst;
    assign tx_byte_ready=!rst && tx_phy_ready;
    genvar g;
    generate for(g=0;g<SYMBOLS_PER_WORD;g=g+1) begin: tx_symbols
        if(g==0) begin
            assign tx_phy_data[8*g +: 8]=IDLE;
            assign tx_phy_ctrl[g]=1'b1;
        end else if(g==DATA_SYMBOL_INDEX) begin
            assign tx_phy_data[8*g +: 8]=tx_byte_valid ? tx_byte_data : EMPTY_K;
            assign tx_phy_ctrl[g]=!tx_byte_valid;
        end else begin
            assign tx_phy_data[8*g +: 8]=FILL_BYTE;
            assign tx_phy_ctrl[g]=1'b0;
        end
    end endgenerate

    initial begin
        if((SYMBOLS_PER_WORD!=2) && (SYMBOLS_PER_WORD!=4))
            $error("SYMBOLS_PER_WORD must be 2 or 4");
        if(DATA_SYMBOL_INDEX<1 || DATA_SYMBOL_INDEX>=SYMBOLS_PER_WORD)
            $error("DATA_SYMBOL_INDEX must be in [1, SYMBOLS_PER_WORD-1]");
        if(RX_FIFO_DEPTH<2 || (RX_FIFO_DEPTH & (RX_FIFO_DEPTH-1))!=0)
            $error("RX_FIFO_DEPTH must be a power of two >= 2");
    end

    always @(posedge clk) begin
        if(rst) begin
            wr_ptr<=0;rd_ptr<=0;count<=0;
            rx_overflow<=1'b0;rx_symbol_error<=1'b0;
        end else begin
            if(rx_accept && rx_word_malformed)
                rx_symbol_error<=1'b1;
            if(rx_phy_valid && rx_phy_ready && rx_word_has_data &&
               !rx_word_malformed && !rx_space)
                rx_overflow<=1'b1;

            if(rx_push) begin
                rx_mem[wr_ptr]<=rx_phy_data[8*DATA_SYMBOL_INDEX +: 8];
                wr_ptr<=wr_ptr+1'b1;
            end
            if(rx_pop) rd_ptr<=rd_ptr+1'b1;
            case({rx_push,rx_pop})
                2'b10: count<=count+1'b1;
                2'b01: count<=count-1'b1;
                default: count<=count;
            endcase
        end
    end
endmodule
