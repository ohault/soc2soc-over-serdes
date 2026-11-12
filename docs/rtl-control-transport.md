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

The autonomous node wrapper also includes the physical byte-stream boundary:
`bonded_sync_byte_fifo` absorbs non-stallable PHY receive bytes and
`bonded_wire_rx_framer` reconstructs SOP/EOP from the v0 header and validates
header CRC-16 before trusting the body length. The two-node simulation sends
only raw 8-bit bytes across its virtual cables; SOP/EOP are not carried over
the link. See `docs/physical-byte-stream-interface.md`.

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
- HELLO/READY negotiation, per-lane reception and cumulative credits.
- PING/PONG timeout, stale-heartbeat clearing and session re-arm.
- Crossed lane mapping and duplicate remote lane-ID rejection.
- Two-node full-duplex PHY-word transport, application backpressure,
  asymmetric lane loss, session-flush recovery and malformed-PHY-symbol faults.

The Python and RTL jobs passed in GitHub Actions run
[43178198151](https://github.com/ohault/soc2soc-over-serdes/actions/runs/43178198151).
The payload-RAM candidate has a separate passing 8/16/32-bit regression and
27-case reference-versus-RAM differential matrix in run
[43175183427](https://github.com/ohault/soc2soc-over-serdes/actions/runs/43175183427).
The Acorn LiteX target also elaborated at 2.5 and 5.0 Gb/s in run 43178198151.
A generated-Verilog primitive-count check is now being added to the Acorn job;
it is not a Vivado synthesis or timing check.

## RTL control manager and autonomous node

`bonded_control_manager` implements the v0 control state machine:

- HELLO transmission and per-lane HELLO reception.
- READY transmission after both lane HELLOs, and per-lane READY tracking.
- Session establishment only after the bidirectional two-lane exchange.
- Monotonic remote byte and packet grant updates from HELLO and CREDIT.
- CREDIT generation when local cumulative grants change.
- PING/PONG heartbeat and timeout detection.
- RESET/ERROR and physical-lane-down fault indication.
- Deterministic restart: the lower peer ID initiates a strictly newer runtime
  epoch after local lanes recover; the higher peer adopts that epoch.
- Stale heartbeat and queued control work are cleared when the old session
  faults, so an expired PING cannot prevent re-arm.

`bonded_two_lane_node` composes the manager with the full-duplex endpoint.
It exposes application packet streams, physical lane byte streams and lane-up
status. Crossed SFP cables are discovered from remote lane IDs; duplicate
remote lane IDs are rejected.

The reset architecture separates the always-available CONTROL path from the
session-scoped DATA path:

- A session drop is propagated with toggles into independent TX and recovered
  RX clock domains; no one-bond-clock reset pulse is assumed to be sampled by
  every lane clock.
- TX lane encoders and CONTROL FIFO read sides are flushed on session drop;
  the CONTROL FIFO write sides are reset at the same event.
- The raw-byte RX FIFO and frame-boundary parser are flushed per lane.
  CONTROL demultiplexers, decoders and their asynchronous message queues are
  flushed without prematurely resetting the old session's expected frame
  sequence.
- The local initiator resets its per-lane expected frame sequence when it
  actually starts the new epoch. The higher peer can accept the newer HELLO
  and rebase each lane's sequence from that frame.
- DATA is held reset or discarded until the two-lane session is established;
  HELLO/READY and other required CONTROL messages remain available.

For v0, both peers must be provisioned with the same non-zero initial session
seed at cold boot. Runtime epochs are volatile; independent cold boots do not
yet have persistent monotonic epoch storage.

## Remaining work before hardware validation

1. Complete the generated-Verilog structural smoke check for one shared
   `GTPE2_COMMON` and two `GTPE2_CHANNEL` instances at both Acorn line rates.
2. Run Vivado synthesis and timing analysis; inspect QPLL, CDC constraints,
   clock/reset mapping, resource use and timing.
3. Validate the conservative one-byte-per-PHY-word profile on the Acorn boards:
   PLL lock, TX/RX initialization, PRBS, polarity, comma alignment, lane
   mapping, session recovery and bidirectional packet integrity.
4. Measure sustained throughput and long-duration backpressure on hardware.
   The current byte-wide framing and application RX path are not full-rate
   multi-byte datapaths.
5. After hardware bring-up, widen the framing, CRC, CONTROL/DATA arbitration,
   CDC, reorder/reassembly and application RX paths for aggregate throughput.
