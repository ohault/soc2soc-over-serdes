// SPDX-License-Identifier: BSD-2-Clause
// Experimental payload-RAM-backed parallel DATA frame decoder.
// Kept separate from the byte-array reference until differential validation.
module bonded_wire_rx_lane_parallel_ram #(
    parameter integer DATA_WIDTH=32,
    parameter integer KEEP_WIDTH=DATA_WIDTH/8,
    parameter integer LANE_ID=0,
    parameter integer MAX_PAYLOAD=4096,
    parameter integer DYNAMIC_LANE_ID=0
) (
    input wire clk, input wire rst,
    input wire [63:0] expected_session_id,
    input wire [31:0] expected_frame_sequence_override,
    input wire [7:0] expected_lane_id,
    input wire in_valid, output wire in_ready,
    input wire [DATA_WIDTH-1:0] in_data,
    input wire [KEEP_WIDTH-1:0] in_keep,
    input wire in_sop, input wire in_eop,
    output reg out_valid, input wire out_ready,
    output reg [DATA_WIDTH-1:0] out_data,
    output reg [KEEP_WIDTH-1:0] out_keep,
    output wire out_sop, output wire out_eop,
    output reg [31:0] out_packet_sequence,
    output reg [31:0] out_frame_sequence,
    output reg [7:0] out_lane_id,
    output reg [31:0] expected_frame_sequence,
    output reg frame_error, output reg frame_valid_pulse
);
    localparam integer WORD_BYTES=DATA_WIDTH/8;
    localparam integer MAX_FRAME=24+4+MAX_PAYLOAD+4;
    localparam integer PAYLOAD_WORDS=(MAX_PAYLOAD+WORD_BYTES-1)/WORD_BYTES;
    localparam integer PAYLOAD_ADDR_WIDTH=(PAYLOAD_WORDS<=1)?1:$clog2(PAYLOAD_WORDS);
    localparam [2:0] ST_IDLE=0, ST_COLLECT=1, ST_CHECK=2,
                     ST_READ_REQ=3, ST_READ_WAIT=4, ST_OUTPUT=5;

    reg [2:0] state;
    reg [7:0] header_mem[0:27];
    reg [12:0] rx_count;
    reg [12:0] output_byte_index;
    reg [12:0] payload_length;
    reg [15:0] header_crc_calc;
    reg [31:0] frame_crc_calc;
    reg [7:0] tail0,tail1,tail2,tail3;
    reg [31:0] frame_sequence_received;
    integer byte_count;

    reg payload_wr_en;
    reg [PAYLOAD_ADDR_WIDTH-1:0] payload_wr_addr;
    reg [DATA_WIDTH-1:0] payload_wr_data;
    reg [WORD_BYTES-1:0] payload_wr_keep;
    reg [PAYLOAD_ADDR_WIDTH-1:0] payload_rd_addr;
    wire [DATA_WIDTH-1:0] payload_rd_data;
    wire payload_rd_valid;
    wire payload_rd_en=(state==ST_READ_REQ);

    bonded_payload_word_ram #(
        .DATA_WIDTH(DATA_WIDTH), .MAX_PAYLOAD(MAX_PAYLOAD)
    ) payload_ram (
        .clk(clk), .rst(rst),
        .wr_en(payload_wr_en), .wr_addr(payload_wr_addr),
        .wr_data(payload_wr_data), .wr_keep(payload_wr_keep),
        .rd_en(payload_rd_en), .rd_addr(payload_rd_addr),
        .rd_data(payload_rd_data), .rd_valid(payload_rd_valid)
    );

    // Header and integrity metadata stay in registers. Only bytes belonging
    // to the payload interval are written into the synchronous word RAM.
    task capture_word;
        input integer base_index;
        input [DATA_WIDTH-1:0] word_data;
        input [KEEP_WIDTH-1:0] word_keep;
        input reset_crc;
        integer n;
        integer absolute_index;
        integer lane;
        integer selected_addr;
        reg [15:0] h;
        reg [31:0] f;
        reg [7:0] t0,t1,t2,t3;
        reg [DATA_WIDTH-1:0] p_data;
        reg [WORD_BYTES-1:0] p_keep;
        begin
            h=reset_crc ? 16'hffff : header_crc_calc;
            f=reset_crc ? 32'hffffffff : frame_crc_calc;
            t0=reset_crc ? 8'h00 : tail0;
            t1=reset_crc ? 8'h00 : tail1;
            t2=reset_crc ? 8'h00 : tail2;
            t3=reset_crc ? 8'h00 : tail3;
            p_data={DATA_WIDTH{1'b0}};
            p_keep={WORD_BYTES{1'b0}};
            selected_addr=-1;
            for(n=0;n<KEEP_WIDTH;n=n+1) begin
                if(word_keep[n]) begin
                    absolute_index=base_index+n;
                    if(absolute_index<22)
                        h=crc16_byte(h,word_data[n*8 +: 8]);
                    if(absolute_index>=4)
                        f=crc32_byte(f,t3);
                    t3=t2; t2=t1; t1=t0; t0=word_data[n*8 +: 8];

                    if(absolute_index<28)
                        header_mem[absolute_index]<=word_data[n*8 +: 8];
                    else if(absolute_index<(28+{header_mem[20],header_mem[21]}-16'd4)) begin
                        lane=(absolute_index-28)%WORD_BYTES;
                        if(selected_addr==-1)
                            selected_addr=(absolute_index-28)/WORD_BYTES;
                        p_data[lane*8 +: 8]=word_data[n*8 +: 8];
                        p_keep[lane]=1'b1;
                    end
                end
            end
            header_crc_calc<=h;
            frame_crc_calc<=f;
            tail0<=t0; tail1<=t1; tail2<=t2; tail3<=t3;
            payload_wr_en<=(p_keep!={WORD_BYTES{1'b0}});
            if(p_keep!={WORD_BYTES{1'b0}}) begin
                payload_wr_addr<=selected_addr[PAYLOAD_ADDR_WIDTH-1:0];
                payload_wr_data<=p_data;
                payload_wr_keep<=p_keep;
            end
        end
    endtask

    function keep_contiguous(input [KEEP_WIDTH-1:0] keep);
        begin keep_contiguous=(keep!=0)&&((keep&(keep+1'b1))==0); end
    endfunction
    function integer count_keep(input [KEEP_WIDTH-1:0] keep);
        integer n;
        begin count_keep=0; for(n=0;n<KEEP_WIDTH;n=n+1) count_keep=count_keep+keep[n]; end
    endfunction
    function [15:0] crc16_byte(input [15:0] ci,input [7:0] d);
        integer k; reg [15:0] c;
        begin c=ci^{d,8'h00}; for(k=0;k<8;k=k+1)c=c[15]?((c<<1)^16'h1021):(c<<1); crc16_byte=c; end
    endfunction
    function [31:0] crc32_byte(input [31:0] ci,input [7:0] d);
        integer k; reg [31:0] c;
        begin c=ci^d; for(k=0;k<8;k=k+1)c=c[0]?((c>>1)^32'h82f63b78):(c>>1); crc32_byte=c; end
    endfunction

    assign in_ready=!rst&&(state==ST_IDLE||state==ST_COLLECT);
    assign out_sop=out_valid&&(output_byte_index==0);
    assign out_eop=out_valid&&(payload_length==0 ||
                               output_byte_index+count_keep(out_keep)>=payload_length);

    integer keep_lane;
    always @(posedge clk) begin
        if(rst) begin
            state<=ST_IDLE; rx_count<=0; output_byte_index<=0; payload_length<=0;
            header_crc_calc<=16'hffff; frame_crc_calc<=32'hffffffff;
            tail0<=0; tail1<=0; tail2<=0; tail3<=0;
            payload_wr_en<=0; payload_wr_addr<=0; payload_wr_data<=0;
            payload_wr_keep<=0; payload_rd_addr<=0;
            out_valid<=0; out_data<=0; out_keep<=0;
            out_packet_sequence<=0; out_frame_sequence<=0; out_lane_id<=0;
            expected_frame_sequence<=0; frame_error<=0; frame_valid_pulse<=0;
        end else begin
            payload_wr_en<=0;
            frame_valid_pulse<=0;

            if(in_valid&&in_ready) begin
                if(state==ST_IDLE) begin
                    if(!in_sop || expected_session_id==0 || !keep_contiguous(in_keep)) begin
                        frame_error<=1;
                    end else begin
                        byte_count=count_keep(in_keep);
                        if(byte_count>MAX_FRAME) frame_error<=1;
                        else begin
                            capture_word(0,in_data,in_keep,1'b1);
                            rx_count<=byte_count;
                            state<=in_eop?ST_CHECK:ST_COLLECT;
                        end
                    end
                end else begin
                    if(in_sop) begin
                        frame_error<=1;
                        byte_count=count_keep(in_keep);
                        if(!keep_contiguous(in_keep)||byte_count>MAX_FRAME) begin
                            state<=ST_IDLE; rx_count<=0;
                        end else begin
                            capture_word(0,in_data,in_keep,1'b1);
                            rx_count<=byte_count;
                            state<=in_eop?ST_CHECK:ST_COLLECT;
                        end
                    end else begin
                        byte_count=count_keep(in_keep);
                        if(!keep_contiguous(in_keep)||rx_count+byte_count>MAX_FRAME) begin
                            frame_error<=1; state<=ST_IDLE; rx_count<=0;
                        end else begin
                            capture_word(rx_count,in_data,in_keep,1'b0);
                            rx_count<=rx_count+byte_count;
                            if(in_eop) state<=ST_CHECK;
                        end
                    end
                end
            end

            if(state==ST_CHECK) begin
                frame_sequence_received={header_mem[16],header_mem[17],header_mem[18],header_mem[19]};
                if(rx_count<32 || header_mem[0]!=8'h53 || header_mem[1]!=8'h42 ||
                   header_mem[2]!=8'h01 || header_mem[3]!=8'h01 || header_mem[4]!=0 ||
                   (DYNAMIC_LANE_ID ? ((expected_lane_id!=8'hff)&&(header_mem[5]!=expected_lane_id)) : (header_mem[5]!=LANE_ID[7:0])) ||
                   header_mem[6]!=0 || header_mem[7]!=8'h18 ||
                   {header_mem[22],header_mem[23]}!=header_crc_calc ||
                   {header_mem[20],header_mem[21]}<4 ||
                   {header_mem[20],header_mem[21]}>MAX_PAYLOAD+4 ||
                   rx_count!=24+{header_mem[20],header_mem[21]}+4 ||
                   {tail3,tail2,tail1,tail0}!=~frame_crc_calc) begin
                    frame_error<=1; state<=ST_IDLE; rx_count<=0;
                end else if({header_mem[8],header_mem[9],header_mem[10],header_mem[11],
                             header_mem[12],header_mem[13],header_mem[14],header_mem[15]}!=expected_session_id) begin
                    state<=ST_IDLE; rx_count<=0;
                end else if(frame_sequence_received!=expected_frame_sequence_override ||
                            expected_frame_sequence_override==32'hffffffff) begin
                    frame_error<=1; state<=ST_IDLE; rx_count<=0;
                end else begin
                    out_packet_sequence<={header_mem[24],header_mem[25],header_mem[26],header_mem[27]};
                    out_frame_sequence<=frame_sequence_received;
                    out_lane_id<=header_mem[5];
                    expected_frame_sequence<=frame_sequence_received+1'b1;
                    payload_length<={header_mem[20],header_mem[21]}-16'd4;
                    output_byte_index<=0;
                    frame_valid_pulse<=1;
                    if(({header_mem[20],header_mem[21]}-16'd4)==0) begin
                        out_data<=0; out_keep<={KEEP_WIDTH{1'b0}};
                        out_valid<=1; state<=ST_OUTPUT;
                    end else begin
                        payload_rd_addr<=0;
                        state<=ST_READ_REQ;
                    end
                end
            end

            if(state==ST_READ_REQ)
                state<=ST_READ_WAIT;

            if(state==ST_READ_WAIT && payload_rd_valid) begin
                out_data<=payload_rd_data;
                for(keep_lane=0;keep_lane<KEEP_WIDTH;keep_lane=keep_lane+1)
                    out_keep[keep_lane]<=((output_byte_index+keep_lane)<payload_length);
                out_valid<=1;
                state<=ST_OUTPUT;
            end

            if(state==ST_OUTPUT && out_valid && out_ready) begin
                out_valid<=0;
                if(out_eop) begin
                    state<=ST_IDLE; rx_count<=0;
                end else begin
                    output_byte_index<=output_byte_index+count_keep(out_keep);
                    payload_rd_addr<=payload_rd_addr+1'b1;
                    state<=ST_READ_REQ;
                end
            end
        end
    end

    `ifndef SYNTHESIS
    initial begin
        if((DATA_WIDTH!=8)&&(DATA_WIDTH!=16)&&(DATA_WIDTH!=32)) $error("DATA_WIDTH must be 8, 16 or 32");
        if(KEEP_WIDTH!=WORD_BYTES) $error("KEEP_WIDTH must equal DATA_WIDTH/8");
        if(MAX_PAYLOAD<1||MAX_PAYLOAD>4096) $error("MAX_PAYLOAD must be 1..4096");
    end
    `endif
endmodule
