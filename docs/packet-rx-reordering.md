# Multi-lane packet receive and ordering

`bonded_packet_rx` is the first RTL packet-level receive/reordering stage.
It consumes byte-stream packets from independent lane decoders after each
lane decoder has checked the v0 header, session, lane, frame sequence and CRC.

## Interface

- Each lane supplies byte data, SOP/EOP, packet sequence and ready/valid.
- The collector arbitrates among lanes and stores complete packets in a bounded
  reorder window.
- The application receives one byte stream with SOP/EOP and the global packet
  sequence. Only the packet matching `expected_packet_sequence` is exposed.
- `WINDOW_SIZE` must be a power of two and at least two. Packet sequence values
  within the active window map to slots using their low sequence bits.
- `MAX_PACKET_BYTES` is configurable up to the protocol maximum of 4096 bytes.

The implementation uses a single common clock and accepts at most one byte
across all lanes per cycle. The per-lane wire decoders and recovered-clock
asynchronous FIFOs must bring data into this common domain before this block.

## Ordering and errors

A packet may complete before an earlier packet. It remains buffered until all
preceding sequence numbers have been delivered. Duplicate, stale, out-of-window,
overlength, malformed-SOP and malformed-continuation packets set sticky
`packet_error`. Invalid packets are discarded through EOP where possible.
A missing packet stalls ordered delivery; timeout, retransmission and session
restart policy belong to the control/session supervisor, not this block.

Empty packets use the one-byte zero marker emitted by the current wire RX
adapter. The application therefore sees a one-byte SOP/EOP marker for an empty
packet in this initial interface.

## Current limitations

This is a first functional reference RTL block, not a throughput-optimized
reorder engine. It uses a simple byte-array packet store and one global input
arbiter; it does not yet infer a banked dual-port RAM, accept simultaneous
bytes from multiple lanes, provide per-lane occupancy counters, or implement
timeout/loss recovery. The current integration test deliberately delivers
packet sequence 1 before sequence 0 and verifies that application output remains
0 then 1. More extensive randomized, simultaneous-lane and boundary testing is
required before hardware integration.
