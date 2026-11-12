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
| Parallel 8b/10b word adapter and byte/word gearboxes | Integrated prototype; sustained throughput limited | Multi-byte PHY words are decoded, but the bonded wire TX/RX framing core remains byte-wide and cannot consume full-rate multi-byte RX traffic |
| Per-lane PHY bridge | Integrated as generic RTL | Independent TX/recovered-RX clocks, word packer/decoder, byte unpacker, session-drop flushing and sticky PHY faults |
| Two-lane parallel-PHY node wrapper | Integrated RTL; regression authored, current CI unverified | Full-duplex packet tests exist, but they do not establish sustained PHY line-rate capability |
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

## Current limitations

1. Both peers need the same non-zero initial session seed for first power-up.
   Runtime session epochs are elected by peer ID, but the epoch register is
   volatile and cannot prevent rollback after independent cold boots.
2. Dynamic remote lane-ID discovery is enabled in the autonomous node and
   crossed cable mapping is covered by simulation. Duplicate remote lane IDs
   are rejected.
3. Lane loss invalidates the bonded session. When both local lanes recover,
   the lower peer-ID endpoint initiates a strictly newer epoch and the higher
   peer adopts it. In-flight application packets are not preserved.
4. The parallel-PHY wrapper is configurable for two- or four-symbol words,
   but the actual board transceiver user-side width, clocking, line rate,
   signal integrity, resource use and timing closure remain unvalidated.
5. The PHY bridge flushes stale continuation words until a fresh SOP; the
   session layer rejects complete DATA frames carrying an old epoch.
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
and RTL simulation jobs passed. The current branch is 29 commits ahead of that
baseline; the later session-epoch, dynamic lane-map and parallel-PHY node
changes must be rerun in GitHub Actions before they can be marked CI-verified. The end-to-end test at that baseline connects two byte-oriented
nodes through four asynchronous symbol FIFOs with unrelated TX, RX and bonding
clocks. It transfers eight variable-length packets (1, 2, 3, 4, 5, 7, 11 and
16 bytes) in one direction and a 13-byte packet simultaneously in the reverse
direction, checks both physical lanes, applies application RX backpressure,
and checks packet framing and flow-control behavior.
Later, unverified-on-this-baseline tests extend coverage to crossed lane mapping,
dynamic lane-ID discovery, duplicate-ID rejection, session epoch re-arm,
parallel PHY framing, malformed control-symbol supervision and stale-frame
discard without resetting the physical channel FIFO.

This is digital simulation evidence only. It does not model analogue SERDES
behavior, PLL/CDR lock, actual 8b/10b disparity/code-error indications, signal
integrity, FPGA resource utilization or timing closure.
## Next engineering steps

1. Widen the wire TX/RX framing path so CRC, frame boundaries, CONTROL/DATA
   arbitration and packet scheduling can accept and emit multiple bytes per
   lane clock. The current byte-wide core is the bottleneck and the parallel
   PHY RX gearbox will overflow under sustained full-rate input.
2. Add sustained-rate and long-duration backpressure regressions for both
   two-symbol and four-symbol PHY configurations, including overflow checks.
3. Rerun the complete Python and RTL CI suite against the current branch head;
   fix any compile, simulation or regression failures before board integration.
4. Audit the epoch-change reset boundary, delayed CONTROL frames, stale
   complete DATA frames and asymmetric peer reboot. The epoch counter is
   volatile across independent cold boots.
5. Implement the Acorn GTP/LiteICLink wrapper, keeping all vendor primitives
   outside the generic bonding RTL. The Acorn GTP's current 20-bit datapath is
   two 8b/10b symbols per user clock.
6. Synthesize and time the generic core and wrapper, then validate lock,
   PRBS/loopback, lane skew and sustained traffic on the Acorn.
7. Port the same board-neutral core to the Tang Mega 138K Pro/Gowin PHY.
8. Add PCIe and USB protocol adapters only after the generic transport is
   stable on hardware.
