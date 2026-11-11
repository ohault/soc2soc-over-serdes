# Two-lane end-to-end transmit integration

`bonded_two_lane_tx` connects the packet-level scheduler to two independent
physical lane byte streams:

1. The common-clock application interface accepts a packet with DATA/KEEP/SOP/EOP.
2. `bonded_packet_tx` buffers a complete packet, assigns its global packet
   sequence and selects a lane round-robin. The scheduler now also exports the
   complete packet length alongside each lane beat.
3. Each lane's beat, KEEP, SOP/EOP, packet sequence and packet length are packed
   into an independent asynchronous FIFO.
4. Each FIFO is read in that lane's recovered clock domain.
5. `bonded_wire_tx_lane` emits the v0 DATA header, packet-sequence prefix,
   payload and CRC-32C trailer on the lane byte stream.

The module is independent of LiteX, Migen, board models and transceiver vendors.
A board-specific wrapper supplies the two lane clocks, resets and byte-stream
interfaces.

## Clocking and reset

The packet scheduler and FIFO write ports use `bond_clk`. Each FIFO read port
and wire encoder use its corresponding lane clock. Each lane FIFO's write and
read resets are asserted together using `bond_rst_n && laneN_rst_n`; assertion
is asynchronous and release is synchronized independently in each clock
domain. The system must keep the application traffic disabled until all
participating domains have exited reset.

## Verification

`tb_bonded_two_lane_tx` uses three unrelated clocks and connects each encoded
lane directly to its matching v0 wire decoder. It sends two short packets
through the common application interface. The first packet is assigned to
lane 0 with global sequence 0; the second is assigned to lane 1 with sequence
1. The decoders validate the session, lane identifier, header CRC and frame
CRC, then the test checks the decoded payload bytes and sequence values.

This verifies scheduler -> async FIFO -> wire encoder -> wire decoder on both
lanes. It does not yet verify a physical SerDes/PCS, clock recovery, CONTROL
frames, credit-based flow control, retransmission, lane-loss handling or
full-duplex session supervision. The scheduler buffers one complete packet
before sending it and serves one packet at a time; packet-level striping across
both lanes and multi-packet concurrency are future optimizations.
