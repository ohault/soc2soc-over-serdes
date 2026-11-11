// SPDX-License-Identifier: BSD-2-Clause
module tb_bonded_credit_manager;
 reg clk=0; always #5 clk=~clk;
 reg rst=1;
 reg tv=0; reg [15:0] tb=0; wire tr;
 reg [63:0] remote_b=0; reg [31:0] remote_p=0;
 wire [63:0] sent_b; wire [31:0] sent_p;
 reg av=0; reg [15:0] ab=0; wire ar;
 reg cv=0; reg [15:0] cb=0;
 wire [63:0] acc_b,used_b,grant_b;
 wire [31:0] acc_p,used_p,grant_p;
 wire err;
 bonded_credit_manager #(.INITIAL_RX_BYTES(100),.INITIAL_RX_PACKETS(2)) dut(
 .clk(clk),.rst(rst),.tx_reserve_valid(tv),.tx_reserve_bytes(tb),.tx_reserve_ready(tr),
 .remote_byte_limit(remote_b),.remote_packet_limit(remote_p),
 .tx_reserved_bytes(sent_b),.tx_reserved_packets(sent_p),
 .rx_accept_valid(av),.rx_accept_bytes(ab),.rx_accept_ready(ar),
 .rx_consume_valid(cv),.rx_consume_bytes(cb),
 .rx_accepted_bytes(acc_b),.rx_accepted_packets(acc_p),
 .rx_consumed_bytes(used_b),.rx_consumed_packets(used_p),
 .local_byte_limit(grant_b),.local_packet_limit(grant_p),.credit_error(err));
 task tick; begin @(posedge clk); #1; end endtask
 initial begin
   tick; rst=0; remote_b=10; remote_p=1;
   tv=1;tb=10; #1;if(!tr)$fatal(1,"first TX reservation denied");tick;
   tb=1; #1;if(tr)$fatal(1,"TX byte credit overrun accepted");
   tv=0; av=1;ab=60; #1;if(!ar)$fatal(1,"first RX packet denied");tick;
   ab=40; #1;if(!ar)$fatal(1,"second RX packet denied at exact limit");tick;
   av=0; if(grant_b!=100 || grant_p!=2)$fatal(1,"initial grant mismatch");
   cv=1;cb=60;tick;cv=0;
   if(grant_b!=160 || grant_p!=3)$fatal(1,"credit return not cumulative");
   av=1;ab=60;#1;if(!ar)$fatal(1,"returned byte/packet credit unavailable");tick;
   av=0;cv=1;cb=41;tick;cv=0;
   if(!err)$fatal(1,"over-consumption was not flagged");
   $display("PASS: independent cumulative byte/packet credits, exact limits, returns and overrun detection");
   $finish;
 end
endmodule
