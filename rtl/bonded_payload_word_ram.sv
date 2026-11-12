// Generic synchronous word-wide payload RAM for bonded receive paths.
// The memory array is intentionally not reset so FPGA tools can infer block RAM.
module bonded_payload_word_ram #(
    parameter integer DATA_WIDTH = 32,
    parameter integer MAX_PAYLOAD = 4096,
    parameter integer KEEP_WIDTH = DATA_WIDTH / 8,
    parameter integer WORD_COUNT = (MAX_PAYLOAD + KEEP_WIDTH - 1) / KEEP_WIDTH,
    parameter integer ADDR_WIDTH = (WORD_COUNT <= 1) ? 1 : $clog2(WORD_COUNT)
) (
    input  wire                  clk,
    input  wire                  rst,

    input  wire                  wr_en,
    input  wire [ADDR_WIDTH-1:0] wr_addr,
    input  wire [DATA_WIDTH-1:0] wr_data,
    input  wire [KEEP_WIDTH-1:0] wr_keep,

    input  wire                  rd_en,
    input  wire [ADDR_WIDTH-1:0] rd_addr,
    output reg  [DATA_WIDTH-1:0] rd_data,
    output reg                   rd_valid
);

    reg [DATA_WIDTH-1:0] mem [0:WORD_COUNT-1];
    integer byte_index;

    always @(posedge clk) begin
        if (rst) begin
            // Do not clear mem: reset invalidates the interface, not stored bits.
            rd_valid <= 1'b0;
            rd_data  <= {DATA_WIDTH{1'b0}};
        end else begin
            rd_valid <= 1'b0;

            if (wr_en) begin
                for (byte_index = 0; byte_index < KEEP_WIDTH; byte_index = byte_index + 1) begin
                    if (wr_keep[byte_index])
                        mem[wr_addr][byte_index*8 +: 8] <= wr_data[byte_index*8 +: 8];
                end
            end

            // One-cycle synchronous read. Same-address read/write is intentionally
            // unspecified; the receive design writes during collection and reads
            // only after the complete frame has passed validation.
            if (rd_en) begin
                rd_data  <= mem[rd_addr];
                rd_valid <= 1'b1;
            end
        end
    end

endmodule
