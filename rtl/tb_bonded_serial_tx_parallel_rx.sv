// SPDX-License-Identifier: BSD-2-Clause
`timescale 1ns/1ps
module tb_bonded_serial_tx_parallel_rx;
    reg clk=0; always #5 clk=~clk;
    reg rst=1;
    reg tx_in_valid=0,tx_in_sop=0,tx_in_eop=0;
    wire tx_in_ready;
    reg [31:0] tx_in_data=32'h00ccbbaa;
    reg [3:0] tx_in_keep=4'b0111;
    reg [31:0] tx_packet_sequence=32'h11223344;
    reg [15:0] tx_packet_length=3;
    wire byte_valid,byte_ready,byte_sop,byte_eop;
    wire [7:0] byte_data;
    wire [31:0] next_frame_sequence;
    wire tx_error;

    reg word_valid=0,word_sop=0,word_eop=0;
    reg [31:0] word_data=0;
    reg [3:0] word_keep=0;
    reg [2:0] pack_count=0;
    reg pack_sop=0;
    wire word_ready;
    wire rx_out_valid,rx_out_sop,rx_out_eop;
    wire [31:0] rx_out_data;
    wire [3:0] rx_out_keep;
    reg rx_out_ready=1;
    wire [31:0] rx_packet_sequence,rx_frame_sequence,next_rx_sequence;
    wire [7:0] rx_lane_id;
    wire rx_error,rx_frame_valid;
    integer got=0,cycles=0,i;

    bonded_wire_tx_lane #(.DATA_WIDTH(32),.LANE_ID(1)) tx (
        .clk(clk),.rst(rst),.session_id(64'h0102030405060708),
        .frame_start_enable(1'b1),.frame_sequence_override(32'd0),
        .in_valid(tx_in_valid),.in_ready(tx_in_ready),.in_data(tx_in_data),
        .in_keep(tx_in_keep),.in_sop(tx_in_sop),.in_eop(tx_in_eop),
        .in_packet_sequence(tx_packet_sequence),.in_packet_length(tx_packet_length),
        .out_valid(byte_valid),.out_ready(byte_ready),.out_data(byte_data),
        .out_sop(byte_sop),.out_eop(byte_eop),
        .next_frame_sequence(next_frame_sequence),.frame_error(tx_error)
    );

    assign byte_ready=!word_valid;
    bonded_wire_rx_lane_parallel #(.DATA_WIDTH(32),.LANE_ID(1)) rx (
        .clk(clk),.rst(rst),.expected_session_id(64'h0102030405060708),
        .expected_frame_sequence_override(32'd0),.expected_lane_id(8'd1),
        .in_valid(word_valid),.in_ready(word_ready),.in_data(word_data),
        .in_keep(word_keep),.in_sop(word_sop),.in_eop(word_eop),
        .out_valid(rx_out_valid),.out_ready(rx_out_ready),.out_data(rx_out_data),
        .out_keep(rx_out_keep),.out_sop(rx_out_sop),.out_eop(rx_out_eop),
        .out_packet_sequence(rx_packet_sequence),.out_frame_sequence(rx_frame_sequence),
        .out_lane_id(rx_lane_id),.expected_frame_sequence(next_rx_sequence),
        .frame_error(rx_error),.frame_valid_pulse(rx_frame_valid)
    );

    always @(posedge clk) begin
        if(rst) begin
            word_valid<=0; pack_count<=0; pack_sop<=0;
            word_data<=0; word_keep<=0; word_sop<=0; word_eop<=0;
        end else begin
            if(word_valid && word_ready) word_valid<=0;
            if(byte_valid && byte_ready) begin
                word_data[pack_count*8 +: 8]<=byte_data;
                word_keep[pack_count]<=1'b1;
                if(pack_count==0) pack_sop<=byte_sop;
                if(pack_count==3 || byte_eop) begin
                    word_valid<=1;
                    word_sop<= (pack_count==0) ? byte_sop : pack_sop;
                    word_eop<=byte_eop;
                    pack_count<=0;
                    pack_sop<=0;
                end else pack_count<=pack_count+1'b1;
            end
            if(word_valid && word_ready) begin
                word_data<=0; word_keep<=0; word_sop<=0; word_eop<=0;
            end
        end
    end

    always @(posedge clk) begin
        if(!rst && rx_out_valid && rx_out_ready) begin
            if(rx_out_sop && got!=0) $fatal(1,"unexpected second SOP");
            for(i=0;i<4;i=i+1) if(rx_out_keep[i]) begin
                case(got)
                    0: if(rx_out_data[i*8 +: 8]!==8'haa) $fatal(1,"payload byte 0 mismatch");
                    1: if(rx_out_data[i*8 +: 8]!==8'hbb) $fatal(1,"payload byte 1 mismatch");
                    2: if(rx_out_data[i*8 +: 8]!==8'hcc) $fatal(1,"payload byte 2 mismatch");
                    default: $fatal(1,"unexpected extra payload");
                endcase
                got=got+1;
            end
            if(rx_out_eop && got!=3) $fatal(1,"early payload EOP");
            if(got==3 && !rx_out_eop) $fatal(1,"missing payload EOP");
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
           rx_frame_sequence!=0 || rx_lane_id!=1 || next_rx_sequence!=1 || next_frame_sequence!=1)
            $fatal(1,"serial TX -> parallel RX failed got=%0d txerr=%b rxerr=%b",got,tx_error,rx_error);
        $display("PASS: byte-serial TX -> parallel-word RX");
        $finish;
    end
endmodule
