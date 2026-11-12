# Parallel-word DATA frame encoder

## Purpose

`bonded_wire_tx_lane_parallel` is an experimental, word-oriented implementation
of the v0 DATA frame transmitter. It preserves the existing wire format while
emitting a complete word per accepted output beat instead of one byte per
cycle.

It is deliberately a separate module for now. The existing byte-serial
`bonded_wire_tx_lane` remains the compatibility reference and the integrated
lane-mux implementation. Do not replace it in a node until the parallel
implementation has passed the same interoperability, backpressure, malformed
input, reset and throughput regressions.

## Interface and byte ordering

- `DATA_WIDTH` is 8, 16 or 32; `KEEP_WIDTH` must equal `DATA_WIDTH/8`.
- Byte lane zero is `out_data[7:0]`.
- Envelope fields and packet sequence are serialized in network byte order.
- Packet payload bytes retain the v0 little-endian lane order.
- Header, packet-sequence prefix and CRC trailer are emitted as full words.
- The final payload word may use a contiguous low-order KEEP mask.
- SOP marks the first header word; EOP marks the final CRC word.
- Output data and KEEP remain stable while VALID is asserted and READY is low.

The implementation uses `bonded_crc_parallel` to update CRC-32C once per
accepted output word. Header CRC-16 is calculated when a packet is admitted.
The packet's session ID and frame sequence are copied into the header at
admission, so later changes on those input signals do not alter an active frame.

## Current limitations

- The first regression exercises a 32-bit output and a one-beat payload.
- The module is not yet connected to `bonded_lane_tx_mux`.
- There is not yet a matching parallel-word RX parser.
- Multi-beat payload refill, sustained backpressure, malformed packet lengths,
  reset during a frame, and 8-/16-bit elaboration still require regression.
- No synthesis, timing, resource or physical SerDes measurements have been made.

## Next verification gates

1. Run the golden-vector regression in Icarus Verilog CI.
2. Add multi-beat and randomized backpressure tests.
3. Test all supported word widths and compare byte-for-byte with the reference
   encoder.
4. Add a parallel-word RX path and prove cross-compatibility in both directions.
5. Integrate through an explicit selectable implementation in the lane mux.
6. Measure post-synthesis throughput and timing before selecting a default.
