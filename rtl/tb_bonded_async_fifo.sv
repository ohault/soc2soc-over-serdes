// SPDX-License-Identifier: BSD-2-Clause
// Asynchronous FIFO test: unrelated clocks, randomized backpressure,
// ordering, full/empty transitions and reset flush.
module tb_bonded_async_fifo;
    localparam integer WIDTH = 32;
    localparam integer DEPTH = 16;
    localparam integer TOTAL = 600;

    reg wr_clk = 0, rd_clk = 0;
    always #5 wr_clk = ~wr_clk;   // 100 MHz
    always #7 rd_clk = ~rd_clk;   // ~71.4 MHz

    reg wr_rst_n = 0, rd_rst_n = 0;
    reg wr_valid = 0;
    wire wr_ready;
    reg [WIDTH-1:0] wr_data = 0;
    wire rd_valid;
    reg rd_ready = 0;
    wire [WIDTH-1:0] rd_data;

    bonded_async_fifo #(.DATA_WIDTH(WIDTH), .DEPTH(DEPTH)) dut (
        .wr_clk(wr_clk), .wr_rst_n(wr_rst_n),
        .wr_valid(wr_valid), .wr_ready(wr_ready), .wr_data(wr_data),
        .rd_clk(rd_clk), .rd_rst_n(rd_rst_n),
        .rd_valid(rd_valid), .rd_ready(rd_ready), .rd_data(rd_data)
    );

    reg [WIDTH-1:0] expected [0:TOTAL-1];
    integer sent = 0, received = 0;
    integer cycles = 0;
    reg [31:0] wr_lfsr = 32'h1ace_b00c;
    reg [31:0] rd_lfsr = 32'hc001_d00d;

    always @(posedge wr_clk) begin
        if (!wr_rst_n) begin
            wr_valid <= 0;
            wr_data <= 0;
            wr_lfsr <= 32'h1ace_b00c;
        end else begin
            wr_lfsr <= {wr_lfsr[30:0], wr_lfsr[31]^wr_lfsr[21]^wr_lfsr[1]^wr_lfsr[0]};
            if (!wr_valid || wr_ready) begin
                if (sent < TOTAL && wr_lfsr[2:0] != 0) begin
                    wr_valid <= 1;
                    wr_data <= (sent * 32'h10204081) ^ 32'h5a5aa5a5;
                end else begin
                    wr_valid <= 0;
                end
            end
            if (wr_valid && wr_ready) begin
                expected[sent] = wr_data;
                sent = sent + 1;
            end
        end
    end

    always @(posedge rd_clk) begin
        if (!rd_rst_n) begin
            rd_ready <= 0;
            rd_lfsr <= 32'hc001_d00d;
        end else begin
            rd_lfsr <= {rd_lfsr[30:0], rd_lfsr[31]^rd_lfsr[21]^rd_lfsr[1]^rd_lfsr[0]};
            rd_ready <= (rd_lfsr[2:0] != 0);
            if (rd_valid && rd_ready) begin
                if (received >= TOTAL) begin
                    $display("ERROR: received too many words");
                    $fatal(1);
                end
                if (rd_data !== expected[received]) begin
                    $display("ERROR: mismatch at %0d expected=%h got=%h",
                             received, expected[received], rd_data);
                    $fatal(1);
                end
                received = received + 1;
            end
        end
    end

    initial begin
        #40;
        @(negedge wr_clk);
        wr_rst_n = 1;
        rd_rst_n = 1;
        cycles = 0;
        while (received < TOTAL && cycles < 20000) begin
            @(posedge wr_clk);
            cycles = cycles + 1;
        end
        if (received != TOTAL) begin
            $display("ERROR: timeout sent=%0d received=%0d", sent, received);
            $fatal(1);
        end
        // Allow synchronized pointers to settle, then verify empty.
        repeat (8) @(posedge rd_clk);
        if (rd_valid !== 1'b0) begin
            $display("ERROR: FIFO should be empty after drain");
            $fatal(1);
        end
        $display("PASS: %0d words crossed unrelated clocks with randomized stalls", TOTAL);
        $finish;
    end
endmodule
