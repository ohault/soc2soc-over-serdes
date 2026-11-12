// SPDX-License-Identifier: BSD-2-Clause
// Convert a non-backpressurable read-enable/data-valid PHY FIFO into a
// ready/valid word stream. Every read request reserves an output FIFO slot;
// returned data is accepted only against a reservation.
module bonded_phy_fifo_read_adapter #(
    parameter integer DATA_WIDTH=44,
    parameter integer DEPTH=8,
    parameter integer PTR_WIDTH=(DEPTH<=2)?1:$clog2(DEPTH),
    parameter integer COUNT_WIDTH=$clog2(DEPTH+1)
) (
    input wire clk,
    input wire rst,

    input wire fifo_empty,
    output wire fifo_rdreq,
    input wire fifo_data_valid,
    input wire [DATA_WIDTH-1:0] fifo_data,

    output wire out_valid,
    input wire out_ready,
    output wire [DATA_WIDTH-1:0] out_data,

    output reg overflow,
    output reg protocol_error
);
    reg [DATA_WIDTH-1:0] mem[0:DEPTH-1];
    reg [PTR_WIDTH-1:0] wr_ptr,rd_ptr;
    reg [COUNT_WIDTH-1:0] count;
    reg [COUNT_WIDTH-1:0] pending_reads;

    wire pop=out_valid && out_ready;
    wire reserved_space=(count + pending_reads < DEPTH) || pop;
    assign fifo_rdreq=!rst && !fifo_empty && reserved_space;

    wire unreserved_return=fifo_data_valid && (pending_reads==0) && !fifo_rdreq;
    wire return_space=(count<DEPTH) || pop;
    wire push=fifo_data_valid && !unreserved_return && return_space;

    assign out_valid=!rst && (count!=0);
    assign out_data=mem[rd_ptr];

    initial begin
        if(DEPTH<2 || (DEPTH & (DEPTH-1))!=0)
            $error("DEPTH must be a power of two >= 2");
        if(COUNT_WIDTH<$clog2(DEPTH+1))
            $error("COUNT_WIDTH cannot represent DEPTH");
    end

    always @(posedge clk) begin
        if(rst) begin
            wr_ptr<=0;
            rd_ptr<=0;
            count<=0;
            pending_reads<=0;
            overflow<=1'b0;
            protocol_error<=1'b0;
        end else begin
            if(unreserved_return)
                protocol_error<=1'b1;
            if(fifo_data_valid && !return_space)
                overflow<=1'b1;

            if(push) begin
                mem[wr_ptr]<=fifo_data;
                wr_ptr<=wr_ptr+1'b1;
            end
            if(pop)
                rd_ptr<=rd_ptr+1'b1;

            case({fifo_rdreq,fifo_data_valid && !unreserved_return})
                2'b10: pending_reads<=pending_reads+1'b1;
                2'b01: pending_reads<=pending_reads-1'b1;
                default: pending_reads<=pending_reads;
            endcase

            case({push,pop})
                2'b10: count<=count+1'b1;
                2'b01: count<=count-1'b1;
                default: count<=count;
            endcase
        end
    end
endmodule
