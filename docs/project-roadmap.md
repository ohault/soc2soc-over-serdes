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
| Cumulative flow control | Integrated for v0; CI passing | TX reserves whole-packet byte/packet credits including partial final KEEP; RX reports post-admission overrun |
| RTL CONTROL frame TX/RX | Implemented as building blocks | Dedicated queues, frame-boundary priority, raw frame decode |
| RTL control manager | Implemented as v0 manager | HELLO/READY, CREDIT, PING/PONG, lane fault reporting |
| Autonomous two-lane node | Integrated | Control manager owns session state and drives the byte-oriented endpoint |
| Raw physical byte-stream boundary | Implemented at 8-bit interface | RX elastic FIFO, adapter overrun input and header-CRC-checked SOP/EOP reconstruction |
| Generic 8b/10b byte adapter | Implemented; regression added | 2/4 symbols per PHY word, comma/empty markers, byte FIFO |
| Parallel 8b/10b word adapter and byte/word gearboxes | Integrated; CI passing | Multi-byte words, SOP comma, independent TX/RX clocks, backpressure, session flush and PHY fault propagation |
| Per-lane PHY bridge | Integrated as generic RTL | Independent TX/recovered-RX clocks, word packer/decoder, byte unpacker, session-drop flushing and sticky PHY faults |
| Two-lane parallel-PHY node wrapper | Integrated; full-duplex regression passing | Simultaneous traffic both ways, eight variable-length packets, both lanes, RX backpressure and malformed-symbol session invalidation |
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
- `docs/dynamic-lane-mapping.md`: remote lane-ID discovery, crossed cabling and duplicate-ID rejection.
- `docs/rtl-control-transport.md`: RTL control architecture and limitations.

## Important v0 limitations

1. Both peers must be configured with the same non-zero session ID.
2. The RTL control manager currently assumes direct lane-index mapping. Crossed
   SFP/DAC cable discovery and deterministic session-ID election are not yet
   implemented in RTL.
3. A control fault is sticky; recovery currently requires a coordinated
   physical-lane and bonding-domain reset. Automatic re-negotiation after lane
   recovery is not yet implemented.
4. The original `bonded_two_lane_node` byte-stream boundary remains available
   as the reference path. `bonded_two_lane_phy_word_node` adds a configurable two- or four-symbol
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

The raw-byte framer regression explicitly stalls its consumer during header
replay and body forwarding, checking that VALID and DATA remain stable until
READY. It passes in the current CI baseline.

The workflow `.github/workflows/bonding-tests.yml` now contains dedicated
regressions for the control encoder/decoder, queueing, frame arbitration,
receiver credits, raw-byte framing, session-abort recovery, and an autonomous
two-node test with unrelated lane and bonding clocks.

**Last explicitly verified CI baseline (not the current branch head):** GitHub Actions run
[43117263747](https://github.com/ohault/soc2soc-over-serdes/actions/runs/43117263747)
completed successfully for commit
`dc0e46f6ece177cd11c9df483a8758a7f7069970`. Both the Python reference-model
and RTL simulation jobs passed. The current branch is 27 commits ahead of that
baseline; the later session-epoch, dynamic lane-map and parallel-PHY node
changes must be rerun in GitHub Actions before they can be marked CI-verified. The end-to-end test connects two parallel-PHY
nodes through four asynchronous symbol FIFOs with unrelated TX, RX and bonding
clocks. It transfers eight variable-length packets (1, 2, 3, 4, 5, 7, 11 and
16 bytes) in one direction and a 13-byte packet simultaneously in the reverse
direction, checks both physical lanes, applies application RX backpressure,
and injects malformed 8b/10b control symbols to verify PHY-fault supervision.
The test topology is deliberately crossed: local RX0 receives remote TX1 and
local RX1 receives remote TX0. Dynamic remote lane-ID discovery allows the
HELLO/READY and DATA paths to operate with that cable arrangement. A separate
regression verifies duplicate remote lane IDs are rejected and invalidates the
session rather than silently treating the two physical paths as one lane. The node-level
tests also cover one-sided lane loss, remote PING/PONG timeout, sticky-fault
behavior, coordinated FIFO/bond reset and session re-arm; the per-lane bridge test covers stale continuation discard
without resetting the physical channel FIFO.

This is digital simulation evidence only. It does not model analogue SERDES
behavior, PLL/CDR lock, actual 8b/10b disparity/code-error indications, signal
integrity, FPGA resource utilization or timing closure.
## Next engineering steps

1. Rerun the complete Python and RTL CI suite against the current branch head;
   fix any compile, simulation or regression failures before board integration.
2. Audit the epoch-change reset boundary, especially delayed CONTROL frames,
   stale complete DATA frames, asymmetric peer reboot and cold-boot seed
   persistence. The epoch counter is volatile across power loss.
3. Implement the first board-specific SERDES wrapper, beginning with the
   Acorn GTP and LiteICLink integration while keeping vendor primitives
   outside the generic bonding RTL.
4. Synthesize and time the generic core and board wrapper, then validate
   transceiver lock, PRBS/loopback, lane skew and sustained traffic on the Acorn.
5. Port the same board-neutral core to the Tang Mega 138K Pro/Gowin PHY.
6. Only after the generic transport is stable on hardware, add PCIe and USB
   protocol adapters as separate layers. The one-byte adapter remains the
   conservative bring-up path; the parallel adapter is the performance path.
