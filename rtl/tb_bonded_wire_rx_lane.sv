// SPDX-License-Identifier: BSD-2-Clause
// Cross-checks RX against the independently generated Python-codec vector
// already used by tb_bonded_wire_tx_lane.
module tb_bonded_wire_rx_lane;
    reg clk=0; always #5 clk=~clk;
    reg rst=1;
    reg [63:0] expected_session_id=64'h0102030405060708;
    reg in_valid=0, in_sop=0, in_eop=0;
    wire in_ready;
    reg [7:0] in_data=0;
    wire out_valid,out_sop,out_eop;
    reg out_ready=1;
    wire [7:0] out_data;
    wire [31:0] out_packet_sequence,out_frame_sequence,expected_frame_sequence;
    wire frame_error,frame_valid_pulse;
    bonded_wire_rx_lane #(.LANE_ID(1),.MAX_PAYLOAD(4096)) dut (
        .clk(clk),.rst(rst),.expected_session_id(expected_session_id),
        .in_valid(in_valid),.in_ready(in_ready),.in_data(in_data),
        .in_sop(in_sop),.in_eop(in_eop),
        .out_valid(out_valid),.out_ready(out_ready),.out_data(out_data),
        .out_sop(out_sop),.out_eop(out_eop),
        .out_packet_sequence(out_packet_sequence),.out_frame_sequence(out_frame_sequence),
        .expected_frame_sequence(expected_frame_sequence),
        .frame_error(frame_error),.frame_valid_pulse(frame_valid_pulse)
    );
    reg [7:0] frame [0:34];
    integer got=0, i, cycles=0;
    always @(posedge clk) begin
        if(!rst && out_valid && out_ready) begin
            if(got>=3 || out_data !== (got==0 ? 8'haa : got==1 ? 8'hbb : 8'hcc))
                $fatal(1,"payload mismatch idx=%0d data=%02x",got,out_data);
            if(out_sop !== (got==0) || out_eop !== (got==2))
                $fatal(1,"payload boundary mismatch idx=%0d",got);
            got=got+1;
        end
    end
    task send_frame(input integer corrupt_crc);
        begin
            for(i=0;i<35;i=i+1) begin
                @(negedge clk);
                while(!in_ready) @(negedge clk);
                in_valid=1; in_data=frame[i];
                in_sop=(i==0); in_eop=(i==34);
                if(corrupt_crc && i==34) in_data=frame[i]^8'h01;
                @(posedge clk);
            end
            @(negedge clk); in_valid=0; in_sop=0; in_eop=0;
        end
    endtask
    initial begin
        frame[0]=8'h53; frame[1]=8'h42; frame[2]=8'h01; frame[3]=8'h01;
        frame[4]=8'h00; frame[5]=8'h01; frame[6]=8'h00; frame[7]=8'h18;
        frame[8]=8'h01; frame[9]=8'h02; frame[10]=8'h03; frame[11]=8'h04;
        frame[12]=8'h05; frame[13]=8'h06; frame[14]=8'h07; frame[15]=8'h08;
        frame[16]=8'h00; frame[17]=8'h00; frame[18]=8'h00; frame[19]=8'h00;
        frame[20]=8'h00; frame[21]=8'h07; frame[22]=8'h6a; frame[23]=8'h2f;
        frame[24]=8'h11; frame[25]=8'h22; frame[26]=8'h33; frame[27]=8'h44;
        frame[28]=8'haa; frame[29]=8'hbb; frame[30]=8'hcc;
        frame[31]=8'hcc; frame[32]=8'h37; frame[33]=8'hd6; frame[34]=8'h56;
        repeat(3) @(posedge clk);
        @(negedge clk); rst=0;
        send_frame(0);
        cycles=0;
        while(got<3 && cycles<80) begin @(posedge clk); cycles=cycles+1; end
        if(got!=3 || frame_error || out_packet_sequence!=32'h11223344 ||
           out_frame_sequence!=0 || expected_frame_sequence!=1)
            $fatal(1,"valid frame failed got=%0d error=%b",got,frame_error);
        $display("PASS: RX accepts Python golden frame and releases payload");

        @(negedge clk); rst=1;
        repeat(2) @(posedge clk);
        @(negedge clk); rst=0;
        got=0;
        send_frame(1);
        repeat(8) @(posedge clk);
        if(!frame_error || got!=0 || out_valid)
            $fatal(1,"corrupt CRC frame was not rejected");
        $display("PASS: RX rejects corrupted CRC without payload leakage");
        $finish;
    end
endmodule
