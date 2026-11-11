# Project roadmap — bonded multi-lane interconnect

## Objective

A board-agnostic, SoC-independent FPGA interconnect that bonds multiple
physical SerDes byte lanes into one reliable logical packet transport. LiteX
is an integration option, not a dependency of the bonding core.

## Current status

| Work package | Status | Notes |
|---|---|---|
| Architecture and v0 wire protocol | Implemented in reference model | DATA/CONTROL envelope, CRCs, sequence spaces, session concepts |
| Python control-plane reference | Implemented | HELLO/READY, CREDIT, heartbeat, lane/session supervision |
| RTL DATA framing and packet streams | Implemented; CI passing | Packet TX/RX, CRC, ordering and reassembly |
| Two-lane TX/RX integration | Integrated; CI passing | Current RTL integration is two lanes |
| CDC and width adaptation | Implemented; CI passing | Common bonding clock and per-lane asynchronous FIFOs |
| Cumulative flow control | Partially integrated | TX reservation and RX accounting; receiver reports post-admission overrun |
| RTL CONTROL frame TX/RX | Implemented as building blocks | Dedicated queues, frame-boundary priority, raw frame decode |
| RTL control manager | Implemented as v0 manager | HELLO/READY, CREDIT, PING/PONG, lane fault reporting |
| Autonomous two-lane node | Composed | No externally forced session-active signal |
| Raw physical byte-stream boundary | Implemented at 8-bit interface | RX elastic FIFO, adapter overrun input and header-CRC-checked SOP/EOP reconstruction |
| Generic 8b/10b byte adapter | Implemented; regression added | 2/4 symbols per PHY word, comma/empty markers, byte FIFO |
| Parallel 8b/10b word adapter and byte/word gearboxes | Dual-clock pipeline; standalone CI passing | Byte TX/RX framing remains intact; SOP comma, multi-byte words and independent TX/RX clocks |
| Per-lane PHY bridge | Integrated as generic RTL | TX packer, 8b/10b word adapter, RX unpacker; session-drop flushing |
| Two-lane parallel-PHY node wrapper | Integrated; end-to-end regression added, CI pending | Connects the unchanged byte-oriented node to two independent multi-byte PHY lanes |
| Board-specific transceiver adapters | Not started | Requires vendor PHY primitive, reference clock and line-rate decisions |
| PCIe / USB 3.x adapters | Future work | Must preserve each protocol's own ordering and flow-control rules |

## Current top-level RTL

- `rtl/bonded_two_lane_node.sv`: autonomous byte-oriented node wrapper.
- `rtl/bonded_two_lane_phy_word_node.sv`: parallel 8b/10b two-lane wrapper.
- `rtl/bonded_lane_phy_word_bridge.sv`: per-lane TX/RX clock-domain PHY bridge.
- `rtl/bonded_control_manager.sv`: v0 session and credit manager.
- `rtl/bonded_two_lane_endpoint.sv`: lower-level endpoint with external control ports.
- `rtl/bonded_wire_rx_framer.sv`: reconstructs frame boundaries from raw bytes.
- `rtl/bonded_sync_byte_fifo.sv`: per-lane RX elastic buffering.
- `docs/physical-byte-stream-interface.md`: contract for a board PHY adapter.
- `docs/rtl-control-transport.md`: RTL control architecture and limitations.

## Important v0 limitations

1. Both peers must be configured with the same non-zero session ID.
2. The RTL control manager currently assumes direct lane-index mapping. Crossed
   SFP/DAC cable discovery and deterministic session-ID election are not yet
   implemented in RTL.
3. A control fault is sticky; automatic restart/re-negotiation after lane
   recovery is not yet implemented.
4. The original `bonded_two_lane_node` byte-stream boundary remains available
   as the reference path. `bonded_two_lane_phy_word_node` adds a four-symbol
   parallel PHY boundary, but the board-specific transceiver user-side width,
   clocking, and achievable line rate have not been validated. The adapter
   fault outputs are sticky and invalidate the session on recovered-byte loss,
   symbol errors or gearbox errors.
5. The RX framer validates the header CRC before trusting frame length and can
   rescan false prefixes. Uncorrectable byte loss inside a frame must still be
   surfaced by the PHY adapter as a lane/session error.
6. The RTL flow-control violation is reported after a complete packet has
   entered reorder storage. Early admission reservation remains a hardening item.

## Verification gate before hardware

The raw-byte framer regression now explicitly stalls its consumer during
header replay and body forwarding, checking that VALID and DATA remain stable
until READY. This test has been added to the CI workflow; it has not yet been
observed passing.

The workflow `.github/workflows/bonding-tests.yml` now contains dedicated
regressions for the control encoder/decoder, queueing, frame arbitration,
receiver credits, raw-byte framing, session-abort recovery, and an autonomous
two-node test with unrelated lane and bonding clocks.

**Verified CI baseline for the integrated parallel-PHY path:** GitHub Actions run
[43113941368](https://github.com/ohault/soc2soc-over-serdes/actions/runs/43113941368)
completed successfully for commit
`2d15cbb75eda4beb7e78b9fc7c00948c9259658d`. Both jobs passed: the Python
reference-model tests and the RTL simulation suite. The RTL job explicitly
passed the standalone PHY word adapter, byte/word gearbox, per-lane bridge CDC
regression and the end-to-end two-node parallel-PHY DATA/CONTROL regression.
This is a digital simulation result only; it does not establish FPGA synthesis,
timing closure, transceiver lock, signal integrity or hardware interoperability.

The original autonomous two-node regression sends 8-bit bytes across its
virtual links. The end-to-end regression instantiates the parallel-PHY node wrapper on both
ends and transports DATA and CONTROL byte streams as multi-byte 8b/10b words
through independent dual-clock FIFOs. It passed in CI run 43113941368.

## Next engineering steps

1. Obtain and review CI results for the current branch.
2. Extend two-node simulation to exercise repeated packets, both-lane
   utilization, backpressure, cumulative CREDIT updates, heartbeat timeout,
   and session reset during a frame.
3. Implement RTL lane-map discovery and deterministic session-ID election,
   then add automatic recovery after a lane fault.
4. Obtain a successful CI run for the new two-node parallel-PHY regression,
   then extend it with backpressure, longer/random packet sizes, lane skew,
   symbol errors, session drops and recovery. The existing one-byte adapter
   remains the conservative hardware bring-up path.
5. Implement the first board-specific SERDES adapter, then validate the same
   bonding core on the second FPGA board.
6. Only after the generic transport is stable, add PCIe and USB protocol
   adapters as separate layers.
