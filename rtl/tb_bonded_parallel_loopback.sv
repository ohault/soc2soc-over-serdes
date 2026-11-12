// SPDX-License-Identifier: BSD-2-Clause
`timescale 1ns/1ps
module tb_bonded_parallel_loopback;
    reg clk=0; always #5 clk=~clk;
    reg rst=1;
    reg in_valid=0,in_sop=0,in_eop=0;
    wire in_ready;
    reg [31:0] in_data=32'h00ccbbaa;
    reg [3:0] in_keep=4'b0111;
    reg [31:0] packet_sequence=32'h11223344;
    reg [15:0] packet_length=3;
    wire tx_valid,tx_ready,tx_sop,tx_eop;
    wire [31:0] tx_data;
    wire [3:0] tx_keep;
    wire tx_error;
    wire rx_valid,rx_sop,rx_eop;
    wire [31:0] rx_data;
    wire [3:0] rx_keep;
    wire [31:0] rx_packet_sequence,rx_frame_sequence,next_rx_sequence;
    wire [7:0] rx_lane_id;
    wire rx_error,rx_frame_valid;
    integer got=0,cycles=0,i;

    bonded_wire_tx_lane_parallel #(.DATA_WIDTH(32),.LANE_ID(1)) tx (
        .clk(clk),.rst(rst),.session_id(64'h0102030405060708),
        .frame_start_enable(1'b1),.frame_sequence(32'd0),
        .in_valid(in_valid),.in_ready(in_ready),.in_data(in_data),.in_keep(in_keep),
        .in_sop(in_sop),.in_eop(in_eop),.in_packet_sequence(packet_sequence),
        .in_packet_length(packet_length),.out_valid(tx_valid),.out_ready(tx_ready),
        .out_data(tx_data),.out_keep(tx_keep),.out_sop(tx_sop),.out_eop(tx_eop),
        .frame_error(tx_error)
    );
    bonded_wire_rx_lane_parallel #(.DATA_WIDTH(32),.LANE_ID(1)) rx (
        .clk(clk),.rst(rst),.expected_session_id(64'h0102030405060708),
        .expected_frame_sequence_override(32'd0),.expected_lane_id(8'd1),
        .in_valid(tx_valid),.in_ready(tx_ready),.in_data(tx_data),.in_keep(tx_keep),
        .in_sop(tx_sop),.in_eop(tx_eop),.out_valid(rx_valid),.out_ready(1'b1),
        .out_data(rx_data),.out_keep(rx_keep),.out_sop(rx_sop),.out_eop(rx_eop),
        .out_packet_sequence(rx_packet_sequence),.out_frame_sequence(rx_frame_sequence),
        .out_lane_id(rx_lane_id),.expected_frame_sequence(next_rx_sequence),
        .frame_error(rx_error),.frame_valid_pulse(rx_frame_valid)
    );

    always @(posedge clk) begin
        if(!rst && rx_valid) begin
            if(rx_sop && got!=0) $fatal(1,"unexpected second SOP");
            for(i=0;i<4;i=i+1) if(rx_keep[i]) begin
                case(got)
                    0: if(rx_data[i*8 +: 8]!==8'haa) $fatal(1,"payload byte 0 mismatch");
                    1: if(rx_data[i*8 +: 8]!==8'hbb) $fatal(1,"payload byte 1 mismatch");
                    2: if(rx_data[i*8 +: 8]!==8'hcc) $fatal(1,"payload byte 2 mismatch");
                    default: $fatal(1,"unexpected extra payload");
                endcase
                got=got+1;
            end
            if(got==3 && !rx_eop) $fatal(1,"missing payload EOP");
        end
        if(!rst) cycles<=cycles+1;
    end

    initial begin
        repeat(4) @(posedge clk); @(negedge clk); rst=0;
        @(negedge clk); in_valid=1; in_sop=1; in_eop=1;
        while(!in_ready) @(negedge clk);
        @(posedge clk); @(negedge clk); in_valid=0; in_sop=0; in_eop=0;
        while(got<3 && cycles<3000) @(posedge clk);
        repeat(3) @(posedge clk);
        if(got!=3 || tx_error || rx_error || rx_packet_sequence!=32'h11223344 ||
           rx_frame_sequence!=0 || rx_lane_id!=1 || next_rx_sequence!=1)
            $fatal(1,"parallel loopback failed got=%0d txerr=%b rxerr=%b",got,tx_error,rx_error);
        $display("PASS: parallel-word TX -> parallel-word RX");
        $finish;
    end
endmodule
