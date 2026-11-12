// SPDX-License-Identifier: BSD-2-Clause
`timescale 1ns/1ps
module tb_bonded_crc_parallel;
    reg [31:0] data;
    reg [3:0] keep;
    reg [15:0] crc16_in;
    reg [31:0] crc32c_in;
    wire [15:0] crc16_out;
    wire [31:0] crc32c_out;

    bonded_crc_parallel #(.DATA_BYTES(4)) dut (
        .data(data),.keep(keep),.crc16_in(crc16_in),.crc32c_in(crc32c_in),
        .crc16_out(crc16_out),.crc32c_out(crc32c_out)
    );

    initial begin
        crc16_in=16'hffff;
        crc32c_in=32'hffffffff;

        // "123456789", split over two full words and one partial word.
        data=32'h34333231; keep=4'b1111; #1;
        crc16_in=crc16_out; crc32c_in=crc32c_out;
        data=32'h38373635; keep=4'b1111; #1;
        crc16_in=crc16_out; crc32c_in=crc32c_out;
        data=32'hdeadbe39; keep=4'b0001; #1;

        if(crc16_out!==16'h29b1)
            $fatal(1,"CRC-16 mismatch: got %04x expected 29b1",crc16_out);
        if((~crc32c_out)!==32'he3069283)
            $fatal(1,"CRC-32C mismatch: got %08x expected e3069283",~crc32c_out);

        // Unkept bytes must not affect either CRC state.
        crc16_in=16'hffff; crc32c_in=32'hffffffff;
        data=32'hffffffff; keep=4'b0000; #1;
        if(crc16_out!==crc16_in || crc32c_out!==crc32c_in)
            $fatal(1,"zero KEEP changed CRC state");

        $display("PASS: parallel CRC-16/CCITT-FALSE and CRC-32C, chained partial words");
        $finish;
    end
endmodule
