// SPDX-License-Identifier: BSD-2-Clause
// Packs a byte-framed v0 wire stream into parallel PHY words.
// SOP words reserve symbol 0 for the K28.5 comma, so they carry N-1 bytes;
// continuation words carry N bytes. EOP flushes a partial final word.
module bonded_byte_to_phy_word #(
    parameter integer SYMBOLS_PER_WORD=4,
    parameter integer DATA_BYTES_PER_WORD=SYMBOLS_PER_WORD,
    parameter integer COUNT_WIDTH=(SYMBOLS_PER_WORD<=2)?2:$clog2(SYMBOLS_PER_WORD+1)
) (
    input wire clk,
    input wire rst,
    input wire byte_valid,
    output wire byte_ready,
    input wire [7:0] byte_data,
    input wire byte_sop,
    input wire byte_eop,
    output reg word_valid,
    input wire word_ready,
    output reg [SYMBOLS_PER_WORD*8-1:0] word_data,
    output reg [SYMBOLS_PER_WORD-1:0] word_keep,
    output reg word_sop,
    output reg packet_error
);
    reg [COUNT_WIDTH-1:0] byte_count;
    reg frame_open;
    reg first_word;
    localparam integer SOP_CAPACITY=(DATA_BYTES_PER_WORD<SYMBOLS_PER_WORD) ?
        DATA_BYTES_PER_WORD : SYMBOLS_PER_WORD-1;
    wire [COUNT_WIDTH-1:0] capacity = first_word ? SOP_CAPACITY : DATA_BYTES_PER_WORD;
    integer j;

    assign byte_ready=!rst && (!word_valid || word_ready);

    initial begin
        if(SYMBOLS_PER_WORD!=2 && SYMBOLS_PER_WORD!=4)
            $error("SYMBOLS_PER_WORD must be 2 or 4");
        if(DATA_BYTES_PER_WORD<1 || DATA_BYTES_PER_WORD>SYMBOLS_PER_WORD)
            $error("DATA_BYTES_PER_WORD must be between 1 and SYMBOLS_PER_WORD");
    end

    always @(posedge clk) begin
        if(rst) begin
            byte_count<=0;
            frame_open<=0;
            first_word<=1;
            word_valid<=0;
            word_data<=0;
            word_keep<=0;
            word_sop<=0;
            packet_error<=0;
        end else begin
            if(word_valid && word_ready) begin
                word_valid<=0;
                byte_count<=0;
                word_data<=0;
                word_keep<=0;
                word_sop<=0;
            end

            if(byte_valid && byte_ready) begin
                if(byte_sop != !frame_open) begin
                    packet_error<=1;
                    byte_count<=0;
                    frame_open<=0;
                    first_word<=1;
                    word_valid<=0;
                    word_data<=0;
                    word_keep<=0;
                    word_sop<=0;
                end else begin
                    if(byte_count==0)
                        word_sop<=byte_sop;
                    word_data[byte_count*8 +: 8]<=byte_data;
                    for(j=0;j<SYMBOLS_PER_WORD;j=j+1)
                        word_keep[j] <= (j<=byte_count);

                    if(byte_sop)
                        frame_open<=1;
                    if(byte_eop) begin
                        frame_open<=0;
                        first_word<=1;
                    end

                    if((byte_count+1'b1)>=capacity || byte_eop) begin
                        word_valid<=1;
                        byte_count<=0;
                        if(!byte_eop && first_word)
                            first_word<=0;
                    end else begin
                        byte_count<=byte_count+1'b1;
                    end
                end
            end
        end
    end
endmodule
