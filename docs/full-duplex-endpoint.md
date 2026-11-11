# Full-duplex bonded endpoint

`bonded_two_lane_endpoint` composes the two-lane TX and RX paths into one
board- and SoC-neutral full-duplex endpoint. The TX and RX directions have
independent clocks; each direction has two lane clocks, for four independent
physical lane clock domains in total.

## Session boundary and reset policy

The endpoint does not negotiate sessions itself. A higher-level control-plane
implementation supplies:

- `session_established`: asserted only after peer/session negotiation succeeds;
- `tx_session_id`: the non-zero session identifier to place in transmitted
  DATA frames;
- `rx_expected_session_id`: the non-zero peer session identifier expected
  in received DATA frames.

All four lane directions participate in one session. If any TX or RX lane
reset asserts, `bonded_session_gate` asynchronously drops its common
readiness synchronizer. The endpoint then deasserts `session_active` and
asserts the datapath reset for **both** TX and RX. This flushes packet
collection, reorder slots, frame sequence state and both sides of every
asynchronous FIFO. The gate waits for two bonding-clock edges after all four
lane resets and the bond reset are released. The external controller must
then re-establish the session before traffic is accepted.

This is intentionally a whole-session reset policy. It does not yet support
continuing on one surviving lane, lane-local rejoin, retransmission or
sequence continuity across a lane reset.

## Interfaces

The application TX interface accepts complete packets using ready/valid,
SOP/EOP and KEEP. The application RX interface emits ordered payload bytes
with SOP/EOP and the global packet sequence. Each physical lane has independent
TX and RX byte-stream ready/valid interfaces.

The endpoint remains independent of LiteX, Migen, FPGA vendor primitives and
board models. Board adapters supply clocks, resets and the physical
transceiver byte streams.

## Verification scope

`tb_bonded_two_lane_endpoint` connects two endpoints in both directions
through four independent asynchronous lane FIFOs. It checks bidirectional
packet delivery and CRC-validated wire framing with unrelated clock domains.
It also drops one physical direction (endpoint A TX lane 0 / endpoint B RX
lane 0), verifies that both endpoints become inactive, verifies that reset
release alone does not reactivate the old session, and then checks explicit
session re-arming. This is a digital integration test, not a PHY,
signal-integrity or hardware resource validation.
