# Packet TX scheduler RTL

`bonded_packet_tx` is the first hardware implementation of packet-level
lane distribution. It is synchronous to the bonding-core clock and has no
LiteX, Migen, board, FPGA-vendor or transceiver dependency.

## Function

- Accepts a framed logical packet on a ready/valid beat interface.
- Buffers the complete packet before selecting a lane.
- Assigns one monotonically increasing 32-bit packet sequence number per
  accepted complete packet.
- Selects lanes in round-robin order.
- Emits the packet's beats, in order, on exactly one selected lane.
- Holds the current lane beat stable while that lane is backpressured.
- Keeps `packet_error` sticky until reset for malformed SOP/EOP/KEEP framing
  or a packet exceeding the configured beat capacity.

This is packet-level distribution, not byte striping. Packets are never split
across physical lanes. A lane is selected once per packet, not once per beat.

## Deliberate boundary

The module emits payload beats plus a lane-local SOP/EOP boundary and the
packet sequence metadata. It does **not** yet encode the v0 wire frame
envelope, DATA opcode, session ID, lane ID, header CRC-16 or frame CRC-32C.
A separate wire-framer stage must add those fields before the physical lane
adapter. This separation keeps the scheduler independent of a particular
physical stream encoding.

The module currently assumes all configured lanes are eligible. Link health,
session readiness, lane availability and credit-aware scheduling are not yet
inputs to this first scheduler. A later scheduler revision must skip
unavailable lanes and must not admit a packet until local buffering and remote
cumulative byte/packet credits have been reserved.

## Parameters

- `DATA_WIDTH`: payload beat width, multiple of eight.
- `LANE_COUNT`: number of configured lanes.
- `MAX_PACKET_BYTES`: configured maximum packet size, capped at the v0
  protocol limit of 4096 bytes.

The first CI test uses two lanes and 32-bit beats. It checks round-robin
assignment, complete-packet lane affinity, sequence numbering, SOP/EOP,
partial final KEEP and output ordering.

## Known limitations

- One complete packet buffer is implemented; no concurrent packet assembly
  and transmission.
- No packet RX/reorder engine yet.
- No credit accounting, lane health selection, or retransmission.
- Sequence wrap requires a session restart; session restart integration is
  not yet implemented.
- The packet buffer is implemented as registers/arrays; target-specific RAM
  inference and timing/resource use remain to be assessed.
