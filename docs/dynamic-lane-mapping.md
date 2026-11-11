# Dynamic physical lane mapping

## Why the receiver learns lane IDs

The two SFP/DAC cables are independent physical paths. A user may connect
TX0 to the peer's RX1 and TX1 to RX0. The logical transport must not assume
that local physical RX lane number equals the remote TX lane ID carried in
the wire-frame header.

The transmitter continues to label each frame with its configured TX lane ID.
The receiver learns the remote ID independently on each local physical RX
lane from the first valid CONTROL frame (normally HELLO):

1. Before learning, the per-lane CONTROL decoder accepts any lane ID while
   still validating the session ID, frame sequence, CRC and message format.
2. The receiver records the header lane ID observed on that local RX lane.
3. The DATA and subsequent CONTROL decoders on that physical RX lane require
   the learned remote lane ID.
4. A later frame carrying a different remote lane ID on the same physical
   RX lane is a sticky lane-map error.
5. Once both physical lanes have been mapped, the two remote lane IDs must be
   distinct. If they are equal, both lane error outputs assert and the node's
   session supervisor invalidates the bonded session.

The mapping ID is the remote transmitter's lane identity. It is not the
physical local RX index.

## Keep control ingress identity local

The CONTROL manager also needs to know *which local physical RX port* received
a message so it can track HELLO/READY coverage over the two local paths. This
is a separate value from the remote lane ID.

The RX implementation therefore carries two identities:

- **Remote TX lane ID:** parsed from the wire header and used for lane-map
  learning and DATA/CONTROL header validation.
- **Local ingress lane index:** assigned by the physical RX port (0 or 1) and
  carried across the control CDC FIFO to the CONTROL manager's HELLO/READY
  state machine.

Do not substitute the remote lane ID for the local ingress index. That mistake
is hidden by straight-through cabling where both numbers happen to match, but
breaks HELLO/READY negotiation when the two SFP/DAC paths are crossed.

## Reset and recovery boundary

Lane-map state is held in the recovered RX clock domains and is reset by the
CONTROL-domain reset. The current bridge drops stale continuation words until
a fresh SOP after a session drop. A fresh session epoch is still required to
reject a stale *complete* frame that begins with its own SOP after a coordinated
reset. Until that epoch is implemented, reset the physical lane FIFOs as part
of a coordinated session reinitialization.

## Regression coverage

- `rtl/tb_bonded_two_lane_phy_word_node.sv` crosses both physical paths and
  verifies full-duplex HELLO/READY and DATA traffic.
- `rtl/tb_bonded_duplicate_remote_lane_id.sv` configures a peer to advertise
  the same TX lane ID on both paths and verifies that the receiver rejects the
  mapping and invalidates the session.
