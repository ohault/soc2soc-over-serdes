# Full-duplex two-lane endpoint

`bonded_two_lane_endpoint` composes the previously tested two-lane TX and RX
paths into one reusable full-duplex endpoint. It does not assume a board,
transceiver vendor, SoC, LiteX or Migen.

## Logical interfaces

The endpoint exposes two independent application interfaces:

- TX: a common-bond-clock packet stream with DATA, KEEP, SOP and EOP.
- RX: a common-bond-clock byte stream with packet SOP/EOP and the global
  packet sequence, delivered in order.

The endpoint also exposes four physical byte-stream interfaces: TX and RX for
each of two lanes. TX and RX lane clocks are separate ports because the
transmit clock and recovered receive clock need not be related. The board
adapter is responsible for connecting these streams to the appropriate
PCS/PMA or vendor transceiver primitives.

The `bonded_session_gate` synchronizes deassertion of all four lane reset
signals into the bonding clock domain. Any lane reset assertion immediately
disables the application interfaces. Application traffic is enabled only when
the external session manager asserts `session_established` and all four lane
reset indications have been observed released through the synchronizers.
This is a reset/readiness gate, not the HELLO/READY protocol itself.

## Sessions and reset

TX and RX session IDs are independent parameters/ports. The local TX session
ID is inserted in outgoing frames; the expected peer session ID is checked by
the receive decoders. A system-level session manager must negotiate and
coordinate these values before application traffic is enabled.

This module is a datapath composition with an external session-ready input,
not a complete link manager. It does not perform HELLO/READY negotiation,
heartbeat, peer identity/election, credit exchange, lane-loss detection or
automatic rejoin. The external manager must deassert `session_established`
on any session/lane failure, coordinate reset with the peer, and assert it
again only after negotiation and all required resets are complete.

## Physical stream contract

Each lane TX port uses local ready/valid semantics toward the local PCS
adapter. Do not connect TX READY directly to a remote endpoint's RX READY
across the physical link. The PCS/PMA and board adapter must absorb the
electrical/link-layer timing and present a local transmit acceptance signal.
The receive adapter presents recovered-clock RX valid/data/SOP/EOP to the
endpoint; it must ensure the RX decoder can accept the incoming byte stream.
Protocol-level flow control/credits are the planned mechanism for controlling
the remote sender, not a combinational ready wire across the cable.

## Verification

`tb_bonded_two_lane_endpoint` instantiates two endpoints and cross-connects
both lanes in both directions. The test uses independent bonding clocks and
unrelated transmit/recovered receive clocks for all four lane directions. It
sends one application packet simultaneously in each direction and checks
decoded payload, SOP/EOP, global packet sequence and all datapath error flags.

This digital loopback verifies endpoint composition and simultaneous
bidirectional datapath operation. It does not model a physical transceiver,
PCS/PMA, elastic buffer, signal integrity, credit flow control or session
negotiation.
