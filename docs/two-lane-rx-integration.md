# Two-lane end-to-end receive integration

`bonded_two_lane_rx` composes the existing board-neutral receive building
blocks into a complete two-lane logical receive path:

1. Each lane's recovered clock drives its own `bonded_wire_rx_lane` decoder.
2. The decoder validates the complete DATA frame before emitting payload.
3. Payload byte, SOP, EOP and global packet sequence are packed into a 42-bit
   FIFO word.
4. Each lane has an independent asynchronous FIFO crossing into `bond_clk`.
5. `bonded_packet_rx` arbitrates between the two common-clock FIFO outputs,
   buffers packets in its bounded reorder window, and delivers the global
   packet sequence in order.

The wrapper is independent of LiteX, Migen and any FPGA board family. A board
adapter need only provide the recovered lane clocks, reset signals, and
byte-stream transceiver interfaces.

## Reset and session assumptions

The lane decoder and its FIFO write side are reset together for each lane.
The FIFO read side uses the same lane reset combined with `bond_rst_n`, so a
lane reset flushes both sides of that lane's FIFO. Reset assertion is
asynchronous; FIFO reset release is synchronized independently in each clock
domain. The system-level reset/session manager must coordinate reset and
prevent traffic until both sides have exited reset.

This wrapper assumes that the peer has already established the same non-zero
session ID at both decoders. It does not implement HELLO/READY negotiation,
heartbeat, timeout, lane failure policy or automatic rejoin. A lane reset
clears that lane's decoder frame sequence; the session supervisor must decide
whether to restart the whole bonded session before allowing traffic again.

## Verification

`tb_bonded_two_lane_rx` drives two independent lane clocks and a third
bonding clock. It sends valid Python-codec-compatible DATA frames, with packet
sequence 1 arriving first on lane 1 and sequence 0 arriving later on lane 0.
It checks that sequence 1 is not exposed early, then verifies payload ordering,
SOP/EOP, and output stability while the application applies backpressure.

The regression is an end-to-end simulation of the byte-stream RX decoders,
asynchronous FIFO crossings and packet reorder stage. It does not yet include
the physical transceiver/PCS, gearbox, clock recovery, CONTROL frames, credit
flow control, or lane-loss recovery.
