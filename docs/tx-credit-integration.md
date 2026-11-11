# TX cumulative-credit integration

The two-lane TX path now gates packet completion on the peer's cumulative
byte and packet grants.

## Interface

`bonded_two_lane_tx` and `bonded_two_lane_endpoint` expose:

- `remote_byte_limit[63:0]`: cumulative payload-byte grant received from the
  peer in a CREDIT control frame (or the initial grant advertised in HELLO).
- `remote_packet_limit[31:0]`: cumulative packet grant received from the peer.

These are absolute cumulative limits, not free-space deltas. The control-plane
adapter must merge updates monotonically (independent maximum for each field)
before driving these ports.

## Reservation point

The packet scheduler reserves the complete packet's payload bytes and one
packet credit on the accepted final input beat. Until both limits permit the
reservation, the final beat is backpressured and the scheduler does not assign
a global packet sequence. This also covers a single-beat packet.

The credit manager counts only accepted reservation handshakes. Credit
exhaustion is normal ready/valid backpressure, not a sticky protocol error.
The endpoint resets the TX scheduler and its reservation counters together
when the bonded session is dropped.

## Scope and limitations

This change integrates the **sender-side** reservation path. Receiver-side
accounting still needs to be connected to the point where a complete,
CRC-validated packet is admitted to reorder storage, and credit must be
returned only after application consumption. The present RX packet collector
does not yet expose a complete-packet admission/consumption accounting
interface.

The RTL CONTROL-frame scheduler/encoder is also not yet implemented. The
existing Python control-plane reference model handles HELLO/READY, CREDIT,
PING/PONG and CONTROL priority. Until an RTL control path exists, the system
integration must supply the cumulative remote grant inputs out of band.

Control traffic must ultimately have reserved queue/bandwidth capacity
independent of DATA credits, so CREDIT, RESET and liveness messages cannot be
blocked by DATA exhaustion. This is a required next milestone, not a property
claimed by the current DATA-only RTL path.
