// SPDX-License-Identifier: BSD-2-Clause
// Integration test for two independent recovered clocks feeding one bonding
// clock. Each lane is checked independently to prove isolation and ordering.
module tb_bonded_two_lane_cdc;
    localparam integer WIDTH = 32;
    localparam integer COUNT = 180;

    reg clk0 = 0, clk1 = 0, bond_clk = 0;
    always #5 clk0 = ~clk0;
    always #7 clk1 = ~clk1;
    always #4 bond_clk = ~bond_clk;

    reg bond_rst_n = 0, lane0_rst_n = 0, lane1_rst_n = 0;
    reg v0 = 0, v1 = 0;
    wire r0, r1;
    reg [WIDTH-1:0] d0 = 0, d1 = 0;
    wire ov0, ov1;
    reg or0 = 0, or1 = 0;
    wire [WIDTH-1:0] od0, od1;

    bonded_two_lane_cdc #(.DATA_WIDTH(WIDTH), .FIFO_DEPTH(16)) dut (
        .bond_rst_n(bond_rst_n),
        .lane0_clk(clk0), .lane0_rst_n(lane0_rst_n),
        .lane0_valid(v0), .lane0_ready(r0), .lane0_data(d0),
        .lane1_clk(clk1), .lane1_rst_n(lane1_rst_n),
        .lane1_valid(v1), .lane1_ready(r1), .lane1_data(d1),
        .bond_clk(bond_clk),
        .bond_lane0_valid(ov0), .bond_lane0_ready(or0), .bond_lane0_data(od0),
        .bond_lane1_valid(ov1), .bond_lane1_ready(or1), .bond_lane1_data(od1)
    );

    reg [WIDTH-1:0] exp0 [0:COUNT-1];
    reg [WIDTH-1:0] exp1 [0:COUNT-1];
    integer sent0=0, sent1=0, got0=0, got1=0, cycles=0;
    reg [31:0] lfsr0=32'h1234567, lfsr1=32'h7654321, lfsrb=32'hdeadbeef;

    always @(posedge clk0) begin
        if (!lane0_rst_n || !bond_rst_n) begin
            v0 <= 0;
            d0 <= 0;
        end else if (!v0 || r0) begin
            if (sent0 < COUNT) begin
                v0 <= 1;
                d0 <= 32'h10000000 + sent0;
            end else v0 <= 0;
            if (v0 && r0) begin
                exp0[sent0] = d0;
                sent0 = sent0 + 1;
            end
        end
    end

    always @(posedge clk1) begin
        if (!lane1_rst_n || !bond_rst_n) begin
            v1 <= 0;
            d1 <= 0;
        end else if (!v1 || r1) begin
            if (sent1 < COUNT) begin
                v1 <= 1;
                d1 <= 32'h20000000 + sent1;
            end else v1 <= 0;
            if (v1 && r1) begin
                exp1[sent1] = d1;
                sent1 = sent1 + 1;
            end
        end
    end

    always @(posedge bond_clk) begin
        if (!bond_rst_n) begin
            or0 <= 0;
            or1 <= 0;
        end else begin
            lfsrb <= {lfsrb[30:0],lfsrb[31]^lfsrb[21]^lfsrb[1]^lfsrb[0]};
            or0 <= lfsrb[1:0] != 0;
            or1 <= lfsrb[3:2] != 0;
            if (ov0 && or0) begin
                if (got0 >= COUNT || od0 !== exp0[got0]) begin
                    $display("lane0 mismatch at %0d data=%h",got0,od0);
                    $fatal(1);
                end
                got0 = got0 + 1;
            end
            if (ov1 && or1) begin
                if (got1 >= COUNT || od1 !== exp1[got1]) begin
                    $display("lane1 mismatch at %0d data=%h",got1,od1);
                    $fatal(1);
                end
                got1 = got1 + 1;
            end
        end
    end

    initial begin
        #50;
        @(negedge bond_clk);
        bond_rst_n=1; lane0_rst_n=1; lane1_rst_n=1;
        while ((got0 < COUNT || got1 < COUNT) && cycles < 20000) begin
            @(posedge bond_clk);
            cycles=cycles+1;
        end
        if (got0 != COUNT || got1 != COUNT) begin
            $display("timeout sent=%0d/%0d got=%0d/%0d",sent0,sent1,got0,got1);
            $fatal(1);
        end
        $display("PASS: two recovered-clock lanes crossed into common bonding clock");
        $finish;
    end
endmodule
