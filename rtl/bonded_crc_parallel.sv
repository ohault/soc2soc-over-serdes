// SPDX-License-Identifier: BSD-2-Clause
// Combinational multi-byte CRC update for the v0 wire format.
// Byte 0 is data[7:0]; only keep-marked bytes participate, in ascending order.
// CRC state conventions match bonded_wire_tx_lane: CRC-16/CCITT-FALSE starts
// at 0xffff; CRC-32C starts at 0xffffffff and is complemented by the caller.
module bonded_crc_parallel #(
    parameter integer DATA_BYTES = 4
) (
    input wire [DATA_BYTES*8-1:0] data,
    input wire [DATA_BYTES-1:0] keep,
    input wire [15:0] crc16_in,
    input wire [31:0] crc32c_in,
    output reg [15:0] crc16_out,
    output reg [31:0] crc32c_out
);
    function [15:0] crc16_byte(input [15:0] crc_in,input [7:0] value);
        integer k;
        reg [15:0] c;
        begin
            c=crc_in ^ {value,8'h00};
            for(k=0;k<8;k=k+1)
                c=c[15] ? ((c<<1)^16'h1021) : (c<<1);
            crc16_byte=c;
        end
    endfunction

    function [31:0] crc32c_byte(input [31:0] crc_in,input [7:0] value);
        integer k;
        reg [31:0] c;
        begin
            c=crc_in ^ value;
            for(k=0;k<8;k=k+1)
                c=c[0] ? ((c>>1)^32'h82f63b78) : (c>>1);
            crc32c_byte=c;
        end
    endfunction

    integer i;
    always @* begin
        crc16_out=crc16_in;
        crc32c_out=crc32c_in;
        for(i=0;i<DATA_BYTES;i=i+1) begin
            if(keep[i]) begin
                crc16_out=crc16_byte(crc16_out,data[i*8 +: 8]);
                crc32c_out=crc32c_byte(crc32c_out,data[i*8 +: 8]);
            end
        end
    end

    initial begin
        if(DATA_BYTES<1)
            $error("DATA_BYTES must be positive");
    end
endmodule
