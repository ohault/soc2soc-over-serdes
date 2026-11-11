# Bonded SerDes interconnect: architecture and implementation plan

**Status:** proposal for review; no RTL/API changes are made by this document.  
**Target branch:** `feature/bonded-serdes-interconnect`

## 1. Purpose

Introduce a logical interconnect that can use multiple independent full-duplex SerDes lanes as one ordered logical transport.

The first implementation target is two SFP/DAC lanes between two FPGA-based systems. The architecture must not assume two lanes, a particular board, FPGA vendor, transceiver family, SoC, CPU, operating system, or host bus.

The initial user-visible service is a reliable-in-order *stream of framed packets* between two endpoints. Application protocols such as SerWB, a remote serial console, or future PCIe/USB packet tunnels are clients of this service; they are not part of the bonding core.

## 2. Design constraints

1. **Board and vendor agnostic:** no Acorn, Tang, SQRL, Xilinx, AMD, Gowin, or Sipeed assumptions in the bonding protocol or core.
2. **SoC/framework independent:** no LiteX, LiteICLink, Wishbone, CSR, Linux, or CPU dependency in the logical bonding core.
3. **Configurable lane count:** the core accepts a configured number of lanes. The first hardware profile uses two; the protocol must not encode a fixed two-lane topology.
4. **Physical adaptation is replaceable:** transceiver setup, pin constraints, reference clocks, reset sequencing, equalization, encoding/decoding, and board pinout live in physical adapters/platform integration.
5. **Preserve existing operation:** the current single-lane SerWB path and current independent two-link scenarios must continue to work while the bonded path is developed separately.
6. **No application assumptions:** the bonded service does not interpret Wishbone addresses, SerWB packets, UART bytes, PCIe TLPs, or USB transactions.
7. **No false claim of native lane aggregation:** this is packet-level aggregation above independent physical links. It is not, by itself, PCIe multi-lane PHY bonding or USB SuperSpeed lane bonding.

## 3. What exists today

The repository already has working building blocks, but it does not yet implement a bonded logical link.

- `soc2soc/link.py:SerDesLinkPHY` implements a 32-bit stream link over a 16-bit, two-byte 8b/10b transceiver interface. It performs IDLE/status framing, link qualification, error detection, pause-based flow control, and clock-domain crossings between transceiver TX/RX clocks and the LiteX `sys` domain.
- `soc2soc/serdes_link.py:GTPSoCLink` combines the LiteICLink 7-series GTP, `SerDesLinkPHY`, the LiteICLink SerWB core, optional stream port, and optional remote window. It is a SoC-oriented integration wrapper, not a generic physical adapter.
- `soc2soc/stream.py:SerWBStreamPort` is an application-specific bidirectional stream carried as SerWB logical port 1. It uses 32-bit words, packet chunks, and credit-based flow control. It is not the generic bonded transport.
- `acorn_soc2soc.py` instantiates the board-specific GTP/SFP implementation and assigns initiator/target roles.
- `test/test_link.py` simulates a single link layer and SerWB path. `test/test_bench.py` simulates the existing one- and two-cable topologies.
- The README's two-cable scenario connects two independent links in opposite directions (A.SFP0 to B.SFP1 and B.SFP0 to A.SFP1). The two links are used concurrently, but traffic is not striped across them as one logical link.
- The 2026-11-07 hardware result demonstrates simultaneous operation of two independent SFP channels. It is useful baseline evidence, not a bonded-link test.

### Consequence for reuse

Do not rewrite the existing link layer or GTP wrapper as a first step. First add a separate bonding layer above a well-defined per-lane stream service, then add an adapter that connects the current LiteX implementation to that service.

The current `SerDesLinkPHY` is a useful *candidate* for the first lane adapter because it already presents a 32-bit stream in the system clock domain. It is not itself framework-independent: it imports Migen/LiteX stream, CSR, clock-domain and 8b/10b definitions. Keep that dependency on the adapter/integration side of the boundary.

## 4. Proposed architecture

```text
                 Application / protocol clients
          SerWB       remote console       PCIe/USB tunnel
             \             |                    /
              +------------+-------------------+
                           |
                Logical packet/stream interface
                           |
                 +---------------------+
                 |   Bonding core      |
                 |                     |
                 | session / lane map  |
                 | packet striping     |
                 | sequence / reorder  |
                 | aggregate flow ctrl |
                 | lane health         |
                 +--+--------------+---+
                    |              |
             lane service 0   lane service 1   ... lane service N-1
                    |              |
             +------v------+ +-----v--------+
             | Lane adapter| | Lane adapter |   platform-specific
             +------^------+ +-----^--------+
                    |              |
              SerDes PHY 0    SerDes PHY 1
                    |              |
                 SFP/DAC 0      SFP/DAC 1
```

The bonding core is logically independent of how each lane is implemented. A lane adapter is responsible for making one physical link look like a synchronous lane service to the bonding core.

### 4.1 Lane-service boundary (proposed)

The first implementation should define a small, documented contract rather than prematurely committing to a public Python class or HDL module name.

Each lane service provides:

- TX: ready/valid handshake and a fixed-width data word.
- RX: ready/valid handshake and a fixed-width data word.
- Local lane state: link-up/ready, reset/reinitialisation indication, and a link epoch or equivalent way to detect that the peer/lane has restarted.
- Error/status: at minimum a sticky or countable receive/framing error indication and overflow indication.
- A single common **bonding-core clock domain** for its TX and RX handshakes.

The data width is a configuration parameter shared by all lanes in the initial profile. A 32-bit word is the natural first integration width because that is what `SerDesLinkPHY` already exposes. The bonding protocol must not depend on that width.

The adapter must absorb all lane-specific clocking. In particular, each recovered RX clock and each TX clock can be independent. The adapter must provide the required asynchronous FIFOs/CDC, reset coordination, and safe status synchronisation so that the bonding core sees all lane services in one clock domain. The bonding core must not sample unrelated recovered clocks directly.

A future implementation may support separate TX/RX user clocks or asynchronous lane interfaces, but that is not required for the first version.

### 4.2 Adapter responsibilities

A lane adapter owns:

- Vendor/transceiver primitive instantiation and configuration.
- SFP electrical/pin interface and board-specific constraints.
- Reference-clock selection and PLL/QPLL setup.
- Physical reset and transceiver initialisation.
- Encoding/decoding and symbol/framing details required by that physical link.
- RX/TX clock-domain crossings into the common bonding clock.
- Mapping physical link status/errors into the lane-service contract.

For the first Acorn implementation, an adapter may compose the existing GTP setup and `SerDesLinkPHY`. Keep this composition outside the bonding core. Other boards may later supply different adapters without changing the bonding protocol.

### 4.3 Bonding-core responsibilities

The core owns:

- Peer/session establishment across all configured lanes.
- Lane identity and lane-to-peer association (do not infer identity from local SFP index or cable wiring).
- Packet striping over available lanes.
- Sequence numbering and ordered reassembly.
- Bounded buffering and aggregate backpressure.
- Lane health, loss detection, and deterministic session reset/recovery.
- A logical packet interface independent of the application protocol.

The core must not own a transceiver primitive, board pin, reference clock, CSR bus, Wishbone bus, SerWB core, or Linux device.

## 5. Initial transport profile (v0)

The first profile should favour correctness and debuggability over maximum throughput.

### 5.1 Transfer unit

Stripe **complete packets/frames**, not individual bytes or arbitrary words, across lanes. A packet is the unit accepted by the logical interface and the unit reassembled before delivery.

The logical interface must carry at least:
- packet payload;
- packet length or an end-of-packet marker;
- optional application-defined metadata only if a concrete client requires it.

Do not bake a specific application header into the core. The bonding layer adds its own transport header on each lane.

### 5.2 Transport header

Define and version a compact header containing at least:

- protocol magic and version;
- session identifier/epoch;
- source lane identity;
- packet sequence number;
- payload length and framing flags;
- header integrity check (or a documented equivalent).

A payload CRC may be added in the first implementation if the existing lane service does not already provide an adequate integrity check. Do not assume 8b/10b disparity/framing checks detect arbitrary payload corruption.

Exact field widths, endianness, alignment, and CRC polynomial should be specified alongside the RTL implementation after the lane word width and maximum packet size are fixed. Avoid assigning speculative bit positions in this architecture note.

### 5.3 Lane assignment and ordering

- Use a deterministic round-robin scheduler initially, selecting only lanes that are session-ready and have transmit capacity.
- A packet is assigned wholly to one lane. Do not split one packet across two lanes in v0.
- Sequence numbers are assigned once at the logical ingress, not independently by each lane.
- The receiver reorders complete packets by sequence number and delivers them in original ingress order.
- Reordering storage must be bounded. If the next expected packet does not arrive within a defined timeout/window policy, the receiver must not silently skip it and corrupt the stream. In v0, treat an unrecoverable gap as a session fault and reset the bonded session.
- The scheduler may later become weighted or latency-aware. Do not introduce adaptive scheduling before the correctness tests exist.

Packet-level striping will not guarantee that two lanes are perfectly utilised for every traffic pattern: a large packet occupies one lane while the other can carry another packet. This is an intentional v0 trade-off.

### 5.4 Flow control and buffering

- The logical interface applies backpressure when aggregate TX capacity is exhausted.
- Each lane has an independent, finite TX queue. A full lane is skipped by the packet scheduler while other lanes remain eligible.
- If every lane queue is full, the logical sender does not accept the packet; the caller must retain it and retry. A rejected enqueue must not consume a sequence number.
- The adapter-facing dequeue operation represents acceptance by that lane adapter, not wire transmission or remote acknowledgement.
- Reassembly/reorder buffers have explicit finite capacities and high-water marks.
- This reference-model step covers local per-lane TX queue capacity and aggregate sender backpressure. It does **not yet** model remote receiver capacity, a wire-level credit protocol, or the number of packets already in flight after a remote pause.
- Those remote-flow-control semantics must be specified before RTL. The model must eventually distinguish local queue space, lane-adapter acceptance, physical transmission, and remote receive-buffer availability.

The current `SerDesLinkPHY` has a per-lane pause mechanism and an RX buffer. This can help the first adapter, but it is not a substitute for aggregate buffering and ordering.

### 5.5 Session and lane management

A local lane's `link_up` is not proof that the remote bonding endpoint has associated the same physical lane with the same session.

The endpoints must exchange bonding-level control information to establish:
- peer identity/session;
- configured lane count and compatible profile;
- lane identity and observed peer-lane mapping;
- protocol version and relevant limits;
- ready state for the bonded session.

Do not use SFP0/SFP1 numbering as a protocol identity. Cable wiring may cross local ports, and the design must discover/validate the mapping.

**Initial policy:** the bonded session becomes operational only when every configured lane has been discovered and validated. If any lane drops, mark the aggregate session down, stop accepting new packets, discard incomplete/in-flight bonded packets, and restart session establishment when the configured lane set is healthy again. This fail-stop policy is simpler to verify than silently continuing on one lane.

A later version may support degraded operation with fewer lanes, lane rejoin, and retransmission. These are explicitly out of scope for v0.

### 5.6 Reliability semantics

The v0 design provides ordered delivery while the bonded session remains healthy, with explicit session failure on a detected lane/session fault. It does **not** promise lossless recovery of packets in flight across a physical link failure.

Do not describe this as a reliable retransmitting transport until acknowledgement, retransmission, duplicate suppression, timeout, and replay-buffer semantics have been designed and tested. Higher-level protocols may already provide their own recovery.

## 6. Clocking and reset rules

1. Each physical lane has independent TX and recovered RX clocks.
2. The adapter crosses both directions into the bonding-core clock domain using suitable asynchronous FIFOs or equivalent CDC structures.
3. Status signals crossing domains must use synchronisers or handshakes appropriate to their semantics; multi-bit status must not be sampled as an unsynchronised bus.
4. A physical lane reset/reinitialisation invalidates its queued words and must be visible to the bonding core as a lane epoch/state change.
5. A lane reset or loss during a bonded session causes the v0 aggregate session to go down. Reinitialisation must not allow stale FIFO contents from the previous session to be interpreted as current-session packets.
6. The common bonding clock is supplied by platform integration. It is not assumed to be a transceiver reference clock or a recovered clock.

## 7. Integration strategy

Keep the current implementation operational and introduce the bonded path alongside it.

### Stage 0 — architecture and baseline

- Review this document and agree on the lane-service and logical packet contracts.
- Record baseline simulations and current hardware measurements.
- No modifications to existing link or SerWB behaviour.

### Stage 1 — framework-neutral protocol model

- Implement a software/reference model of packet scheduling, lane assignment, sequence numbers, reordering, session establishment, and lane-loss behaviour.
- Add deterministic tests for out-of-order arrival, lane skew, backpressure, duplicate/stale session traffic, lane reset, missing packets, and lane-count variations.
- Use this model to settle header fields and timeout/window rules before RTL.

### Stage 2 — bonding RTL/core

- Implement the bonding datapath and control state machine using the repository's current HDL toolchain only where needed.
- Keep the module free of LiteX SoC, Wishbone, SerWB, and board-specific imports.
- If implemented in Migen, describe it accurately as **SoC/framework-independent but Migen-dependent**. Do not claim HDL independence. A future Verilog/SystemVerilog implementation can target a language/tool-neutral protocol specification.

### Stage 3 — first lane adapter

- Adapt the existing `SerDesLinkPHY` output/input stream to the lane-service contract.
- Keep the existing GTP and LiteX dependencies in the Acorn adapter.
- Verify independent lane readiness, clock crossings, reset/epoch handling, and error propagation.
- Do not refactor `GTPSoCLink` wholesale before the adapter boundary is proven.

### Stage 4 — simulation and hardware integration

- First simulate two bonded endpoints with two independently clocked lanes and controllable skew, stalls, resets, and faults.
- Then integrate two lanes on one supported board pair.
- Preserve and rerun all existing single-link, independent-link, SerWB, and hardware bring-up tests.
- Compare measured aggregate throughput with the sum of the two single-lane baselines, accounting for bonding headers, packet scheduling, and reassembly.

### Stage 5 — application clients

Add clients separately:
- SerWB over the logical transport (if the chosen SerWB framing can be carried cleanly as packets).
- Byte-stream service for a remote serial console, with a Linux PTY/userspace bridge as an initial host-side experiment.
- PCIe or USB packet tunnelling only as separate protocol-specific projects.

## 8. Required verification scenarios

At minimum:

1. One lane configured: behaves as a one-lane bonded session.
2. Two lanes, equal latency: packets are striped and delivered in order.
3. Two lanes, asymmetric latency: receiver reorders correctly.
4. One lane temporarily stalls while the other continues transmitting.
5. RX consumer backpressure reaches the sender without overflow.
6. Lane loss while idle.
7. Lane loss while packets are in flight.
8. Lane reset/reinitialisation with stale FIFO contents present.
9. Crossed physical wiring / lane discovery.
10. Mismatched lane count or protocol version: session does not come up.
11. Duplicate, stale-session, malformed, and corrupted transport headers are rejected.
12. More than two configured lanes in the reference model, even if first RTL/hardware target is two.
13. Existing non-bonded regression suite remains unchanged and passes.

## 9. Explicit non-goals for v0

- Native PCIe xN or USB SuperSpeed multi-lane PHY extension.
- Transparent PCIe electrical/PHY extension over SFP.
- USB 3.2 Gen 2x2 PHY extension.
- Automatic lane-rate conversion or heterogeneous lane widths/rates.
- Dynamic lane add/remove while the session remains operational.
- Degraded one-lane operation after a two-lane session loses one lane.
- Retransmission/replay guaranteeing lossless recovery across lane failure.
- QoS, priority classes, weighted scheduling, or latency-aware adaptive striping.
- Linux drivers or userspace services inside the FPGA core.

## 10. Repository impact proposed for the first implementation

Do not move or rename existing modules in the first change. Add the new work in a separate namespace, for example:

- `soc2soc/bonding/` — protocol model and bonding core.
- `soc2soc/adapters/` — framework/platform adapters, with the first LiteX/Acorn adapter clearly isolated.
- `test/test_bonding_model.py` — reference-model tests.
- `test/test_bonding.py` — RTL simulation tests.
- `docs/bonded-interconnect.md` — this architecture and evolving protocol specification.

These paths are suggestions, not existing repository structure. Agree on them before creating the implementation files.

## 11. Open decisions before RTL

The following must be resolved explicitly rather than hidden in implementation defaults:

1. Logical interface granularity: packet interface (recommended) versus a generic byte stream with packet delimiters.
2. Initial maximum packet size and whether the packet length is fixed-width or bounded by configuration.
3. Header integrity and payload integrity requirements.
4. Sequence-number width and maximum reorder window.
5. Session identity/epoch generation and collision avoidance.
6. Timeout policy for missing sequence numbers and failed lane discovery.
7. Whether all lanes must have identical physical rates/word widths in the first hardware profile (recommended: yes).
8. Which simulation/runtime dependencies are acceptable for a framework-neutral reference model.

**Recommended decision:** start with a packet interface, fixed common lane word width, same-rate lanes, two lanes in hardware, all-lanes-required session policy, deterministic round-robin packet striping, bounded reordering, and fail-stop session reset on a missing packet or lane failure. Keep all those values configurable where that does not complicate the first implementation.
