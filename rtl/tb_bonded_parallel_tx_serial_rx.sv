// SPDX-License-Identifier: BSD-2-Clause
`timescale 1ns/1ps
module tb_bonded_parallel_tx_serial_rx;
    reg clk=0; always #5 clk=~clk;
    reg rst=1;
    reg tx_in_valid=0,tx_in_sop=0,tx_in_eop=0;
    wire tx_in_ready;
    reg [31:0] tx_in_data=32'h00ccbbaa;
    reg [3:0] tx_in_keep=4'b0111;
    reg [31:0] tx_packet_sequence=32'h11223344;
    reg [15:0] tx_packet_length=3;
    wire tx_out_valid,tx_out_ready,tx_out_sop,tx_out_eop;
    wire [31:0] tx_out_data;
    wire [3:0] tx_out_keep;
    wire tx_error;

    reg word_valid=0,word_sop=0,word_eop=0;
    reg [31:0] word_data=0;
    reg [3:0] word_keep=0;
    reg [2:0] byte_index=0;
    wire byte_valid,byte_ready,byte_sop,byte_eop;
    wire [7:0] byte_data;
    wire [31:0] rx_packet_sequence,rx_frame_sequence,next_rx_sequence;
    wire [7:0] rx_lane_id;
    wire rx_error,rx_frame_valid;
    wire rx_out_valid,rx_out_sop,rx_out_eop;
    wire [7:0] rx_out_data;
    reg rx_out_ready=1;
    integer got=0,cycles=0;
    wire [31:0] valid_count;

    function integer keep_count(input [3:0] k);
        integer q; begin keep_count=0; for(q=0;q<4;q=q+1) keep_count=keep_count+k[q]; end
    endfunction

    bonded_wire_tx_lane_parallel #(.DATA_WIDTH(32),.LANE_ID(1)) tx (
        .clk(clk),.rst(rst),.session_id(64'h0102030405060708),
        .frame_start_enable(1'b1),.frame_sequence(32'd0),
        .in_valid(tx_in_valid),.in_ready(tx_in_ready),.in_data(tx_in_data),
        .in_keep(tx_in_keep),.in_sop(tx_in_sop),.in_eop(tx_in_eop),
        .in_packet_sequence(tx_packet_sequence),.in_packet_length(tx_packet_length),
        .out_valid(tx_out_valid),.out_ready(tx_out_ready),.out_data(tx_out_data),
        .out_keep(tx_out_keep),.out_sop(tx_out_sop),.out_eop(tx_out_eop),
        .frame_error(tx_error)
    );
    assign tx_out_ready=!word_valid;
    assign valid_count=keep_count(word_keep);
    assign byte_valid=word_valid && byte_index<valid_count;
    assign byte_data=word_data[byte_index*8 +: 8];
    assign byte_sop=word_sop && byte_index==0;
    assign byte_eop=word_eop && byte_index+1'b1==valid_count;

    bonded_wire_rx_lane #(.LANE_ID(1)) rx (
        .clk(clk),.rst(rst),.expected_session_id(64'h0102030405060708),
        .expected_frame_sequence_override(32'd0),.expected_lane_id(8'd1),
        .in_valid(byte_valid),.in_ready(byte_ready),.in_data(byte_data),
        .in_sop(byte_sop),.in_eop(byte_eop),
        .out_valid(rx_out_valid),.out_ready(rx_out_ready),.out_data(rx_out_data),
        .out_sop(rx_out_sop),.out_eop(rx_out_eop),
        .out_packet_sequence(rx_packet_sequence),.out_frame_sequence(rx_frame_sequence),
        .out_lane_id(rx_lane_id),.expected_frame_sequence(next_rx_sequence),
        .frame_error(rx_error),.frame_valid_pulse(rx_frame_valid)
    );

    always @(posedge clk) begin
        if(rst) begin word_valid<=0; byte_index<=0; end
        else begin
            if(tx_out_valid && tx_out_ready) begin
                word_valid<=1; word_data<=tx_out_data; word_keep<=tx_out_keep;
                word_sop<=tx_out_sop; word_eop<=tx_out_eop; byte_index<=0;
            end
            if(byte_valid && byte_ready) begin
                if(byte_index+1'b1>=valid_count) begin word_valid<=0; byte_index<=0; end
                else byte_index<=byte_index+1'b1;
            end
        end
    end

    always @(posedge clk) begin
        if(!rst && rx_out_valid && rx_out_ready) begin
            case(got)
                0: if(rx_out_data!==8'haa) $fatal(1,"payload byte 0 mismatch");
                1: if(rx_out_data!==8'hbb) $fatal(1,"payload byte 1 mismatch");
                2: if(rx_out_data!==8'hcc) $fatal(1,"payload byte 2 mismatch");
                default: $fatal(1,"unexpected extra payload");
            endcase
            if(got==0 && !rx_out_sop) $fatal(1,"missing payload SOP");
            if(got==2 && !rx_out_eop) $fatal(1,"missing payload EOP");
            got=got+1;
        end
        if(!rst) cycles<=cycles+1;
    end

    initial begin
        repeat(4) @(posedge clk); @(negedge clk); rst=0;
        @(negedge clk); tx_in_valid=1; tx_in_sop=1; tx_in_eop=1;
        while(!tx_in_ready) @(negedge clk);
        @(posedge clk); @(negedge clk); tx_in_valid=0; tx_in_sop=0; tx_in_eop=0;
        while(got<3 && cycles<3000) @(posedge clk);
        repeat(3) @(posedge clk);
        if(got!=3 || tx_error || rx_error || rx_packet_sequence!=32'h11223344 ||
           rx_frame_sequence!=0 || rx_lane_id!=1 || next_rx_sequence!=1)
            $fatal(1,"parallel TX -> serial RX failed got=%0d txerr=%b rxerr=%b",got,tx_error,rx_error);
        $display("PASS: parallel-word TX -> byte-serial RX");
        $finish;
    end
endmodule
