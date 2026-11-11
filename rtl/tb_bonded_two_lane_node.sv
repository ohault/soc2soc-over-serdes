// SPDX-License-Identifier: BSD-2-Clause
module tb_bonded_two_lane_node;
 reg bond_a=0,bond_b=0;
 always #4 bond_a=~bond_a;
 always #4.5 bond_b=~bond_b;
 reg a_tx0=0,a_tx1=0,b_tx0=0,b_tx1=0;
 always #5 a_tx0=~a_tx0;
 always #9 a_tx1=~a_tx1;
 always #7 b_tx0=~b_tx0;
 always #11 b_tx1=~b_tx1;
 reg rst_n=0;
 wire a0txv,a0txs,a0txe,a1txv,a1txs,a1txe,b0txv,b0txs,b0txe,b1txv,b1txs,b1txe;
 wire [7:0] a0txd,a1txd,b0txd,b1txd;
 wire a0txr,a1txr,b0txr,b1txr;
 wire a0rxv,a0rxs,a0rxe,a1rxv,a1rxs,a1rxe,b0rxv,b0rxs,b0rxe,b1rxv,b1rxs,b1rxe;
 wire [7:0] a0rxd,a1rxd,b0rxd,b1rxd;
 wire a0rxr,a1rxr,b0rxr,b1rxr;
 wire [7:0] ab0data,ab1data,ba0data,ba1data;
 wire ab0v,ab1v,ba0v,ba1v,ab0ready,ab1ready,ba0ready,ba1ready;
 bonded_async_fifo #(.DATA_WIDTH(8),.DEPTH(32)) ab0(
  .wr_clk(a_tx0),.wr_rst_n(rst_n),.wr_valid(a0txv),.wr_ready(ab0ready),.wr_data(a0txd),
  .rd_clk(a_tx0),.rd_rst_n(rst_n),.rd_valid(ab0v),.rd_ready(b0rxr),.rd_data(ab0data));
 bonded_async_fifo #(.DATA_WIDTH(10),.DEPTH(32)) ab1(
  .wr_clk(a_tx1),.wr_rst_n(rst_n),.wr_valid(a1txv),.wr_ready(ab1ready),.wr_data(a1txd),
  .rd_clk(a_tx1),.rd_rst_n(rst_n),.rd_valid(ab1v),.rd_ready(b1rxr),.rd_data(ab1data));
 bonded_async_fifo #(.DATA_WIDTH(10),.DEPTH(32)) ba0(
  .wr_clk(b_tx0),.wr_rst_n(rst_n),.wr_valid(b0txv),.wr_ready(ba0ready),.wr_data(b0txd),
  .rd_clk(b_tx0),.rd_rst_n(rst_n),.rd_valid(ba0v),.rd_ready(a0rxr),.rd_data(ba0data));
 bonded_async_fifo #(.DATA_WIDTH(10),.DEPTH(32)) ba1(
  .wr_clk(b_tx1),.wr_rst_n(rst_n),.wr_valid(b1txv),.wr_ready(ba1ready),.wr_data(b1txd),
  .rd_clk(b_tx1),.rd_rst_n(rst_n),.rd_valid(ba1v),.rd_ready(a1rxr),.rd_data(ba1data));
 assign a0txr=ab0ready; assign a1txr=ab1ready; assign b0txr=ba0ready; assign b1txr=ba1ready;
 assign b0rxv=ab0v; assign b0rxd=ab0data;
 assign b1rxv=ab1v; assign b1rxd=ab1data;
 assign a0rxv=ba0v; assign a0rxd=ba0data;
 assign a1rxv=ba1v; assign a1rxd=ba1data;

 reg atxv=0,ats=0,ate=0;
 reg [31:0] atxd=0;
 reg [3:0] atk=0;
 wire atxr,btxr,arxv,brxv;
 wire [7:0] arxd,brxd;
 wire ars,are,brs,bre;
 wire [31:0] arseq,brseq;
 wire active_a,active_b,fault_a,fault_b,credit_a,credit_b;
 wire txerr_a,txerr_b,rxerr_a,rxerr_b;
 wire a0te,a1te,b0te,b1te,a0re,a1re,b0re,b1re;
 bonded_two_lane_node #(.DATA_WIDTH(32),.TX_FIFO_DEPTH(16),.RX_FIFO_DEPTH(16),
  .REORDER_WINDOW(4),.MAX_PACKET_BYTES(64),.SESSION_ID(64'h123456789abcdef0),
  .LOCAL_PEER_ID(64'd1),.EXPECTED_PEER_ID(64'd2),.MAX_PAYLOAD(16'd64),
  .PING_INTERVAL_CYCLES(32'd1000000),.PONG_TIMEOUT_CYCLES(32'd3000000)) node_a(
  .bond_clk(bond_a),.bond_rst_n(rst_n),.lane0_up(1'b1),.lane1_up(1'b1),
  .lane0_tx_clk(a_tx0),.lane0_tx_rst_n(rst_n),.lane0_tx_valid(a0txv),.lane0_tx_ready(a0txr),.lane0_tx_data(a0txd),.lane0_tx_sop(a0txs),.lane0_tx_eop(a0txe),
  .lane1_tx_clk(a_tx1),.lane1_tx_rst_n(rst_n),.lane1_tx_valid(a1txv),.lane1_tx_ready(a1txr),.lane1_tx_data(a1txd),.lane1_tx_sop(a1txs),.lane1_tx_eop(a1txe),
  .lane0_rx_clk(b_tx0),.lane0_rx_rst_n(rst_n),.lane0_rx_valid(a0rxv),.lane0_rx_ready(a0rxr),.lane0_rx_data(a0rxd),
  .lane1_rx_clk(b_tx1),.lane1_rx_rst_n(rst_n),.lane1_rx_valid(a1rxv),.lane1_rx_ready(a1rxr),.lane1_rx_data(a1rxd),
  .tx_valid(atxv),.tx_ready(atxr),.tx_data(atxd),.tx_keep(atk),.tx_sop(ats),.tx_eop(ate),
  .rx_valid(arxv),.rx_ready(1'b1),.rx_data(arxd),.rx_sop(ars),.rx_eop(are),.rx_packet_sequence(arseq),
  .session_active(active_a),.control_fault(fault_a),.rx_credit_error(credit_a),
  .tx_packet_error(txerr_a),.rx_packet_error(rxerr_a),
  .lane0_tx_frame_error(a0te),.lane1_tx_frame_error(a1te),.lane0_rx_frame_error(a0re),.lane1_rx_frame_error(a1re));
 bonded_two_lane_node #(.DATA_WIDTH(32),.TX_FIFO_DEPTH(16),.RX_FIFO_DEPTH(16),
  .REORDER_WINDOW(4),.MAX_PACKET_BYTES(64),.SESSION_ID(64'h123456789abcdef0),
  .LOCAL_PEER_ID(64'd2),.EXPECTED_PEER_ID(64'd1),.MAX_PAYLOAD(16'd64),
  .PING_INTERVAL_CYCLES(32'd1000000),.PONG_TIMEOUT_CYCLES(32'd3000000)) node_b(
  .bond_clk(bond_b),.bond_rst_n(rst_n),.lane0_up(1'b1),.lane1_up(1'b1),
  .lane0_tx_clk(b_tx0),.lane0_tx_rst_n(rst_n),.lane0_tx_valid(b0txv),.lane0_tx_ready(b0txr),.lane0_tx_data(b0txd),.lane0_tx_sop(b0txs),.lane0_tx_eop(b0txe),
  .lane1_tx_clk(b_tx1),.lane1_tx_rst_n(rst_n),.lane1_tx_valid(b1txv),.lane1_tx_ready(b1txr),.lane1_tx_data(b1txd),.lane1_tx_sop(b1txs),.lane1_tx_eop(b1txe),
  .lane0_rx_clk(a_tx0),.lane0_rx_rst_n(rst_n),.lane0_rx_valid(b0rxv),.lane0_rx_ready(b0rxr),.lane0_rx_data(b0rxd),
  .lane1_rx_clk(a_tx1),.lane1_rx_rst_n(rst_n),.lane1_rx_valid(b1rxv),.lane1_rx_ready(b1rxr),.lane1_rx_data(b1rxd),
  .tx_valid(1'b0),.tx_ready(btxr),.tx_data(32'd0),.tx_keep(4'd0),.tx_sop(1'b0),.tx_eop(1'b0),
  .rx_valid(brxv),.rx_ready(1'b1),.rx_data(brxd),.rx_sop(brs),.rx_eop(bre),.rx_packet_sequence(brseq),
  .session_active(active_b),.control_fault(fault_b),.rx_credit_error(credit_b),
  .tx_packet_error(txerr_b),.rx_packet_error(rxerr_b),
  .lane0_tx_frame_error(b0te),.lane1_tx_frame_error(b1te),.lane0_rx_frame_error(b0re),.lane1_rx_frame_error(b1re));
 integer got=0,cycles=0;
 always @(posedge bond_b) if(brxv) begin
  if(got==0 && (!brs || brd!==8'haa || bre)) $fatal(1,"B packet byte 0");
  if(got==1 && (brs || brd!==8'hbb || !bre)) $fatal(1,"B packet byte 1");
  got=got+1;
 end
 initial begin
  repeat(10) @(posedge bond_a);@(negedge bond_a);rst_n=1;
  cycles=0;
  while((!active_a || !active_b) && cycles<20000) begin @(posedge bond_a);cycles=cycles+1;end
  if(!active_a || !active_b || fault_a || fault_b)
   $fatal(1,"automatic HELLO/READY failed active=%b/%b fault=%b/%b",active_a,active_b,fault_a,fault_b);
  @(negedge bond_a);atxv=1;ats=1;ate=1;atk=4'b0011;atxd=32'h0000bbaa;
  #1;while(!atxr) begin @(negedge bond_a);#1;end
  @(posedge bond_a);@(negedge bond_a);atxv=0;ats=0;ate=0;
  cycles=0;
  while(got<2 && cycles<5000) begin @(posedge bond_b);cycles=cycles+1;end
  repeat(5) @(posedge bond_b);
  if(got!=2 || fault_a || fault_b || credit_a || credit_b || txerr_a || rxerr_b ||
     a0te || a1te || b0re || b1re)
   $fatal(1,"autonomous bonded DATA failed got=%0d",got);
  $display("PASS: autonomous two-node HELLO/READY, two-lane control, credits and DATA delivery");
  $finish;
 end
 initial begin #500000;$fatal(1,"timeout active=%b/%b fault=%b/%b",active_a,active_b,fault_a,fault_b);end
endmodule
