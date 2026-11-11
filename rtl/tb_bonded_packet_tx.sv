// SPDX-License-Identifier: BSD-2-Clause
// Exercises the packet scheduler using two lanes, mixed packet lengths and packet buffer boundaries.
module tb_bonded_packet_tx;
    localparam integer W=32, K=4, LANES=2;
    reg clk=0;
    always #5 clk=~clk;
    reg rst=1, tx_valid=0, tx_sop=0, tx_eop=0;
    wire tx_ready;
    reg [W-1:0] tx_data=0;
    reg [K-1:0] tx_keep=4'hf;
    wire [LANES-1:0] lane_valid, lane_sop, lane_eop;
    reg [LANES-1:0] lane_ready=2'b11;
    wire [LANES*W-1:0] lane_data;
    wire [LANES*K-1:0] lane_keep;
    wire [LANES*32-1:0] lane_packet_sequence;
    wire packet_error;

    bonded_packet_tx #(.DATA_WIDTH(W),.LANE_COUNT(LANES),.MAX_PACKET_BYTES(64)) dut (
        .clk(clk),.rst(rst),
        .tx_valid(tx_valid),.tx_ready(tx_ready),.tx_data(tx_data),
        .tx_keep(tx_keep),.tx_sop(tx_sop),.tx_eop(tx_eop),
        .lane_valid(lane_valid),.lane_ready(lane_ready),
        .lane_data(lane_data),.lane_keep(lane_keep),
        .lane_sop(lane_sop),.lane_eop(lane_eop),
        .lane_packet_sequence(lane_packet_sequence),.packet_error(packet_error)
    );

    integer got=0, cycles=0;
    reg [31:0] exp_data[0:8];
    reg [0:8] exp_lane, exp_sop, exp_eop;
    reg [31:0] exp_seq[0:8];

    always @(posedge clk) begin
        if (!rst) begin
            if (lane_valid[0] && lane_ready[0]) begin
                if (lane_data[0 +: W] !== exp_data[got] ||
                    lane_sop[0] !== exp_sop[got] || lane_eop[0] !== exp_eop[got] ||
                    lane_packet_sequence[0 +: 32] !== exp_seq[got] || exp_lane[got] != 0) begin
                    $display("lane0 mismatch beat=%0d data=%h",got,lane_data[0 +: W]); $fatal(1);
                end
                got=got+1;
            end
            if (lane_valid[1] && lane_ready[1]) begin
                if (lane_data[W +: W] !== exp_data[got] ||
                    lane_sop[1] !== exp_sop[got] || lane_eop[1] !== exp_eop[got] ||
                    lane_packet_sequence[32 +: 32] !== exp_seq[got] || exp_lane[got] != 1) begin
                    $display("lane1 mismatch beat=%0d data=%h",got,lane_data[W +: W]); $fatal(1);
                end
                got=got+1;
            end
        end
    end

    task send_beat(input [31:0] d,input s,input e,input [3:0] keep);
    begin
        @(negedge clk);
        tx_valid=1; tx_data=d; tx_sop=s; tx_eop=e; tx_keep=keep;
        while (!tx_ready) @(negedge clk);
        @(posedge clk);
        @(negedge clk);
        tx_valid=0; tx_sop=0; tx_eop=0;
    end
    endtask

    initial begin
        exp_data[0]=32'h11; exp_data[1]=32'h12; exp_data[2]=32'h13;
        exp_data[3]=32'h21; exp_data[4]=32'h22;
        exp_data[5]=32'h31; exp_data[6]=32'h32; exp_data[7]=32'h33; exp_data[8]=32'h34;
        exp_lane[0]=0;exp_lane[1]=0;exp_lane[2]=0;exp_lane[3]=1;exp_lane[4]=1;
        exp_lane[5]=0;exp_lane[6]=0;exp_lane[7]=0;exp_lane[8]=0;
        exp_sop[0]=1;exp_sop[1]=0;exp_sop[2]=0;exp_sop[3]=1;exp_sop[4]=0;
        exp_sop[5]=1;exp_sop[6]=0;exp_sop[7]=0;exp_sop[8]=0;
        exp_eop[0]=0;exp_eop[1]=0;exp_eop[2]=1;exp_eop[3]=0;exp_eop[4]=1;
        exp_eop[5]=0;exp_eop[6]=0;exp_eop[7]=0;exp_eop[8]=1;
        exp_seq[0]=0;exp_seq[1]=0;exp_seq[2]=0;exp_seq[3]=1;exp_seq[4]=1;
        exp_seq[5]=2;exp_seq[6]=2;exp_seq[7]=2;exp_seq[8]=2;
        repeat(3) @(posedge clk);
        @(negedge clk); rst=0;
        send_beat(32'h11,1,0,4'hf);
        send_beat(32'h12,0,0,4'hf);
        send_beat(32'h13,0,1,4'hf);
        wait(got==3);
        send_beat(32'h21,1,0,4'hf);
        send_beat(32'h22,0,1,4'h3);
        wait(got==5);
        send_beat(32'h31,1,0,4'hf);
        send_beat(32'h32,0,0,4'hf);
        send_beat(32'h33,0,0,4'hf);
        send_beat(32'h34,0,1,4'hf);
        cycles=0;
        while(got<9 && cycles<100) begin @(posedge clk); cycles=cycles+1; end
        if(got!=9 || packet_error) begin $display("FAIL got=%0d error=%b",got,packet_error); $fatal(1); end
        $display("PASS: complete packets distributed round-robin across two lanes");
        $finish;
    end
endmodule
