// SPDX-License-Identifier: BSD-2-Clause
`timescale 1ns/1ps
module tb_bonded_crc_parallel;
    localparam integer DATA_BYTES=8;
    reg [DATA_BYTES*8-1:0] data;
    reg [DATA_BYTES-1:0] keep;
    reg [15:0] crc16_in;
    reg [31:0] crc32c_in;
    wire [15:0] crc16_out;
    wire [31:0] crc32c_out;
    reg [15:0] ref16;
    reg [31:0] ref32;
    integer i,j;

    bonded_crc_parallel #(.DATA_BYTES(DATA_BYTES)) dut (
        .data(data),.keep(keep),.crc16_in(crc16_in),.crc32c_in(crc32c_in),
        .crc16_out(crc16_out),.crc32c_out(crc32c_out)
    );

    function [15:0] ref_crc16_byte(input [15:0] ci,input [7:0] value);
        integer k; reg [15:0] c;
        begin
            c=ci^{value,8'h00};
            for(k=0;k<8;k=k+1)c=c[15]?((c<<1)^16'h1021):(c<<1);
            ref_crc16_byte=c;
        end
    endfunction

    function [31:0] ref_crc32_byte(input [31:0] ci,input [7:0] value);
        integer k; reg [31:0] c;
        begin
            c=ci^value;
            for(k=0;k<8;k=k+1)c=c[0]?((c>>1)^32'h82f63b78):(c>>1);
            ref_crc32_byte=c;
        end
    endfunction

    task check_reference;
        begin
            ref16=crc16_in;
            ref32=crc32c_in;
            for(j=0;j<DATA_BYTES;j=j+1) begin
                if(keep[j]) begin
                    ref16=ref_crc16_byte(ref16,data[j*8 +: 8]);
                    ref32=ref_crc32_byte(ref32,data[j*8 +: 8]);
                end
            end
            #1;
            if(crc16_out!==ref16 || crc32c_out!==ref32)
                $fatal(1,"parallel CRC mismatch keep=%h data=%h got=%h/%h expected=%h/%h",
                       keep,data,crc16_out,crc32c_out,ref16,ref32);
        end
    endtask

    initial begin
        // Standard "123456789" check values, chained over an 8-byte and 1-byte word.
        crc16_in=16'hffff; crc32c_in=32'hffffffff;
        data=64'h3837363534333231; keep=8'hff; check_reference();
        crc16_in=crc16_out; crc32c_in=crc32c_out;
        data=64'hdeadbeefcafeba39; keep=8'h01; check_reference();
        if(crc16_out!==16'h29b1)
            $fatal(1,"CRC-16 check vector mismatch: got %04x expected 29b1",crc16_out);
        if((~crc32c_out)!==32'he3069283)
            $fatal(1,"CRC-32C check vector mismatch: got %08x expected e3069283",~crc32c_out);

        // Empty and sparse masks, arbitrary initial states, and randomized data.
        for(i=0;i<500;i=i+1) begin
            data={$random,$random};
            keep=$random;
            crc16_in=$random;
            crc32c_in={$random};
            check_reference();
        end

        $display("PASS: 8-byte parallel CRC, standard vectors and 500 randomized masks");
        $finish;
    end
endmodule
