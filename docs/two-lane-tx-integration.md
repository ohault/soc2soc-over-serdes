# Two-lane end-to-end transmit integration

`bonded_two_lane_tx` connects the common-clock application packet interface
to two independent physical lane byte streams:

1. `bonded_packet_tx` buffers a complete application packet, assigns its
   monotonically increasing global packet sequence and selects a lane
   round-robin. It exports the complete packet length with every beat.
2. Each lane's beat, KEEP, SOP/EOP, packet sequence and packet length are
   packed together into an independent asynchronous FIFO.
3. Each FIFO is written in `bond_clk` and read in that lane's clock domain.
4. The corresponding `bonded_wire_tx_lane` emits the v0 DATA header,
   packet-sequence prefix, payload and CRC-32C trailer.
5. The lane byte-stream ready/valid interface connects to the board-specific
   transceiver adapter.

The module is independent of LiteX, Migen, board models and transceiver
vendors. A board adapter supplies the clocks, resets and physical
ready/valid byte-stream interfaces.

## Scheduling and packet boundaries

Packets remain intact on one lane in this first implementation; individual
packets are not striped across both lanes. Round-robin assignment balances
packets, while the receiver's global packet sequence/reorder stage restores
application order across lane latency differences.

The scheduler buffers one complete packet at a time and bounds storage with
`MAX_PACKET_BYTES`. Each lane FIFO has an independent `FIFO_DEPTH` and
provides backpressure to the scheduler. The wire encoder checks that the
number of payload bytes emitted across all beats matches the packet length
carried with the packet.

## Clocking, reset and remaining integration work

The packet scheduler and FIFO write ports use `bond_clk`. Each FIFO read
port and wire encoder use its corresponding lane clock. Each lane FIFO's
write and read resets are asserted together using
`bond_rst_n && laneN_rst_n`; assertion is asynchronous and release is
synchronized independently in each clock domain.

A lane reset also resets that lane's wire-frame sequence. The session
supervisor must coordinate a peer/session reset before traffic resumes, or
the peer may reject the restarted per-lane frame sequence.

The current RTL provides local ready/valid backpressure. It does not yet
connect cumulative protocol byte/packet credits to the hardware scheduler.
It also does not implement retransmission, lane failover, automatic rejoin,
CONTROL-frame scheduling or full-duplex session supervision.

## Verification

`tb_bonded_two_lane_tx` uses independent bonding, lane 0 and lane 1 clocks.
It sends a six-byte, two-beat packet followed by a two-byte partial-beat
packet. It checks round-robin lane assignment, global packet sequence, packet
length propagation and decoded payload bytes. Deterministic downstream
backpressure is applied independently on both lane outputs. Each output is
connected to the matching v0 wire RX decoder, which validates the complete
frame before releasing its payload.

This is a digital simulation of scheduler -> asynchronous FIFO -> wire
encoder -> wire decoder. It is not a transceiver timing, signal-integrity or
FPGA resource validation.
