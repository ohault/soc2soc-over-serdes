// SPDX-License-Identifier: BSD-2-Clause
`timescale 1ns/1ps
// Compare complete wire streams from the byte-serial and parallel encoders.
module tb_bonded_wire_tx_serial_parallel_compare;
    parameter integer DATA_WIDTH=32;
    localparam integer KEEP_WIDTH=DATA_WIDTH/8;
    localparam integer PAYLOAD_LEN=7;
    localparam integer FRAME_LEN=24+4+PAYLOAD_LEN+4;
    reg clk=0; always #5 clk=~clk;
    reg rst=1;
    reg [63:0] session_id=64'h0102030405060708;
    reg frame_start_enable=1;
    reg [31:0] frame_sequence=0;
    reg in_valid=0,in_sop=0,in_eop=0;
    reg [DATA_WIDTH-1:0] in_data=0;
    reg [KEEP_WIDTH-1:0] in_keep=0;
    reg [31:0] packet_sequence=32'h89abcdef;
    reg [15:0] packet_length=PAYLOAD_LEN;
    wire serial_ready,parallel_ready;
    wire serial_valid,serial_sop,serial_eop;
    wire [7:0] serial_data;
    wire parallel_valid,parallel_sop,parallel_eop;
    wire [DATA_WIDTH-1:0] parallel_data;
    wire [KEEP_WIDTH-1:0] parallel_keep;
    wire [31:0] next_frame_sequence;
    wire serial_error,parallel_error;
    reg [7:0] serial_bytes[0:FRAME_LEN-1];
    reg [7:0] parallel_bytes[0:FRAME_LEN-1];
    integer serial_count=0,parallel_count=0;
    integer beat,bytepos,idx,cycles=0;

    bonded_wire_tx_lane #(.DATA_WIDTH(DATA_WIDTH),.KEEP_WIDTH(KEEP_WIDTH),.LANE_ID(8'h5a)) serial_tx (
        .clk(clk),.rst(rst),.session_id(session_id),.frame_start_enable(frame_start_enable),
        .frame_sequence_override(frame_sequence),.in_valid(in_valid),.in_ready(serial_ready),
        .in_data(in_data),.in_keep(in_keep),.in_sop(in_sop),.in_eop(in_eop),
        .in_packet_sequence(packet_sequence),.in_packet_length(packet_length),
        .out_valid(serial_valid),.out_ready(1'b1),.out_data(serial_data),
        .out_sop(serial_sop),.out_eop(serial_eop),.next_frame_sequence(next_frame_sequence),
        .frame_error(serial_error)
    );
    bonded_wire_tx_lane_parallel #(.DATA_WIDTH(DATA_WIDTH),.KEEP_WIDTH(KEEP_WIDTH),.LANE_ID(8'h5a)) parallel_tx (
        .clk(clk),.rst(rst),.session_id(session_id),.frame_start_enable(frame_start_enable),
        .frame_sequence(frame_sequence),.in_valid(in_valid),.in_ready(parallel_ready),
        .in_data(in_data),.in_keep(in_keep),.in_sop(in_sop),.in_eop(in_eop),
        .in_packet_sequence(packet_sequence),.in_packet_length(packet_length),
        .out_valid(parallel_valid),.out_ready(1'b1),.out_data(parallel_data),
        .out_keep(parallel_keep),.out_sop(parallel_sop),.out_eop(parallel_eop),
        .frame_error(parallel_error)
    );

    always @(posedge clk) begin
        if(!rst && DATA_WIDTH==8 && in_valid && parallel_ready)
            $display("TXDBG accept keep=%b sop=%b eop=%b bytes_seen=%0d length=%0d state=%0d payload_valid=%b payload_eop=%b",
                     in_keep,in_sop,in_eop,parallel_tx.payload_bytes_seen,
                     parallel_tx.packet_length,parallel_tx.state,
                     parallel_tx.payload_valid,parallel_tx.payload_eop);
        if(!rst && DATA_WIDTH==8 && parallel_error)
            $display("TXDBG ERROR state=%0d bytes_seen=%0d length=%0d in_valid=%b keep=%b sop=%b eop=%b",
                     parallel_tx.state,parallel_tx.payload_bytes_seen,
                     parallel_tx.packet_length,in_valid,in_keep,in_sop,in_eop);
        if(!rst && serial_valid) begin
            if(serial_count>=FRAME_LEN) $fatal(1,"serial encoder emitted too many bytes");
            if(serial_sop !== (serial_count==0) || serial_eop !== (serial_count==FRAME_LEN-1))
                $fatal(1,"serial SOP/EOP mismatch at byte %0d",serial_count);
            serial_bytes[serial_count]=serial_data;
            serial_count=serial_count+1;
        end
        if(!rst && parallel_valid) begin
            if(parallel_sop !== (parallel_count==0))
                $fatal(1,"parallel SOP mismatch at byte %0d",parallel_count);
            for(integer k=0;k<KEEP_WIDTH;k=k+1) if(parallel_keep[k]) begin
                if(parallel_count>=FRAME_LEN) $fatal(1,"parallel encoder emitted too many bytes");
                parallel_bytes[parallel_count]=parallel_data[k*8 +: 8];
                parallel_count=parallel_count+1;
            end
            if(parallel_eop !== (parallel_count==FRAME_LEN))
                $fatal(1,"parallel EOP mismatch width=%0d count=%0d",DATA_WIDTH,parallel_count);
        end
    end

    task send_payload_beat(input integer first_byte,input integer nbytes,input bit first,input bit last);
        begin
            @(negedge clk);
            in_data=0; in_keep=0;
            for(integer k=0;k<nbytes;k=k+1) begin
                in_data[k*8 +: 8]=(8'h31+first_byte+k);
                in_keep[k]=1'b1;
            end
            in_sop=first; in_eop=last; in_valid=1;
            while(!(serial_ready && parallel_ready)) @(negedge clk);
            @(posedge clk);
            @(negedge clk);
            in_valid=0; in_sop=0; in_eop=0; in_keep=0;
        end
    endtask

    initial begin
        repeat(4) @(posedge clk);
        @(negedge clk); rst=0;
        bytepos=0;
        while(bytepos<PAYLOAD_LEN) begin
            beat=KEEP_WIDTH;
            if(bytepos+beat>PAYLOAD_LEN) beat=PAYLOAD_LEN-bytepos;
            send_payload_beat(bytepos,beat,(bytepos==0),(bytepos+beat==PAYLOAD_LEN));
            bytepos=bytepos+beat;
        end
        while((serial_count<FRAME_LEN || parallel_count<FRAME_LEN) && cycles<2000) begin
            @(posedge clk); cycles=cycles+1;
        end
        repeat(3) @(posedge clk);
        if(serial_count!=FRAME_LEN || parallel_count!=FRAME_LEN ||
           serial_error || parallel_error || next_frame_sequence!=1)
            $fatal(1,"encoder completion failed width=%0d serial=%0d parallel=%0d errors=%b/%b",
                   DATA_WIDTH,serial_count,parallel_count,serial_error,parallel_error);
        for(idx=0;idx<FRAME_LEN;idx=idx+1)
            if(serial_bytes[idx]!==parallel_bytes[idx])
                $fatal(1,"encoder mismatch width=%0d byte=%0d serial=%02x parallel=%02x",
                       DATA_WIDTH,idx,serial_bytes[idx],parallel_bytes[idx]);
        $display("PASS: serial/parallel TX byte-identical DATA_WIDTH=%0d",DATA_WIDTH);
        $finish;
    end
endmodule
