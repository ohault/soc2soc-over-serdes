// SPDX-License-Identifier: BSD-2-Clause
// Two-lane v0 control manager. Session ID is provisioned by the caller for v0;
// deterministic peer session election is a later control-plane extension.
module bonded_control_manager #(
    parameter [63:0] LOCAL_PEER_ID = 64'd1,
    parameter [63:0] EXPECTED_PEER_ID = 64'd2,
    parameter [15:0] PROFILE_ID = 16'd1,
    parameter [15:0] MAX_PAYLOAD = 16'd4096,
    parameter [63:0] INITIAL_SESSION_ID = 64'h1,
    parameter [31:0] RESTART_BACKOFF_CYCLES = 32'd64,
    parameter [31:0] PING_INTERVAL_CYCLES = 32'd100000000,
    parameter [31:0] PONG_TIMEOUT_CYCLES = 32'd300000000,
    // HELLO/READY are resent at this interval until the session is
    // established: a frame sent before the peer's receiver is up is lost.
    parameter [31:0] HELLO_RETRY_CYCLES = 32'd1000000
) (
    input wire clk,
    input wire rst,
    input wire [1:0] lane_up,

    input wire ctrl_rx_valid,
    output wire ctrl_rx_ready,
    input wire [207:0] ctrl_rx_body,
    input wire [5:0] ctrl_rx_body_length,
    input wire ctrl_rx_lane,
    input wire [63:0] ctrl_rx_session_id,

    output wire ctrl_tx_valid,
    input wire ctrl_tx_ready,
    output reg [207:0] ctrl_tx_body,
    output reg [5:0] ctrl_tx_body_length,

    input wire [63:0] local_byte_limit,
    input wire [31:0] local_packet_limit,
    output reg [63:0] remote_byte_limit,
    output reg [31:0] remote_packet_limit,

    output reg session_established,
    output reg fault,
    output reg [63:0] active_session_id,
    output reg session_changed,
    output reg session_initiated
);
    reg [1:0] hello_seen,ready_seen;
    reg was_all_lanes_up;
    reg hello_sent,ready_sent,ready_queued;
    reg tx_pending;
    reg [63:0] last_advertised_bytes;
    reg [31:0] last_advertised_packets;
    reg pong_pending,pong_queued;
    reg [31:0] pong_nonce;
    reg ping_pending,ping_queued;
    reg [31:0] ping_nonce,next_ping_nonce;
    reg [31:0] ping_age,ping_interval_age;
    reg [31:0] ping_sent_nonce;
    reg [63:0] highest_peer_session_id;
    reg restart_pending;
    reg [31:0] restart_age;
    reg [31:0] hello_retry_age;
    wire tx_handshake = tx_pending && ctrl_tx_ready;
    wire rx_handshake = ctrl_rx_valid && ctrl_rx_ready;
    wire [7:0] rx_opcode = ctrl_rx_body[207:200];
    wire [63:0] rx_peer_id = ctrl_rx_body[199:136];
    wire [7:0] rx_lane_count = ctrl_rx_body[135:128];
    wire [15:0] rx_profile = ctrl_rx_body[127:112];
    wire [15:0] rx_max_payload = ctrl_rx_body[111:96];
    wire [63:0] rx_hello_bytes = ctrl_rx_body[95:32];
    wire [31:0] rx_hello_packets = ctrl_rx_body[31:0];
    wire [63:0] rx_credit_bytes = ctrl_rx_body[199:136];
    wire [31:0] rx_credit_packets = ctrl_rx_body[135:104];
    wire [31:0] rx_nonce = ctrl_rx_body[199:168];
    wire [1:0] rx_lane_mask = ctrl_rx_lane ? 2'b10 : 2'b01;
    wire all_lanes_up = &lane_up;

    // A new epoch invalidates any outstanding heartbeat from the previous
    // session. Suppress its timeout on the same clock edge as adoption or
    // local epoch initiation, otherwise the old ping_pending value can
    // reassert fault after the transition has cleared it.
    wire peer_epoch_adopt = rx_handshake && ctrl_rx_session_id!=active_session_id &&
        rx_opcode==8'h01 && ctrl_rx_session_id!=0 &&
        ctrl_rx_session_id>highest_peer_session_id &&
        LOCAL_PEER_ID>EXPECTED_PEER_ID && all_lanes_up &&
        ctrl_rx_body_length==26 && rx_peer_id==EXPECTED_PEER_ID &&
        rx_lane_count==2 && rx_profile==PROFILE_ID &&
        rx_max_payload==MAX_PAYLOAD;
    wire local_epoch_restart = restart_pending && all_lanes_up &&
        LOCAL_PEER_ID<EXPECTED_PEER_ID &&
        restart_age>=RESTART_BACKOFF_CYCLES &&
        active_session_id!=64'hffff_ffff_ffff_ffff;
    wire epoch_transition = peer_epoch_adopt || local_epoch_restart;
    assign ctrl_rx_ready = !rst;
    assign ctrl_tx_valid = tx_pending;

    initial begin
        if(INITIAL_SESSION_ID==0)
            $error("INITIAL_SESSION_ID must be non-zero");
        if(RESTART_BACKOFF_CYCLES==0)
            $error("RESTART_BACKOFF_CYCLES must be non-zero");
        if(PING_INTERVAL_CYCLES==0 || PONG_TIMEOUT_CYCLES<=PING_INTERVAL_CYCLES)
            $error("PONG timeout must exceed a non-zero PING interval");
        if(HELLO_RETRY_CYCLES==0)
            $error("HELLO_RETRY_CYCLES must be non-zero");
    end

    task automatic queue_hello;
    begin
        ctrl_tx_body <= 0;
        ctrl_tx_body[207:200] <= 8'h01;
        ctrl_tx_body[199:136] <= LOCAL_PEER_ID;
        ctrl_tx_body[135:128] <= 8'd2;
        ctrl_tx_body[127:112] <= PROFILE_ID;
        ctrl_tx_body[111:96] <= MAX_PAYLOAD;
        ctrl_tx_body[95:32] <= local_byte_limit;
        ctrl_tx_body[31:0] <= local_packet_limit;
        ctrl_tx_body_length <= 26;
        tx_pending <= 1'b1;
    end
    endtask

    task automatic queue_ready;
    begin
        ctrl_tx_body <= 0;
        ctrl_tx_body[207:200] <= 8'h02;
        ctrl_tx_body[199:136] <= LOCAL_PEER_ID;
        ctrl_tx_body[135:128] <= 8'd2;
        ctrl_tx_body[127:112] <= PROFILE_ID;
        ctrl_tx_body_length <= 12;
        tx_pending <= 1'b1;
        ready_queued <= 1'b1;
    end
    endtask

    task automatic queue_credit;
    begin
        ctrl_tx_body <= 0;
        ctrl_tx_body[207:200] <= 8'h03;
        ctrl_tx_body[199:136] <= local_byte_limit;
        ctrl_tx_body[135:104] <= local_packet_limit;
        ctrl_tx_body_length <= 13;
        tx_pending <= 1'b1;
    end
    endtask

    task automatic queue_pong(input [31:0] nonce);
    begin
        ctrl_tx_body <= 0;
        ctrl_tx_body[207:200] <= 8'h05;
        ctrl_tx_body[199:168] <= nonce;
        ctrl_tx_body_length <= 5;
        tx_pending <= 1'b1;
        pong_queued <= 1'b1;
    end
    endtask

    task automatic queue_ping;
    begin
        ctrl_tx_body <= 0;
        ctrl_tx_body[207:200] <= 8'h04;
        ctrl_tx_body[199:168] <= next_ping_nonce;
        ctrl_tx_body_length <= 5;
        tx_pending <= 1'b1;
        ping_queued <= 1'b1;
        ping_sent_nonce <= next_ping_nonce;
        ping_age <= 0;
        next_ping_nonce <= (next_ping_nonce==32'hffff_ffff) ? 32'd1 : next_ping_nonce+1'b1;
        ping_interval_age <= 0;
    end
    endtask

    always @(posedge clk) begin
        if(rst) begin
            hello_seen<=0;ready_seen<=0;was_all_lanes_up<=0;hello_sent<=0;ready_sent<=0;ready_queued<=0;
            tx_pending<=0;ctrl_tx_body<=0;ctrl_tx_body_length<=0;
            remote_byte_limit<=0;remote_packet_limit<=0;
            last_advertised_bytes<=0;last_advertised_packets<=0;
            pong_pending<=0;pong_queued<=0;pong_nonce<=0;
            ping_pending<=0;ping_queued<=0;ping_nonce<=0;next_ping_nonce<=1;
            ping_age<=0;ping_interval_age<=0;ping_sent_nonce<=0;
            session_established<=0;fault<=0;
            active_session_id<=INITIAL_SESSION_ID;highest_peer_session_id<=INITIAL_SESSION_ID;
            session_changed<=0;session_initiated<=0;restart_pending<=0;restart_age<=0;
            hello_retry_age<=0;
        end else begin
            session_changed<=1'b0;
            session_initiated<=1'b0;
            if(all_lanes_up) was_all_lanes_up<=1;
            if(was_all_lanes_up && !all_lanes_up) begin
                session_established<=0;
                fault<=1;
                tx_pending<=0;
                ping_pending<=0;ping_queued<=0;
                pong_pending<=0;pong_queued<=0;
                restart_pending<=1;
                restart_age<=0;
            end

            // Until the session is established, resend HELLO (then READY,
            // once both peer HELLOs are seen) every HELLO_RETRY_CYCLES. Both
            // are idempotent at the receiver. Later epoch transitions in this
            // block override these assignments.
            if(session_established || fault || !all_lanes_up || !hello_sent)
                hello_retry_age<=0;
            else if(hello_retry_age<HELLO_RETRY_CYCLES)
                hello_retry_age<=hello_retry_age+1'b1;
            else if(!tx_pending) begin
                hello_retry_age<=0;
                hello_sent<=0;ready_sent<=0;ready_queued<=0;
            end

            if(tx_handshake) begin
                tx_pending<=0;
                case(ctrl_tx_body[207:200])
                    8'h01: begin
                        hello_sent<=1;
                        last_advertised_bytes<=ctrl_tx_body[95:32];
                        last_advertised_packets<=ctrl_tx_body[31:0];
                    end
                    8'h02: begin
                        ready_sent<=1; ready_queued<=0;
                        if(ready_seen==2'b11 && hello_seen==2'b11 && hello_sent)
                            session_established<=1;
                    end
                    8'h03: begin
                        last_advertised_bytes<=ctrl_tx_body[199:136];
                        last_advertised_packets<=ctrl_tx_body[135:104];
                    end
                    8'h04: begin ping_interval_age<=0;ping_pending<=1;ping_queued<=0;ping_age<=0; end
                    8'h05: begin pong_pending<=0;pong_queued<=0; end
                    default: begin end
                endcase
            end

            if(rx_handshake && ctrl_rx_session_id!=active_session_id) begin
                // The higher peer adopts only a strictly newer HELLO from
                // the configured lower peer. Delayed older epochs are ignored.
                if(rx_opcode==8'h01 && ctrl_rx_session_id!=0 &&
                   ctrl_rx_session_id>highest_peer_session_id &&
                   LOCAL_PEER_ID>EXPECTED_PEER_ID && all_lanes_up &&
                   ctrl_rx_body_length==26 && rx_peer_id==EXPECTED_PEER_ID &&
                   rx_lane_count==2 && rx_profile==PROFILE_ID &&
                   rx_max_payload==MAX_PAYLOAD) begin
                    active_session_id<=ctrl_rx_session_id;
                    highest_peer_session_id<=ctrl_rx_session_id;
                    session_changed<=1'b1;
                    session_established<=1'b0;
                    fault<=1'b0;
                    hello_seen<=rx_lane_mask;
                    ready_seen<=0;
                    hello_sent<=0;ready_sent<=0;ready_queued<=0;
                    tx_pending<=0;
                    remote_byte_limit<=rx_hello_bytes;
                    remote_packet_limit<=rx_hello_packets;
                    last_advertised_bytes<=0;last_advertised_packets<=0;
                    pong_pending<=0;pong_queued<=0;
                    ping_pending<=0;ping_queued<=0;ping_age<=0;
                    ping_interval_age<=0;next_ping_nonce<=1;ping_sent_nonce<=0;
                    restart_pending<=0;restart_age<=0;
                    was_all_lanes_up<=1'b1;
                end else if(LOCAL_PEER_ID<EXPECTED_PEER_ID &&
                            rx_opcode==8'h01 && ctrl_rx_session_id<active_session_id &&
                            rx_peer_id==EXPECTED_PEER_ID && all_lanes_up && !tx_pending) begin
                    // The higher peer may have rebooted and lost its volatile
                    // epoch. Re-advertise the authoritative current epoch.
                    queue_hello();
                end
            end else if(rx_handshake && !fault) begin
                case(rx_opcode)
                    8'h01: begin
                        if(ctrl_rx_body_length!=26 || rx_peer_id!=EXPECTED_PEER_ID ||
                           rx_lane_count!=2 || rx_profile!=PROFILE_ID ||
                           rx_max_payload!=MAX_PAYLOAD) begin
                            fault<=1;session_established<=0;
                        end else begin
                            hello_seen<=hello_seen | rx_lane_mask;
                            if(rx_hello_bytes>remote_byte_limit) remote_byte_limit<=rx_hello_bytes;
                            if(rx_hello_packets>remote_packet_limit) remote_packet_limit<=rx_hello_packets;
                            // A HELLO after establishment means the peer is
                            // still retrying: our READY was lost. Resend
                            // READY only (never HELLO), so this cannot loop.
                            if(session_established && !tx_handshake) ready_sent<=1'b0;
                        end
                    end
                    8'h02: begin
                        if(ctrl_rx_body_length!=12 || rx_peer_id!=EXPECTED_PEER_ID ||
                           rx_lane_count!=2 || rx_profile!=PROFILE_ID) begin
                            fault<=1;session_established<=0;
                        end else if(!hello_seen[ctrl_rx_lane]) begin
                            // READY before this lane's HELLO: the HELLO was
                            // lost. Ignore it; the peer resends both.
                        end else begin
                            ready_seen<=ready_seen | rx_lane_mask;
                            if((ready_seen | rx_lane_mask)==2'b11 &&
                               (ready_sent || (tx_handshake && ctrl_tx_body[207:200]==8'h02)) &&
                               hello_sent && hello_seen==2'b11)
                                session_established<=1;
                        end
                    end
                    8'h03: begin
                        if(ctrl_rx_body_length!=13) begin fault<=1;session_established<=0; end
                        else begin
                            if(rx_credit_bytes>remote_byte_limit) remote_byte_limit<=rx_credit_bytes;
                            if(rx_credit_packets>remote_packet_limit) remote_packet_limit<=rx_credit_packets;
                        end
                    end
                    8'h04: begin
                        if(ctrl_rx_body_length!=5) begin fault<=1;session_established<=0; end
                        else begin pong_pending<=1;pong_nonce<=rx_nonce; end
                    end
                    8'h05: begin
                        if(ctrl_rx_body_length!=5 || !ping_pending || rx_nonce!=ping_sent_nonce) begin
                            fault<=1;session_established<=0;
                        end else begin ping_pending<=0;ping_age<=0;ping_interval_age<=0; end
                    end
                    8'h06,8'h07: begin fault<=1;session_established<=0; end
                    default: begin fault<=1;session_established<=0; end
                endcase
            end

            if(ping_pending && !epoch_transition) begin
                if(ping_age<PONG_TIMEOUT_CYCLES) ping_age<=ping_age+1'b1;
                else begin
                    fault<=1;session_established<=0;restart_pending<=1;restart_age<=0;
                    tx_pending<=0;ping_pending<=0;ping_queued<=0;
                    pong_pending<=0;pong_queued<=0;
                end
            end
            if(restart_pending && all_lanes_up && LOCAL_PEER_ID<EXPECTED_PEER_ID) begin
                if(restart_age<RESTART_BACKOFF_CYCLES) restart_age<=restart_age+1'b1;
                else if(active_session_id==64'hffff_ffff_ffff_ffff) begin
                    restart_pending<=0;fault<=1;session_established<=0;
                end else begin
                    active_session_id<=active_session_id+1'b1;
                    highest_peer_session_id<=active_session_id+1'b1;
                    session_changed<=1'b1;session_initiated<=1'b1;
                    session_established<=1'b0;fault<=1'b0;
                    hello_seen<=0;ready_seen<=0;
                    hello_sent<=0;ready_sent<=0;ready_queued<=0;tx_pending<=0;
                    remote_byte_limit<=0;remote_packet_limit<=0;
                    last_advertised_bytes<=0;last_advertised_packets<=0;
                    pong_pending<=0;pong_queued<=0;
                    ping_pending<=0;ping_queued<=0;ping_age<=0;
                    ping_interval_age<=0;next_ping_nonce<=1;ping_sent_nonce<=0;
                    restart_pending<=0;restart_age<=0;
                end
            end else if(restart_pending && !all_lanes_up) begin
                restart_age<=0;
            end
            if(session_established && !ping_pending && ping_interval_age<PING_INTERVAL_CYCLES)
                ping_interval_age<=ping_interval_age+1'b1;

            if(!fault && !tx_pending) begin
                if(all_lanes_up && !hello_sent) queue_hello();
                else if(all_lanes_up && hello_sent && hello_seen==2'b11 && !ready_sent && !ready_queued)
                    queue_ready();
                else if(pong_pending && !pong_queued) queue_pong(pong_nonce);
                else if(session_established &&
                        (local_byte_limit!=last_advertised_bytes ||
                         local_packet_limit!=last_advertised_packets)) queue_credit();
                else if(session_established && !ping_pending && !ping_queued &&
                        ping_interval_age>=PING_INTERVAL_CYCLES) queue_ping();
            end
        end
    end
endmodule
