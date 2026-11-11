// SPDX-License-Identifier: BSD-2-Clause
module tb_bonded_packet_rx;
    reg clk=0; always #5 clk=~clk;
    reg rst=1;
    reg [1:0] lane_valid=0;
    wire [1:0] lane_ready;
    reg [15:0] lane_data=0;
    reg [1:0] lane_sop=0,lane_eop=0;
    reg [63:0] lane_packet_sequence=0;
    wire out_valid;
    reg out_ready=1;
    wire [7:0] out_data;
    wire out_sop,out_eop;
    wire [31:0] out_packet_sequence,expected_packet_sequence;
    wire packet_error;
    bonded_packet_rx #(.LANE_COUNT(2),.WINDOW_SIZE(4),.MAX_PACKET_BYTES(16)) dut(
        .clk(clk),.rst(rst),.lane_valid(lane_valid),.lane_ready(lane_ready),
        .lane_data(lane_data),.lane_sop(lane_sop),.lane_eop(lane_eop),
        .lane_packet_sequence(lane_packet_sequence),
        .out_valid(out_valid),.out_ready(out_ready),.out_data(out_data),
        .out_sop(out_sop),.out_eop(out_eop),.out_packet_sequence(out_packet_sequence),
        .expected_packet_sequence(expected_packet_sequence),.packet_error(packet_error)
    );
    integer got=0, cycles=0;
    always @(posedge clk) begin
        if(!rst && out_valid && out_ready) begin
            if(out_packet_sequence !== (got<2 ? 32'd0 : 32'd1))
                $fatal(1,"sequence order mismatch at output byte %0d: %0d",got,out_packet_sequence);
            if(got==0 && (!out_sop || out_data!==8'h10))
                $fatal(1,"packet 0 first byte mismatch");
            if(got==1 && (!out_eop || out_data!==8'h11))
                $fatal(1,"packet 0 second byte mismatch");
            if(got==2 && (!out_sop || out_data!==8'h20))
                $fatal(1,"packet 1 first byte mismatch");
            if(got==3 && (!out_eop || out_data!==8'h21))
                $fatal(1,"packet 1 second byte mismatch");
            got=got+1;
        end
    end
    task send_byte(input integer lane,input [31:0] seq,input [7:0] data,
                   input integer sop,input integer eop);
        begin
            @(negedge clk);
            lane_valid[lane]=1;
            lane_data[lane*8 +: 8]=data;
            lane_packet_sequence[lane*32 +: 32]=seq;
            lane_sop[lane]=sop; lane_eop[lane]=eop;
            do @(posedge clk); while(!lane_ready[lane]);
            @(negedge clk);
            lane_valid[lane]=0; lane_sop[lane]=0; lane_eop[lane]=0;
        end
    endtask
    initial begin
        repeat(3) @(posedge clk);
        @(negedge clk); rst=0;
        // Deliberately deliver packet 1 before packet 0.
        send_byte(1,1,8'h20,1,0);
        send_byte(1,1,8'h21,0,1);
        repeat(3) @(posedge clk);
        if(out_valid) $fatal(1,"later packet escaped before sequence 0");
        send_byte(0,0,8'h10,1,0);
        send_byte(0,0,8'h11,0,1);
        cycles=0;
        while(got<4 && cycles<100) begin @(posedge clk); cycles=cycles+1; end
        @(posedge clk); // allow nonblocking expected-sequence update after final EOP
        $display("FINAL got=%0d error=%b expected=%0d active=%b drop=%b fill=%b valid=%b count0=%0d count1=%0d",got,packet_error,expected_packet_sequence,dut.lane_active,dut.lane_drop,dut.slot_filling,dut.slot_valid,dut.lane_count[0],dut.lane_count[1]);
        if(got!=4 || packet_error || expected_packet_sequence!=2)
            $fatal(1,"reorder test failed got=%0d error=%b expected=%0d",
                   got,packet_error,expected_packet_sequence);
        $display("PASS: packets arriving out of order are delivered in sequence order");
        $finish;
    end
endmodule
