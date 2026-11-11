// SPDX-License-Identifier: BSD-2-Clause
// Single-clock byte elastic FIFO between the PHY adapter and frame parser.
module bonded_sync_byte_fifo #(
    parameter integer DEPTH=64,
    parameter integer PTR_WIDTH=(DEPTH<=2)?1:$clog2(DEPTH)
) (
    input wire clk,
    input wire rst,
    input wire in_valid,
    output wire in_ready,
    input wire [7:0] in_data,
    output wire out_valid,
    input wire out_ready,
    output wire [7:0] out_data,
    output wire full,
    output wire empty
);
    reg [7:0] mem[0:DEPTH-1];
    reg [PTR_WIDTH-1:0] wr_ptr,rd_ptr;
    reg [PTR_WIDTH:0] count;
    wire push=in_valid && in_ready;
    wire pop=out_valid && out_ready;
    assign full=(count==DEPTH);
    assign empty=(count==0);
    assign in_ready=!rst && !full;
    assign out_valid=!rst && !empty;
    assign out_data=mem[rd_ptr];
    initial begin
        if(DEPTH<2 || (DEPTH & (DEPTH-1))!=0)
            $error("PHY elastic FIFO DEPTH must be a power of two >= 2");
    end
    always @(posedge clk) begin
        if(rst) begin wr_ptr<=0;rd_ptr<=0;count<=0; end
        else begin
            if(push) begin mem[wr_ptr]<=in_data;wr_ptr<=wr_ptr+1'b1;end
            if(pop) rd_ptr<=rd_ptr+1'b1;
            case({push,pop})
                2'b10: count<=count+1'b1;
                2'b01: count<=count-1'b1;
                default: count<=count;
            endcase
        end
    end
endmodule
