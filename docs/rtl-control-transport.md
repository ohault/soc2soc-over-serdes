# v0 RTL CONTROL transmit path

The CONTROL transmit path is a separate, framework-neutral datapath. It does
not depend on LiteX, Migen, a board model or a particular FPGA family.

## Composition per physical lane

`bonded_lane_tx_mux` composes:

1. `bonded_control_queue`: four-entry default message FIFO, reserved only for
   CONTROL bodies.
2. `bonded_control_frame_tx`: v0 CONTROL envelope and CRC encoder.
3. `bonded_wire_tx_lane`: v0 DATA envelope and CRC encoder.
4. `bonded_lane_frame_arbiter`: frame-atomic CONTROL-priority byte-stream mux.

The external CONTROL producer sees ready/valid backpressure from the reserved
queue. DATA cannot consume this queue's storage.

## Arbitration semantics

CONTROL wins whenever a new frame is eligible at an idle boundary. Once an
encoder presents SOP, the arbiter locks that source even if the downstream
physical stream is stalled. It does not interrupt a frame already in progress.
A CONTROL message arriving during DATA therefore waits until the DATA EOP has
been accepted.

This lock-on-SOP rule is important: it makes frame selection and wire sequence
allocation deterministic even when the physical link applies backpressure.

## Shared per-lane frame sequence

v0 frame sequence numbers are shared by DATA and CONTROL on each physical
lane. They are not independent counters per frame type.

The lane mux owns one sequence allocator. Both encoders capture its current
value when they launch a frame. The allocator advances only when the final
byte (EOP) is accepted by the physical output. The two encoder status outputs
expose this shared next sequence value.

The standalone DATA-only two-lane TX path continues to use one DATA encoder
counter per lane.

## CONTROL decoder

`bonded_control_frame_rx` is independent of the DATA frame decoder. It
validates magic, version, CONTROL type, lane ID, session ID, per-lane sequence,
header CRC-16, frame CRC-32C, opcode and exact body length. It holds a decoded
body and length until the control-plane consumer accepts the ready/valid
handshake.

The two-lane RX integration demultiplexes DATA and CONTROL frames after the
recovered-clock input. Each lane has its own CONTROL decoder. Validated
messages cross into the bonding clock through a dedicated asynchronous FIFO;
a round-robin merger preserves the physical ingress-lane index for the
control-plane consumer. DATA and CONTROL decoders share one expected frame
sequence counter per physical lane.

The full-duplex endpoint exposes a CONTROL transmit ready/valid interface
(`ctrl_tx_valid/ready/body/body_length`) and a CONTROL receive ready/valid
interface (`ctrl_rx_valid/ready/body/body_length/lane`). TX broadcasts each
message atomically to both lane-specific asynchronous queues. The per-lane
frame mux then gives CONTROL priority at frame boundaries.

The v0 body lengths match the Python reference model:

| Opcode | Message | Body bytes |
|---:|---|---:|
| 0x01 | HELLO | 26 |
| 0x02 | READY | 12 |
| 0x03 | CREDIT | 13 |
| 0x04 / 0x05 | PING / PONG | 5 |
| 0x06 | RESET | 3 |
| 0x07 | ERROR | 5 |

## Verification

Dedicated regressions cover:

- CONTROL frame encoding, CRCs and CREDIT field byte order.
- CONTROL encoder/decoder loopback.
- CONTROL priority when both frame types are waiting.
- Frame atomicity when CONTROL arrives during an active DATA frame.
- Reserved CONTROL queue capacity, ordering and backpressure.
- Shared frame sequence allocation across DATA and CONTROL.

These tests are included in `.github/workflows/bonding-tests.yml`. A successful
CI result has not yet been observed for the current branch revision.

## Remaining work before hardware validation

- Connect decoded CONTROL messages to the RTL session manager and credit
  manager.
- Generate HELLO/READY, CREDIT and heartbeat messages automatically.
- Add CREDIT coalescing before queue insertion.
- Define reset/error propagation and timeout policy in RTL.
- Connect decoded CONTROL messages to the RTL session manager and credit manager.
- Add two-endpoint tests that exchange HELLO/READY and CREDIT over the physical stream.
- Test two complete endpoints with no out-of-band credit wiring.
- Run all Python and RTL regressions and close any failures before board work.

The current implementation is a per-lane building block, not yet a complete
automatic RTL control plane or a hardware-validated interconnect.
