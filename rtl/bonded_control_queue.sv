// SPDX-License-Identifier: BSD-2-Clause
// Small synchronous message FIFO reserved exclusively for CONTROL traffic.
module bonded_control_queue #(
    parameter integer DEPTH = 4,
    parameter integer PTR_WIDTH = (DEPTH <= 2) ? 1 : $clog2(DEPTH)
) (
    input wire clk,
    input wire rst,
    input wire in_valid,
    output wire in_ready,
    input wire [207:0] in_body,
    input wire [5:0] in_length,
    output wire out_valid,
    input wire out_ready,
    output wire [207:0] out_body,
    output wire [5:0] out_length,
    output wire full,
    output wire empty
);
    reg [213:0] mem [0:DEPTH-1];
    reg [PTR_WIDTH-1:0] wr_ptr,rd_ptr;
    reg [PTR_WIDTH:0] count;
    wire push = in_valid && in_ready;
    wire pop = out_valid && out_ready;
    assign full = (count==DEPTH);
    assign empty = (count==0);
    assign in_ready = !rst && !full;
    assign out_valid = !rst && !empty;
    assign {out_length,out_body}=mem[rd_ptr];

    initial begin
        if(DEPTH<2 || (DEPTH & (DEPTH-1))!=0)
            $error("CONTROL queue DEPTH must be a power of two >= 2");
    end
    always @(posedge clk) begin
        if(rst) begin
            wr_ptr<=0;rd_ptr<=0;count<=0;
        end else begin
            if(push) begin
                mem[wr_ptr]<={in_length,in_body};
                wr_ptr<=wr_ptr+1'b1;
            end
            if(pop) rd_ptr<=rd_ptr+1'b1;
            case({push,pop})
                2'b10: count<=count+1'b1;
                2'b01: count<=count-1'b1;
                default: count<=count;
            endcase
        end
    end
endmodule
