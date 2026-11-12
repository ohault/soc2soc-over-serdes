// SPDX-License-Identifier: BSD-2-Clause
`timescale 1ns/1ps
module tb_bonded_byte_to_phy_word_rate;
    reg clk=0;always #5 clk=~clk;
    reg rst=1;
    reg v2=0,s2=0,e2=0;reg [7:0] d2=0;wire r2,wv2,ws2;wire [15:0] wd2;wire [1:0] wk2;wire err2;
    reg v4=0,s4=0,e4=0;reg [7:0] d4=0;wire r4,wv4,ws4;wire [31:0] wd4;wire [3:0] wk4;wire err4;

    bonded_byte_to_phy_word #(.SYMBOLS_PER_WORD(2),.DATA_BYTES_PER_WORD(1)) dut2(
        .clk(clk),.rst(rst),.byte_valid(v2),.byte_ready(r2),.byte_data(d2),
        .byte_sop(s2),.byte_eop(e2),.word_valid(wv2),.word_ready(1'b1),
        .word_data(wd2),.word_keep(wk2),.word_sop(ws2),.packet_error(err2));
    bonded_byte_to_phy_word #(.SYMBOLS_PER_WORD(4),.DATA_BYTES_PER_WORD(1)) dut4(
        .clk(clk),.rst(rst),.byte_valid(v4),.byte_ready(r4),.byte_data(d4),
        .byte_sop(s4),.byte_eop(e4),.word_valid(wv4),.word_ready(1'b1),
        .word_data(wd4),.word_keep(wk4),.word_sop(ws4),.packet_error(err4));

    task send2(input [7:0] d,input s,input e);
    begin
        @(negedge clk);d2=d;s2=s;e2=e;v2=1;
        while(!r2) @(negedge clk);
        @(posedge clk);#1;
        if(!wv2 || wd2!=={8'h00,d} || wk2!==2'b01 || ws2!==s)
            $fatal(1,"2-symbol one-byte packing failed d=%02x",d);
        @(negedge clk);v2=0;s2=0;e2=0;
    end endtask

    task send4(input [7:0] d,input s,input e);
    begin
        @(negedge clk);d4=d;s4=s;e4=e;v4=1;
        while(!r4) @(negedge clk);
        @(posedge clk);#1;
        if(!wv4 || wd4!=={24'h0,d} || wk4!==4'b0001 || ws4!==s)
            $fatal(1,"4-symbol one-byte packing failed d=%02x",d);
        @(negedge clk);v4=0;s4=0;e4=0;
    end endtask

    initial begin
        repeat(3) @(posedge clk);@(negedge clk);rst=0;
        send2(8'h53,1,0);send2(8'h42,0,0);send2(8'hbc,0,0);send2(8'h7e,0,1);
        send4(8'h53,1,0);send4(8'h42,0,0);send4(8'hbc,0,0);send4(8'h7e,0,1);
        if(err2 || err4) $fatal(1,"unexpected packer error");
        $display("PASS: safe one-byte-per-word mode for 2- and 4-symbol PHYs");
        $finish;
    end
    initial begin #10000;$fatal(1,"timeout");end
endmodule
