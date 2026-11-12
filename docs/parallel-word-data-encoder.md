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


## Parallel-word receiver

An experimental counterpart, `bonded_wire_rx_lane_parallel`, has been added.
It accepts compact byte words with contiguous low-order KEEP masks, buffers a
complete frame, validates the v0 header CRC-16 and frame CRC-32C, checks the
session/lane/frame sequence, and only then releases payload words. It supports
the same 8-, 16- and 32-bit widths.

The receive path deliberately buffers the full frame before releasing payload,
matching the existing byte-stream receiver's integrity-before-delivery
behavior. This is a correctness-first reference implementation, not yet a
streaming/high-throughput architecture. In particular, the frame buffer and
CRC scan need synthesis review before hardware use.

A dedicated receive regression generates a valid seven-byte DATA frame and
checks the released payload and sequence metadata. CI is configured to run it
at all three widths. The parser accepts partial KEEP words before EOP because
the transmitter emits a partial final payload word followed by a separate
full-width CRC trailer.

## Remaining interoperability gates

- Cross-test byte-serial TX into parallel RX and parallel TX into byte-serial RX.
- Corrupt header, payload, CRC, lane, session and frame sequence independently.
- Exercise truncated frames, premature SOP resynchronization, overlength frames,
  output backpressure, and reset during collection/output.
- Compare parallel TX output byte-for-byte against the byte-serial TX module.
- Run Icarus regressions and inspect warnings before claiming RTL verification.
