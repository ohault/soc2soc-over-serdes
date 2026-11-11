# Receiver-side cumulative credit accounting

The receive path now accounts for verified DATA packets at the reorder-buffer
ownership boundary and returns credit when the application consumes a packet.

## Admission event

`bonded_packet_rx` emits a one-cycle `packet_accept_valid` event only when
the complete packet has been assembled in a reorder slot. Its
`packet_accept_bytes` value is the stored payload length. Partial packets,
malformed frames and CRC-failed frames do not generate this event.

The receiver credit manager increments independent cumulative accepted-byte
and accepted-packet counters. The initial grant is sized to the reorder store:
`REORDER_WINDOW * MAX_PACKET_BYTES` bytes and `REORDER_WINDOW` packets.
This matches the physical storage bound, since each reorder slot can hold at
most one packet of `MAX_PACKET_BYTES`.

## Consumption and credit return

`packet_consume_valid` is asserted on the handshake of the final output byte
(`out_valid && out_ready && out_eop`). The associated stored packet length is
added to the cumulative consumed-byte count and the consumed-packet count is
incremented. The peer-visible limits are:

- `local_byte_limit = initial_byte_grant + consumed_bytes`
- `local_packet_limit = initial_packet_grant + consumed_packets`

The two counters are independent and monotonic. The manager handles a packet
admission and its consumption being accounted on the same clock edge, which
can occur for a short packet when the application is always ready.

## Endpoint interface

`bonded_two_lane_endpoint` exposes `local_byte_limit`,
`local_packet_limit` and `rx_credit_error`. The system control plane must
advertise these absolute cumulative limits to the peer in CREDIT frames and
drive the peer's limits into `remote_byte_limit` and
`remote_packet_limit` at the TX side. Updates must be merged monotonically,
independently for bytes and packets.

## Safety and remaining scope

The reorder store is statically bounded by its window and maximum packet size.
A peer that exceeds its advertised credit is flagged by `rx_credit_error`;
the packet collector also rejects sequence numbers outside the reorder window.
This RTL revision reports a credit violation after a complete packet has
entered the reorder store; it does not yet provide an early per-packet
credit-reservation handshake into the lane decoders.

The RTL CONTROL frame scheduler/encoder and automatic CREDIT message exchange
are not implemented yet. The exposed grant outputs are the hardware/software
integration point for that future control path. Until then, a testbench or
external control adapter must connect the peer grant signals.

The current empty-packet representation uses a one-byte zero marker in the
byte-stream packet collector. Consequently, credit accounting counts that
marker as one stored byte; a future explicit zero-length packet metadata path
should remove this representation ambiguity.
