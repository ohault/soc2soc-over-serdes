`timescale 1ns/1ps

module tb_bonded_payload_word_ram #(
    parameter integer DATA_WIDTH = 32
);
    localparam integer KEEP_WIDTH = DATA_WIDTH / 8;
    localparam integer MAX_PAYLOAD = 19;
    localparam integer WORD_COUNT = (MAX_PAYLOAD + KEEP_WIDTH - 1) / KEEP_WIDTH;
    localparam integer ADDR_WIDTH = (WORD_COUNT <= 1) ? 1 : $clog2(WORD_COUNT);

    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg rst = 1'b1;
    reg wr_en = 1'b0;
    reg [ADDR_WIDTH-1:0] wr_addr = {ADDR_WIDTH{1'b0}};
    reg [DATA_WIDTH-1:0] wr_data = {DATA_WIDTH{1'b0}};
    reg [KEEP_WIDTH-1:0] wr_keep = {KEEP_WIDTH{1'b0}};
    reg rd_en = 1'b0;
    reg [ADDR_WIDTH-1:0] rd_addr = {ADDR_WIDTH{1'b0}};
    wire [DATA_WIDTH-1:0] rd_data;
    wire rd_valid;

    reg [DATA_WIDTH-1:0] expected0;
    reg [DATA_WIDTH-1:0] expected1;
    reg [DATA_WIDTH-1:0] partial_expected;
    integer i;

    bonded_payload_word_ram #(
        .DATA_WIDTH(DATA_WIDTH),
        .MAX_PAYLOAD(MAX_PAYLOAD)
    ) dut (
        .clk(clk), .rst(rst),
        .wr_en(wr_en), .wr_addr(wr_addr), .wr_data(wr_data), .wr_keep(wr_keep),
        .rd_en(rd_en), .rd_addr(rd_addr), .rd_data(rd_data), .rd_valid(rd_valid)
    );

    task tick;
        begin
            @(posedge clk);
            #1;
        end
    endtask

    task write_word;
        input [ADDR_WIDTH-1:0] address;
        input [DATA_WIDTH-1:0] data;
        input [KEEP_WIDTH-1:0] keep;
        begin
            @(negedge clk);
            wr_en = 1'b1;
            wr_addr = address;
            wr_data = data;
            wr_keep = keep;
            tick();
            @(negedge clk);
            wr_en = 1'b0;
            wr_keep = {KEEP_WIDTH{1'b0}};
        end
    endtask

    task read_word;
        input [ADDR_WIDTH-1:0] address;
        input [DATA_WIDTH-1:0] expected;
        begin
            @(negedge clk);
            rd_en = 1'b1;
            rd_addr = address;
            tick();
            if (!rd_valid)
                $fatal(1, "DATA_WIDTH=%0d read response was not valid", DATA_WIDTH);
            if (rd_data !== expected)
                $fatal(1, "DATA_WIDTH=%0d address=%0d got=%h expected=%h",
                       DATA_WIDTH, address, rd_data, expected);
            @(negedge clk);
            rd_en = 1'b0;
            tick();
            if (rd_valid)
                $fatal(1, "DATA_WIDTH=%0d rd_valid did not clear", DATA_WIDTH);
        end
    endtask

    initial begin
        expected0 = {DATA_WIDTH{1'b0}};
        expected1 = {DATA_WIDTH{1'b0}};
        partial_expected = {DATA_WIDTH{1'b0}};
        for (i = 0; i < KEEP_WIDTH; i = i + 1) begin
            expected0[i*8 +: 8] = 8'h20 + i;
            expected1[i*8 +: 8] = 8'h80 + i;
            partial_expected[i*8 +: 8] = 8'h20 + i;
        end

        tick();
        @(negedge clk);
        rst = 1'b0;

        write_word(0, expected0, {KEEP_WIDTH{1'b1}});
        write_word(1, expected1, {KEEP_WIDTH{1'b1}});
        read_word(0, expected0);
        read_word(1, expected1);

        // Update only the highest byte lane; all other bytes must be preserved.
        partial_expected[(KEEP_WIDTH-1)*8 +: 8] = 8'hD7;
        write_word(0, {DATA_WIDTH{1'b1}}, ({{(KEEP_WIDTH-1){1'b0}},1'b1} << (KEEP_WIDTH-1)));
        read_word(0, partial_expected);

        // Reset clears response validity but deliberately preserves RAM contents.
        @(negedge clk);
        rst = 1'b1;
        tick();
        if (rd_valid)
            $fatal(1, "DATA_WIDTH=%0d reset did not clear rd_valid", DATA_WIDTH);
        @(negedge clk);
        rst = 1'b0;
        read_word(0, partial_expected);

        $display("PASS bonded_payload_word_ram DATA_WIDTH=%0d WORD_COUNT=%0d",
                 DATA_WIDTH, WORD_COUNT);
        $finish;
    end
endmodule
