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
| RTL CONTROL frame TX/RX | Integrated; CI passing | Dedicated queues, frame-boundary priority, raw frame decode, epoch-scoped RX flushing |
| RTL control manager | Integrated; CI passing | HELLO/READY, CREDIT, PING/PONG, stale-heartbeat clearing and lane/session supervision |
| Autonomous two-lane node | Integrated; end-to-end CI passing | Full-duplex packets, crossed lanes, backpressure and asymmetric lane-loss recovery |
| Raw physical byte-stream boundary | Implemented at 8-bit interface | RX elastic FIFO, adapter overrun input and header-CRC-checked SOP/EOP reconstruction |
| Generic 8b/10b byte adapter | Implemented; regression added | 2/4/8 symbols per PHY word, comma/empty markers, byte FIFO |
| Parallel 8b/10b word adapter and byte/word gearboxes | Integrated prototype; sustained throughput limited | The safe default is one payload byte per PHY word; multi-byte mode is experimental because the bonded wire TX/RX framing core remains byte-wide and cannot consume full-rate multi-byte RX traffic |
| PHY FIFO read adapter | Implemented; delayed-valid regression added | Reservation-aware read-enable/data-valid FIFO to ready/valid bridge, including outstanding read tracking |
| Experimental RAM-backed RX | Candidate regression passing; not integrated | 8/16/32-bit RAM tests, 27 reference-vs-RAM differential configurations and generic Yosys memory inference pass |
| Gowin 8b/10b FIFO mapper | Implemented; 4/8-symbol mapping regressions added | Maps 40/44-bit and 80/88-bit Gowin interfaces, including disparity and decoder-error flags |
| Per-lane PHY bridge | Integrated as generic RTL | Independent TX/recovered-RX clocks, word packer/decoder, byte unpacker, session-drop flushing and sticky PHY faults |
| Two-lane parallel-PHY node wrapper | Integrated RTL; CI passing | End-to-end parallel-word PHY tests, session-flush recovery and malformed-symbol fault propagation; no sustained line-rate claim |
| Board-specific transceiver adapters | Acorn wrapper LiteX/Migen elaboration passing | Both 2.5 and 5.0 Gb/s targets elaborate with one shared QPLL and two GTP channels; no Vivado synthesis or hardware validation yet |
| PCIe / USB 3.x adapters | Future work | Must preserve each protocol's own ordering and flow-control rules |

## Current top-level RTL

- `rtl/bonded_two_lane_node.sv`: autonomous byte-oriented node wrapper.
- `rtl/bonded_two_lane_phy_word_node.sv`: parallel 8b/10b two-lane wrapper.
- `soc2soc/bonded_acorn.py`: prototype LiteICLink GTP binding for the Acorn; not yet build-validated.
- `rtl/bonded_lane_phy_word_bridge.sv`: per-lane TX/RX clock-domain PHY bridge.
- `rtl/bonded_control_manager.sv`: v0 session and credit manager.
- `rtl/bonded_two_lane_endpoint.sv`: lower-level endpoint with external control ports.
- `rtl/bonded_wire_rx_framer.sv`: reconstructs frame boundaries from raw bytes.
- `rtl/bonded_sync_byte_fifo.sv`: per-lane RX elastic buffering.
- `docs/physical-byte-stream-interface.md`: contract for a board PHY adapter.
- `docs/dynamic-lane-mapping.md`: remote lane-ID discovery, crossed cabling and duplicate-ID rejection.
- `docs/acorn-gtp-adapter.md`: exact LiteICLink GTP stream, clock, reset and error mapping for the Acorn.
- `docs/tang-gowin-phy-adapter.md`: Tang Mega 138K Pro Gowin PHY/FIFO mapping and outstanding-read reservation plan.
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
READY. The RTL workflow exercises the control encoder/decoder, queueing,
frame arbitration, receiver credits, raw-byte framing, session-abort recovery,
the full-duplex endpoint, and an autonomous two-node parallel-PHY test with
unrelated lane and bonding clocks.

**Current code verification (12 November 2026):** GitHub Actions run
[43178198151](https://github.com/ohault/soc2soc-over-serdes/actions/runs/43178198151)
on commit `eb0f3026fda8a1c501aedc3cad0251c55959e0c9` passes all three jobs:
Python bonding tests, the complete RTL frame-boundary workflow (including
two-node parallel-PHY transport, asymmetric lane-loss recovery, PHY
session-flush recovery, crossed-lane mapping and full-duplex backpressure),
and Acorn LiteX/Migen elaboration at both 2.5 and 5.0 Gb/s. The elaboration
confirms one shared QPLL and two GTP channel instances; it does not run Vivado.

The separate payload-RAM workflow
[43175183427](https://github.com/ohault/soc2soc-over-serdes/actions/runs/43175183427)
passes the 8/16/32-bit RAM regressions, all 27 reference-versus-RAM receiver
differential configurations (payload lengths 0 through 4096), and the generic
Yosys memory-inference check. The RAM-backed receiver remains an experimental
candidate and is not selected into the endpoint.

This is digital simulation and generic synthesis evidence only. It does not
model analogue SERDES behavior, PLL/CDR lock, actual transceiver code/disparity
indications, signal integrity, vendor BRAM mapping, FPGA resource utilization,
timing closure or bitstream behavior.

## Next engineering steps

1. Add a generated-Verilog structural check for exactly two GTP channel
   primitives and one shared QPLL, then inspect the clock, data/control,
   reset and decoder-error wiring. Keep the existing SerWB target unchanged.
2. Run Vivado synthesis and timing analysis for the conservative
   one-byte-per-PHY-word profile. Check QPLL configuration, resource use, CDC
   constraints and timing before generating a bitstream.
3. Bring up the Acorn boards with the two-DAC topology. Validate QPLL lock,
   TX/RX initialization, PRBS, polarity, comma alignment, lane mapping, session
   recovery and sustained packet integrity.
4. Measure aggregate throughput and long-duration backpressure behavior on
   hardware; the current byte-wide framing and application RX path are not a
   full-rate multi-byte datapath.
5. Widen the entire datapath for full-rate operation: TX/RX wire framing and
   CRC, CONTROL/DATA arbitration, per-lane CDC, packet reorder/reassembly and
   the logical application RX interface. Add sustained-rate regressions for
   two-, four- and eight-symbol PHY words, including overflow checks.
6. Audit asymmetric peer reboot, delayed CONTROL frames and stale complete
   DATA frames. The runtime epoch counter is volatile across cold boots and
   both peers still need the same non-zero initial session seed.
7. Generate the candidate 5.0-Gb/s Gowin PHY IP (20-bit internal width,
   1:2 ratio, 8b/10b encode/decode and RX word alignment), then add the
   board-specific Tang wrapper using the 40/44-bit FIFO adapter. Keep the
   80/88-bit 1:4 profile available as an alternative.
8. Add PCIe and USB protocol adapters only after the generic transport is
   stable and validated on hardware.
