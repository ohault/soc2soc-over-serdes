// SPDX-License-Identifier: BSD-2-Clause
// Parallel 8b/10b PHY word adapter. The byte sequence delivered to the generic
// transport is unchanged; K28.5 is inserted at frame start/idle and K28.0
// marks unused symbols. Supports 2- and 4-symbol decoded PHY words.
module bonded_phy_8b10b_word_adapter #(
    parameter integer SYMBOLS_PER_WORD=4,
    parameter integer RX_FIFO_DEPTH=16,
    parameter integer RX_PHY_STALLABLE=0,
    parameter [7:0] IDLE_K=8'hbc,
    parameter [7:0] EMPTY_K=8'h1c,
    parameter integer PTR_WIDTH=(RX_FIFO_DEPTH<=2)?1:$clog2(RX_FIFO_DEPTH)
) (
    input wire tx_clk,
    input wire tx_rst,
    input wire rx_clk,
    input wire rx_rst,

    input wire tx_valid,
    output wire tx_ready,
    input wire [SYMBOLS_PER_WORD*8-1:0] tx_data,
    input wire [SYMBOLS_PER_WORD-1:0] tx_keep,
    input wire tx_sop,
    output wire tx_phy_valid,
    input wire tx_phy_ready,
    output wire [SYMBOLS_PER_WORD*8-1:0] tx_phy_data,
    output wire [SYMBOLS_PER_WORD-1:0] tx_phy_ctrl,
    output reg tx_error,

    input wire rx_phy_valid,
    output wire rx_phy_ready,
    input wire [SYMBOLS_PER_WORD*8-1:0] rx_phy_data,
    input wire [SYMBOLS_PER_WORD-1:0] rx_phy_ctrl,
    output wire rx_valid,
    input wire rx_ready,
    output wire [SYMBOLS_PER_WORD*8-1:0] rx_data,
    output wire [SYMBOLS_PER_WORD-1:0] rx_keep,
    output wire rx_sop,
    output reg rx_overflow,
    output reg rx_symbol_error
);
    localparam integer DATA_WIDTH=SYMBOLS_PER_WORD*8;
    localparam integer KEEP_WIDTH=SYMBOLS_PER_WORD;
    localparam integer WORD_WIDTH=DATA_WIDTH+KEEP_WIDTH+1;

    function keep_is_contiguous(input [KEEP_WIDTH-1:0] keep);
        begin
            keep_is_contiguous=(keep!=0) && ((keep & (keep+1'b1))==0);
        end
    endfunction

    wire tx_keep_bad = tx_valid &&
        (!keep_is_contiguous(tx_keep) || (tx_sop && tx_keep[SYMBOLS_PER_WORD-1]));
    // PHY VALID describes the continuously produced word stream (including
    // idle words) and must not be gated by READY. The application-side READY
    // is the actual transfer condition and backpressures the source.
    assign tx_phy_valid=!tx_rst && (tx_valid || tx_phy_ready) && !tx_keep_bad;
    assign tx_ready=!tx_rst && tx_phy_ready && !tx_keep_bad;

    genvar g;
    generate for(g=0;g<SYMBOLS_PER_WORD;g=g+1) begin: tx_symbol_map
        if(g==0) begin
            assign tx_phy_data[8*g +: 8]=(tx_valid && !tx_sop && tx_keep[g]) ?
                tx_data[8*g +: 8] : IDLE_K;
            assign tx_phy_ctrl[g]=!(tx_valid && !tx_sop && tx_keep[g]);
        end else begin
            if(g==1) begin
                assign tx_phy_data[8*g +: 8]=(tx_valid && tx_sop && tx_keep[g-1]) ?
                    tx_data[8*(g-1) +: 8] :
                    ((tx_valid && !tx_sop && tx_keep[g]) ? tx_data[8*g +: 8] : EMPTY_K);
                assign tx_phy_ctrl[g]=!((tx_valid && tx_sop && tx_keep[g-1]) ||
                                         (tx_valid && !tx_sop && tx_keep[g]));
            end else begin
                assign tx_phy_data[8*g +: 8]=(tx_valid && tx_sop) ?
                    (tx_keep[g-1] ? tx_data[8*(g-1) +: 8] : EMPTY_K) :
                    (tx_valid && tx_keep[g] ? tx_data[8*g +: 8] : EMPTY_K);
                assign tx_phy_ctrl[g]=tx_valid && tx_sop ? !tx_keep[g-1] :
                                      !(tx_valid && tx_keep[g]);
            end
        end
    end endgenerate

    reg [DATA_WIDTH-1:0] decoded_data;
    reg [KEEP_WIDTH-1:0] decoded_keep;
    reg decoded_sop;
    reg decoded_malformed;
    reg seen_empty;
    integer i;
    integer out_index;
    wire rx_is_comma=rx_phy_ctrl[0] && (rx_phy_data[7:0]==IDLE_K);

    always @* begin
        decoded_data=0;
        decoded_keep=0;
        decoded_sop=1'b0;
        decoded_malformed=1'b0;
        seen_empty=1'b0;
        out_index=0;
        decoded_sop=rx_is_comma;

        for(i=0;i<SYMBOLS_PER_WORD;i=i+1) begin
            if(i==0 && rx_is_comma) begin
                // K28.5 is a word-aligned frame-start or idle marker.
            end else if(!rx_phy_ctrl[i]) begin
                if(seen_empty) decoded_malformed=1'b1;
                else begin
                    decoded_data[8*out_index +: 8]=rx_phy_data[8*i +: 8];
                    decoded_keep[out_index]=1'b1;
                    out_index=out_index+1;
                end
            end else if(rx_phy_data[8*i +: 8]==EMPTY_K) begin
                seen_empty=1'b1;
            end else begin
                decoded_malformed=1'b1;
            end
        end

        if(!rx_is_comma && out_index==0)
            decoded_malformed=1'b1;
        if(rx_is_comma && out_index==0)
            decoded_sop=1'b0; // Idle comma word, not a frame.
    end

    reg [WORD_WIDTH-1:0] rx_mem[0:RX_FIFO_DEPTH-1];
    reg [PTR_WIDTH-1:0] wr_ptr,rd_ptr;
    reg [PTR_WIDTH:0] count;
    wire rx_pop=rx_valid && rx_ready;
    wire rx_space=(count<RX_FIFO_DEPTH) || rx_pop;
    assign rx_phy_ready=!rx_rst && (!RX_PHY_STALLABLE || rx_space);
    wire rx_accept=rx_phy_valid && rx_phy_ready;
    wire decoded_has_data=(decoded_keep!=0);
    wire rx_push=rx_accept && decoded_has_data && !decoded_malformed && rx_space;

    assign rx_valid=!rx_rst && (count!=0);
    assign {rx_sop,rx_keep,rx_data}=rx_mem[rd_ptr];

    initial begin
        if((SYMBOLS_PER_WORD!=2) && (SYMBOLS_PER_WORD!=4) && (SYMBOLS_PER_WORD!=8))
            $error("SYMBOLS_PER_WORD must be 2, 4 or 8");
        if(RX_FIFO_DEPTH<2 || (RX_FIFO_DEPTH & (RX_FIFO_DEPTH-1))!=0)
            $error("RX_FIFO_DEPTH must be a power of two >= 2");
        if(IDLE_K==EMPTY_K)
            $error("IDLE_K comma and EMPTY_K marker must be different");
    end

    // TX and recovered-RX are independent clock domains. The physical PHY
    // wrapper supplies its native TX user clock and recovered RX user clock;
    // no READY/VALID signal is allowed to cross between these domains.
    always @(posedge tx_clk) begin
        if(tx_rst)
            tx_error<=1'b0;
        else if(tx_keep_bad)
            tx_error<=1'b1;
    end

    always @(posedge rx_clk) begin
        if(rx_rst) begin
            wr_ptr<=0;
            rd_ptr<=0;
            count<=0;
            rx_overflow<=1'b0;
            rx_symbol_error<=1'b0;
        end else begin
            if(rx_accept && decoded_malformed)
                rx_symbol_error<=1'b1;
            if(rx_phy_valid && rx_phy_ready && decoded_has_data &&
               !decoded_malformed && !rx_space)
                rx_overflow<=1'b1;

            if(rx_push) begin
                rx_mem[wr_ptr]<={decoded_sop,decoded_keep,decoded_data};
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
