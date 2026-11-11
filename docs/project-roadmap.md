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
| RTL DATA framing and packet streams | Implemented; regression status unconfirmed | Packet TX/RX, CRC, ordering and reassembly |
| Two-lane TX/RX integration | Integrated; regression status unconfirmed | Current RTL integration is two lanes |
| CDC and width adaptation | Implemented; regression status unconfirmed | Common bonding clock and per-lane asynchronous FIFOs |
| Cumulative flow control | Partially integrated | TX reservation and RX accounting; receiver reports post-admission overrun |
| RTL CONTROL frame TX/RX | Implemented as building blocks | Dedicated queues, frame-boundary priority, raw frame decode |
| RTL control manager | Implemented as v0 manager | HELLO/READY, CREDIT, PING/PONG, lane fault reporting |
| Autonomous two-lane node | Composed | No externally forced session-active signal |
| Raw physical byte-stream boundary | Implemented at 8-bit interface | RX elastic FIFO, adapter overrun input and header-CRC-checked SOP/EOP reconstruction |
| Generic 8b/10b byte adapter | Implemented; regression added | 2/4 symbols per PHY word, comma/empty markers, byte FIFO |
| Parallel 8b/10b word adapter | Implemented as standalone prototype; regression added | Multi-byte words, SOP comma, keep masks, RX buffering; not yet integrated with node |
| Board-specific transceiver adapters | Not started | Requires vendor PHY primitive, reference clock and line-rate decisions |
| PCIe / USB 3.x adapters | Future work | Must preserve each protocol's own ordering and flow-control rules |

## Current top-level RTL

- `rtl/bonded_two_lane_node.sv`: autonomous node wrapper.
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
4. The physical node boundary is currently one byte per lane clock. The board adapter must provide buffering and assert the sticky
`laneN_rx_overflow` input if it loses recovered bytes before they reach the
node; this indication is synchronized into the bonding clock and drops the
session. The
   transceiver user-side width and achievable line rate have not been validated.
   A wide/parallel framer and PHY gearbox may be required for high-rate SFP+.
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

**The latest GitHub status query for commit `262de29f326fb9c36badf708fd1b2347bd4e3bbc` returned no check runs/statuses, and no pull-request workflow runs were returned.** Therefore these tests are added but must not yet be described as passing. The next
software gate is to obtain a successful CI run and fix every compile or
simulation failure before connecting physical boards.

The autonomous two-node test sends only 8-bit bytes across its virtual links;
it does not transmit SOP/EOP sidebands over the link.

## Next engineering steps

1. Obtain and review CI results for the current branch.
2. Extend two-node simulation to exercise repeated packets, both-lane
   utilization, backpressure, cumulative CREDIT updates, heartbeat timeout,
   and session reset during a frame.
3. Implement RTL lane-map discovery and deterministic session-ID election,
   then add automatic recovery after a lane fault.
4. Integrate the parallel 8b/10b word adapter with a multi-byte wire TX/RX
   framing path and run a parallel two-node regression. The existing one-byte
   adapter remains the conservative hardware bring-up path, not full
   transceiver bandwidth.
5. Implement the first board-specific SERDES adapter, then validate the same
   bonding core on the second FPGA board.
6. Only after the generic transport is stable, add PCIe and USB protocol
   adapters as separate layers.
