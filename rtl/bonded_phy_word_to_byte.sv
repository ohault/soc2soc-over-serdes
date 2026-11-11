// SPDX-License-Identifier: BSD-2-Clause
// Unpacks PHY words into the original byte stream. PHY comma/empty symbols
// have already been removed by bonded_phy_8b10b_word_adapter.
module bonded_phy_word_to_byte #(
    parameter integer SYMBOLS_PER_WORD=4,
    parameter integer COUNT_WIDTH=(SYMBOLS_PER_WORD<=2)?2:$clog2(SYMBOLS_PER_WORD+1)
) (
    input wire clk,
    input wire rst,
    input wire word_valid,
    output wire word_ready,
    input wire [SYMBOLS_PER_WORD*8-1:0] word_data,
    input wire [SYMBOLS_PER_WORD-1:0] word_keep,
    input wire word_sop,
    output wire byte_valid,
    input wire byte_ready,
    output wire [7:0] byte_data,
    output wire byte_sop,
    output reg word_error
);
    reg holding;
    reg [SYMBOLS_PER_WORD*8-1:0] held_data;
    reg [SYMBOLS_PER_WORD-1:0] held_keep;
    reg held_sop;
    reg [COUNT_WIDTH-1:0] byte_index;
    reg [COUNT_WIDTH-1:0] byte_count;
    integer i;
    reg keep_bad;

    always @* begin
        byte_count=0;
        keep_bad=(word_keep==0) || ((word_keep & (word_keep+1'b1))!=0);
        for(i=0;i<SYMBOLS_PER_WORD;i=i+1)
            byte_count=byte_count+word_keep[i];
    end

    assign byte_valid=!rst && holding;
    assign byte_data=held_data[byte_index*8 +: 8];
    assign byte_sop=byte_valid && held_sop && (byte_index==0);
    wire byte_pop=byte_valid && byte_ready;
    wire last_byte=(byte_index+1'b1>=held_count);
    reg [COUNT_WIDTH-1:0] held_count;
    assign word_ready=!rst && (!holding || (byte_pop && last_byte));

    always @(posedge clk) begin
        if(rst) begin
            holding<=0;
            held_data<=0;
            held_keep<=0;
            held_sop<=0;
            held_count<=0;
            byte_index<=0;
            word_error<=0;
        end else begin
            if(byte_pop) begin
                if(last_byte) begin
                    holding<=0;
                    byte_index<=0;
                end else byte_index<=byte_index+1'b1;
            end

            if(word_valid && word_ready) begin
                if(keep_bad) begin
                    word_error<=1;
                end else begin
                    holding<=1;
                    held_data<=word_data;
                    held_keep<=word_keep;
                    held_sop<=word_sop;
                    held_count<=byte_count;
                    byte_index<=0;
                end
            end
        end
    end
endmodule
