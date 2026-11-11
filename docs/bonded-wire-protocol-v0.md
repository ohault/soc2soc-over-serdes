# Bonded SerDes transport — v0 wire protocol

Status: v0 protocol proposal with a pure-Python reference frame codec. The codec implements the byte envelope and structural validation; it is not RTL, does not implement session negotiation or control scheduling, and is not yet frozen as a hardware interoperability standard.

## 1. Scope and invariants

The v0 transport bonds a configured set of same-profile physical lanes into one ordered logical packet service.

- Complete logical packets are striped across lanes; a packet is never split across lanes.
- All frames carry a session identifier and a lane identity.
- The receiver delivers DATA payloads strictly in logical sequence order.
- Receive capacity is controlled by cumulative byte and packet credits.
- CONTROL traffic has independent queue capacity and scheduling priority over DATA.
- Loss/reset of any required lane faults the whole v0 session. There is no transparent failover or retransmission in v0.
- All multi-byte integers are unsigned and network byte order (big-endian).

This is a framed packet transport over lane services. It is not a native PCIe or USB PHY extension.

## 2. Frame envelope

Each lane carries a sequence of frames. A frame consists of a fixed 24-byte header, a type-specific body, and a 4-byte frame CRC.

| Offset | Width | Field | Meaning |
|---:|---:|---|---|
| 0 | 2 | magic | Constant `0x5342` ("SB") |
| 2 | 1 | version | Protocol version; v0 encoding uses value 1 |
| 3 | 1 | type | DATA=1, CONTROL=2 |
| 4 | 1 | flags | Must be zero in v0; unknown bits reject frame |
| 5 | 1 | lane_id | Logical lane index, 0..N-1 |
| 6 | 2 | header_length | Must be 24 in v0 |
| 8 | 8 | session_id | Session identifier, non-zero |
| 16 | 4 | frame_sequence | Per-lane frame sequence, starting at zero |
| 20 | 2 | body_length | Number of body bytes, excluding header and CRC |
| 22 | 2 | header_crc16 | CRC-16/CCITT-FALSE over bytes 0..21 |

The final four bytes are CRC-32C (Castagnoli) over the complete header including header_crc16 and the body, excluding the final CRC field. Reflected implementation parameters: polynomial 0x1EDC6F41, init/xorout 0xFFFFFFFF, reflected input/output. The transmitted CRC integer is big-endian.

The lane service must preserve frame boundaries or provide an equivalent length-delimited byte stream. It must report malformed/truncated frames and must not silently concatenate across a reset/epoch boundary.

Maximum body length is negotiated/configured out of band for the initial profile and must fit the 16-bit body_length field. The first implementation should cap DATA payloads at 4096 bytes. A DATA body contains exactly one logical packet payload; its length is body_length. A zero-length DATA packet is legal only if the logical client explicitly permits it.

## 3. DATA body and ordering

DATA body is the application-independent logical packet payload. The logical sequence number is carried in a four-byte DATA prefix:

| Offset | Width | Field |
|---:|---:|---|
| 0 | 4 | packet_sequence |
| 4 | variable | payload |

Therefore DATA body_length is 4 + payload_length. Maximum logical payload in the initial profile is 4096 bytes.

packet_sequence is a session-scoped unsigned 32-bit counter, starting at zero. The sender must not wrap it. It must stop admitting packets and establish a new session before the next sequence would wrap. The receiver's reorder window must be strictly less than 2^31; v0 uses a configurable bounded window, default 32.

The receiver rejects duplicate, stale, out-of-window, wrong-session, wrong-lane, malformed, or CRC-invalid frames. It buffers out-of-order complete packets and releases only the next expected sequence. If the missing sequence does not arrive before the configured gap timeout, it faults the session; it never skips the gap.

frame_sequence is separate from packet_sequence. It counts every DATA and CONTROL frame transmitted on a particular lane and is used for diagnostics and detection of lane-local discontinuities. It must not be used to infer logical packet order. It must not wrap within a session; re-establish the session before wrap.

## 4. CONTROL body

CONTROL frames use the common envelope. The first body byte is control_opcode, followed by opcode-specific fields. Control frames are not assigned packet_sequence values. frame_sequence still increments on the lane carrying the control frame.

| Opcode | Name | Body after opcode | Purpose |
|---:|---|---|---|
| 0x01 | HELLO | peer_id[8], lane_count[1], profile_id[2], max_payload[2], rx_bytes[8], rx_packets[4] | Announce endpoint and initial receive grant |
| 0x02 | READY | peer_id[8], lane_count[1], profile_id[2] | Confirm compatible peer/session |
| 0x03 | CREDIT | byte_limit[8], packet_limit[4] | Advertise cumulative receive limits |
| 0x04 | PING | nonce[4] | Liveness probe |
| 0x05 | PONG | nonce[4] | Liveness response |
| 0x06 | RESET | reason[2] | Abort current session |
| 0x07 | ERROR | error_code[2], detail[2] | Report protocol/configuration error |

All fields are big-endian. Exact body lengths are fixed by the table; any other length is invalid. peer_id is a configured 64-bit endpoint identity and must be unique within the connected system. profile_id identifies the agreed lane-service profile (including encoding, word width and line rate); both endpoints must agree. lane_count must match the local configured count in v0. Each physical lane is validated by exchanging HELLO/READY on that lane with the same peer_id and session_id; the lane_id in the envelope identifies the local logical lane index. The peer's lane_id observed on that physical connection establishes the mapping. Do not assume SFP connector numbers match across boards.

The endpoint generating a new session chooses a non-zero 64-bit session_id. The peer echoes it in its response. Session IDs must not be reused during the lifetime of either endpoint; a persistent monotonic counter or sufficiently strong random value is suitable. A session identifier is not an authentication mechanism.

## 5. Session establishment

1. Each lane adapter reports local physical link-up and a fresh lane epoch.
2. Each endpoint sends HELLO on every locally up configured lane, carrying its peer_id, lane_count, profile_id, maximum payload and initial RX credit grant.
3. The remote endpoint validates session_id, peer_id, profile, lane count and limits. It records the peer lane identity observed on each physical connection.
4. Each endpoint sends READY on every validated lane.
5. The aggregate session becomes ready only after all configured lanes have completed the exchange and the observed lane mapping is one-to-one.
6. Initial credits are the HELLO rx_bytes/rx_packets values. No DATA is admitted before the peer's initial grant is known and all lanes are ready.

A repeated HELLO/READY for the same active session and lane is idempotent. A different session_id, changed peer identity, duplicate peer-lane mapping, or incompatible profile faults/restarts establishment. A lane reset invalidates the entire v0 session; frames from the old session are discarded.

## 6. Cumulative receive credits

The receiver advertises two independent cumulative limits:

- byte_limit: maximum total DATA payload bytes accepted during the session;
- packet_limit: maximum total DATA packets accepted during the session.

The sender reserves payload bytes and one packet at logical enqueue, before assigning packet_sequence. It may admit a packet only if both cumulative limits cover the new reservation. Credits are returned only after the application consumes the complete in-order packet. The receiver's next limits equal initial capacity plus cumulative released bytes/packets.

Credit counters are unsigned 64-bit bytes and unsigned 32-bit packets. A session must be restarted before either counter would wrap. Limits are monotonic independently: when an update arrives, merge byte and packet limits separately using max(current, received). This makes delayed/reordered snapshots harmless. A lower value never revokes already granted capacity. The receiver faults the session if the peer exceeds either advertised limit.

The CREDIT opcode is sent on a healthy lane. It is repeated periodically until superseded by a newer cumulative update, and immediately after a credit return changes either limit. Repetition is safe because updates are cumulative and idempotent. A sender that has exhausted credits must still be able to receive CREDIT frames; it must never gate RX/control processing on DATA TX availability.

## 7. Control-plane scheduling and deadlock avoidance

Each lane adapter/bonding endpoint must provide physically/logically reserved CONTROL queue capacity separate from DATA queues. At minimum, one maximum-sized CONTROL frame per lane must be enqueueable even when every DATA queue is full.

Scheduling rules:

1. CONTROL has strict priority over DATA at each lane's frame boundary.
2. A CONTROL frame already being transmitted is not preempted; DATA frames are not interleaved.
3. CREDIT, RESET, ERROR, HELLO/READY and PING/PONG use the reserved CONTROL path.
4. DATA scheduling uses round-robin among lanes with DATA capacity and remote credits.
5. CONTROL RX is always serviced independently of application RX backpressure.
6. If a control queue is full, coalesce replaceable state updates (especially CREDIT) to the newest cumulative values; never discard RESET/ERROR silently.
7. If control delivery cannot be confirmed by the liveness timeout, fault/restart the session. v0 does not retransmit DATA.

This prevents the circular wait in which a sender cannot transmit a credit update because its DATA queue is full while the peer is waiting for that update to release capacity.

## 8. Timers and liveness

Timers are measured in the bonding-core clock domain and are configuration parameters, not wire units. The initial implementation must expose:
- HELLO/READY establishment timeout;
- PING interval;
- PONG/liveness timeout;
- missing packet gap timeout;
- lane-reset/session restart timeout.

PING/PONG is diagnostic/liveness supervision, not a delivery acknowledgement. The initial values should be selected in simulation and then adjusted to the physical lane latency; do not bake arbitrary cycle counts into the wire protocol.

## 9. Error handling

- Invalid magic/version/type/header length/header CRC/frame CRC/body length/opcode/body length: reject frame and increment a diagnostic counter.
- Wrong session_id or stale lane epoch: discard frame and count it as stale; do not inject its payload.
- Credit overrun, duplicate lane mapping, incompatible peer/profile, or unrecoverable sequence gap: fault session and send RESET/ERROR if the control path remains usable.
- Lane-down or lane-epoch change: immediately invalidate the aggregate session and flush lane and bonding queues.
- v0 does not retransmit lost/corrupt frames. A detected sequence gap eventually faults the session.

## 10. Implementation sequence

1. Implemented: pure-Python frame envelope, DATA prefix, CONTROL opcode length validation, CRC-16/CCITT-FALSE and CRC-32C in `soc2soc/bonding/wire.py`.
2. Implemented: a framework-neutral control-plane reference model in `soc2soc/bonding/control.py`, including per-lane HELLO/READY negotiation, crossed-lane mapping, dedicated CONTROL queues, CONTROL-before-DATA scheduling, CREDIT coalescing, monotonic remote-credit merging, PING/PONG response and lane-loss fail-stop.
3. Implemented: an integrated two-endpoint software simulation in `test/test_bonding_integration.py`. It exchanges HELLO/READY over crossed lanes, sends DATA through the wire codec, deliberately reorders arrivals across lanes, returns cumulative credits after application consumption, and checks lane-loss invalidation.
4. Corrected the control-plane model to reject post-negotiation CONTROL frames arriving with the wrong peer-lane identity and to make duplicate HELLO handling idempotent.
5. Added an explicit regression correction for coalesced CREDIT queue depth. The Python tests have not yet been executed; passing status is not claimed.
6. CI: the reference-model workflow passed the 43-test suite, including the seeded 120-packet latency/backpressure simulation (run 43069711240).\n7. Implemented: deterministic negotiation timeout and PING/PONG heartbeat supervision in `BondedControlPlane.tick(now_cycles)`. The caller supplies monotonically increasing bonding-clock cycles; incomplete negotiation and unanswered heartbeat probes fault the whole v0 session.\n8. Added tests for negotiation timeout, successful PING/PONG, missing PONG and wrong-nonce PONG. The new tests are awaiting CI execution.\n9. Implemented: `BondedControlPlane.restart(new_session_id, now_cycles)` clears old queues, lane mappings, frame counters, credits and heartbeat state, then starts HELLO negotiation under a fresh session identifier. The endpoint rejects reuse of identifiers it has already used locally. Frames carrying a previous session identifier are discarded before control-opcode processing.\n10. Added tests for crossed-lane restart, stale old-session frame rejection, session-ID reuse rejection and restart preconditions. CI status for these tests is pending.\n11. Next: define how a single endpoint proposes a fresh session identifier and how its peer adopts it; then test delayed/duplicated control messages and simultaneous/asymmetric restart before freezing the RTL contract.

## 11. Explicit non-goals

This wire protocol does not provide cryptographic authentication, encryption, retransmission/replay of DATA, degraded lane operation, heterogeneous lane rates, native PCIe/USB PHY extension, or guaranteed lossless recovery after physical lane failure.
