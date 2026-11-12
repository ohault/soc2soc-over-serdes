// SPDX-License-Identifier: BSD-2-Clause
`timescale 1ns/1ps
module tb_bonded_phy_fifo_read_adapter;
    localparam integer DATA_WIDTH=44;
    localparam integer DEPTH=4;
    localparam integer NUM_WORDS=96;

    reg clk=0;always #5 clk=~clk;
    reg rst=1;
    reg out_ready=0;
    reg [DATA_WIDTH-1:0] fifo_mem[0:NUM_WORDS-1];
    integer rd_index=0;
    integer received=0;
    integer cycles=0;

    wire fifo_empty=(rd_index==NUM_WORDS);
    wire fifo_rdreq;
    reg [2:0] valid_pipe=0;
    reg [DATA_WIDTH-1:0] data_pipe0=0,data_pipe1=0,data_pipe2=0;
    wire fifo_data_valid=valid_pipe[2];
    wire [DATA_WIDTH-1:0] fifo_data=data_pipe2;

    wire out_valid;
    wire [DATA_WIDTH-1:0] out_data;
    wire overflow,protocol_error;

    bonded_phy_fifo_read_adapter #(.DATA_WIDTH(DATA_WIDTH),.DEPTH(DEPTH)) dut(
        .clk(clk),.rst(rst),
        .fifo_empty(fifo_empty),.fifo_rdreq(fifo_rdreq),
        .fifo_data_valid(fifo_data_valid),.fifo_data(fifo_data),
        .out_valid(out_valid),.out_ready(out_ready),.out_data(out_data),
        .overflow(overflow),.protocol_error(protocol_error)
    );

    always @(posedge clk) begin
        if(rst) begin
            rd_index<=0;
            valid_pipe<=0;
            data_pipe0<=0;data_pipe1<=0;data_pipe2<=0;
            received<=0;
            cycles<=0;
            out_ready<=0;
        end else begin
            cycles<=cycles+1;
            out_ready<=((cycles%13)!=3 && (cycles%13)!=4 &&
                        (cycles%13)!=5 && (cycles%13)!=9);

            valid_pipe<={valid_pipe[1:0],fifo_rdreq};
            if(fifo_rdreq) begin
                if(rd_index>=NUM_WORDS) $fatal(1,"read request after FIFO empty");
                data_pipe0<=fifo_mem[rd_index];
                rd_index<=rd_index+1;
            end
            data_pipe1<=data_pipe0;
            data_pipe2<=data_pipe1;

            if(out_valid && out_ready) begin
                if(received>=NUM_WORDS || out_data!==fifo_mem[received])
                    $fatal(1,"FIFO adapter data/order mismatch at %0d",received);
                received<=received+1;
            end
        end
    end

    integer i;
    initial begin
        for(i=0;i<NUM_WORDS;i=i+1)
            fifo_mem[i]=44'hA0000000000+i;
        repeat(4) @(posedge clk);
        @(negedge clk);rst=0;
        wait(received==NUM_WORDS);
        repeat(5) @(posedge clk);
        if(rd_index!=NUM_WORDS || overflow || protocol_error)
            $fatal(1,"FIFO adapter status/consumption failure");
        $display("PASS: reservation-aware PHY FIFO adapter, delayed read-valid and backpressure");
        $finish;
    end
    initial begin #200000;$fatal(1,"timeout");end
endmodule
