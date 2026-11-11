# Bonded interconnect RTL interface contract v0

**Status:** proposed signal-level contract for review; no RTL implementation is implied by this document.  
**Scope:** framework-neutral interface contract for a packet-bonding core and its physical-lane adapters.  
**Related specifications:** [bonded interconnect architecture](bonded-interconnect.md), [bonded wire protocol](bonded-wire-protocol-v0.md).

## 1. Design boundary

The RTL core is a synchronous packet transport over a configurable number of independent full-duplex physical lanes.

It must not depend on:
- LiteX, LiteICLink, Migen, Wishbone, CSR or a CPU;
- a board name, FPGA vendor, transceiver primitive, SFP cage index or cable topology;
- SerWB, UART, PCIe, USB, Linux or any application protocol.

The signal names below are normative names for the interface contract, not a commitment to a particular HDL syntax. A Migen implementation may expose equivalent signals, but must preserve the handshake and reset semantics.

The initial hardware profile is two lanes, one common lane word width, equal configured line rates and one bonding-core clock. The parameterisation must not hard-code two lanes.

## 2. Clock and reset

### 2.1 Bonding clock

All logical packet, lane-service and status handshakes at the core boundary are synchronous to `bond_clk`.

The platform integration supplies `bond_clk`. It is not assumed to be a transceiver reference clock or a recovered RX clock.

### 2.2 Reset

- `bond_rst` is synchronous, active high, and sampled on `bond_clk`.
- Assertion may be asynchronous at the platform boundary, but deassertion must be synchronised to `bond_clk`.
- Reset clears in-flight packets, sequence state, credit reservations, reorder state and control queues.
- After reset, no DATA is accepted or emitted until a new bonded session is established.
- A physical lane adapter must independently handle its transceiver-specific reset sequence and CDC reset requirements.

A reset of the bonding core is a local reset. It does not imply that the remote endpoint reset at the same instant; the control protocol must recover an asymmetric reset.

## 3. Logical packet client interface

The client interface is a packet stream. A packet is accepted as a sequence of beats; the core buffers the complete packet before assigning it to a physical lane. This preserves packet-level striping and avoids splitting a packet over multiple lanes.

Parameters:
- `DATA_WIDTH`: positive multiple of 8; initial integration value 32.
- `KEEP_WIDTH = DATA_WIDTH / 8`.
- `MAX_PACKET_BYTES`: initial value 4096, matching the v0 wire codec.
- `REORDER_WINDOW`: initial reference-model value 32 packets.

TX signals:
- `tx_valid`: current beat is valid.
- `tx_ready`: core can accept the current beat.
- `tx_data[DATA_WIDTH-1:0]`: payload bytes; byte 0 occupies the least-significant byte.
- `tx_keep[KEEP_WIDTH-1:0]`: byte-valid mask; contiguous low-order ones are required. On non-final beats all bits must be one.
- `tx_sop`: first beat of a packet.
- `tx_eop`: final beat of a packet.

RX uses the corresponding `rx_valid`, `rx_ready`, `rx_data`, `rx_keep`, `rx_sop`, and `rx_eop` signals.

Handshake rule: a beat transfers only on a rising edge where `valid && ready` is true. While `valid && !ready`, the producer must hold data and all sideband signals stable.

Packet rules:
1. A packet begins with exactly one accepted beat carrying `sop=1`.
2. The packet ends with exactly one accepted beat carrying `eop=1`.
3. `sop` may only occur when no packet is currently being assembled; `eop` must close an open packet.
4. Empty packets are not supported in v0.
5. The final beat's `keep` must contain at least one set bit. Byte lanes are contiguous from bit 0; sparse masks are invalid.
6. The assembled packet length must not exceed `MAX_PACKET_BYTES`.
7. A malformed packet is a client-interface protocol error. The implementation must expose an error/status indication and must not emit a partial packet onto a lane.

The core may deassert `tx_ready` while it has insufficient packet-buffer capacity or no bounded descriptor/buffer slot. It must not consume a packet sequence number until a complete packet has been accepted for transmission and both local queue capacity and remote cumulative credits have been reserved.

RX preserves packet order. If the client deasserts `rx_ready`, the core holds the current beat and its sideband signals stable. Receive credits are returned only after the complete packet has been consumed by the client (the final beat handshake).

### 3.1 Client status

The implementation should expose, through implementation-neutral status signals or a documented register wrapper:
- `session_up`;
- `tx_packet_error` (sticky or pulse, implementation choice documented);
- `rx_packet_error` (sticky or pulse, implementation choice documented);
- `tx_packets_accepted` and `rx_packets_delivered` counters, if counters are implemented.

No CSR bus is specified here. A LiteX adapter may map status into CSRs; another platform may map it into registers or software-visible diagnostics.

## 4. Physical lane-service interface

There is one lane-service port per configured lane. The lane service represents a framed byte stream transported over one physical link. It is already in the `bond_clk` domain; no asynchronous recovered clock may cross this boundary.

Parameters:
- `LANE_COUNT`: positive integer; first hardware target 2.
- `LANE_DATA_WIDTH`: positive multiple of 8; first Acorn adapter candidate 32.
- All lanes use the same `LANE_DATA_WIDTH` in v0.
- `LANE_KEEP_WIDTH = LANE_DATA_WIDTH / 8`.

For each lane `i`, TX signals from core to adapter:
- `lane_tx_valid[i]`, `lane_tx_ready[i]`;
- `lane_tx_data[i][LANE_DATA_WIDTH-1:0]`;
- `lane_tx_keep[i][LANE_KEEP_WIDTH-1:0]`;
- `lane_tx_sop[i]`, `lane_tx_eop[i]`.

RX signals from adapter to core:
- `lane_rx_valid[i]`, `lane_rx_ready[i]`;
- `lane_rx_data[i][LANE_DATA_WIDTH-1:0]`;
- `lane_rx_keep[i][LANE_KEEP_WIDTH-1:0]`;
- `lane_rx_sop[i]`, `lane_rx_eop[i]`.

The handshake and stability rules are identical to the logical packet interface. Here SOP/EOP delimit one complete bonded-wire frame (DATA or CONTROL), not one client packet. The wire codec defines the frame contents, header, checksums and packet sequence.

The lane adapter must preserve byte order and frame boundaries. It may use a continuous underlying PHY stream; it is responsible for encoding/decoding the SOP/EOP framing into that PHY's transport, and for rejecting malformed physical framing.

### 4.1 Lane status and reset events

Per lane, the adapter supplies the following signals in the bonding clock domain:
- `lane_up[i]`: physical lane service is qualified and can transfer frames.
- `lane_epoch[i][EPOCH_WIDTH-1:0]`: changes whenever the adapter reinitialises the lane or detects a physical link restart that invalidates in-flight lane data.
- `lane_rx_error[i]`: pulse indicating a receive/framing/decoder error.
- `lane_overflow[i]`: pulse or sticky indication that the adapter could not retain received data.
- `lane_status_valid[i]`: optional validity qualifier if the implementation cannot provide reliable status immediately after reset.

The adapter must synchronise multi-bit status into `bond_clk`; it must not expose raw asynchronous transceiver status buses to the core.

The core records each lane epoch. A change of epoch, a falling `lane_up`, an RX error classified as fatal, or an overflow classified as fatal invalidates the complete v0 bonded session. The initial policy is fail-stop: all configured lanes must be up and rediscovered before DATA resumes.

The adapter owns CDC and physical FIFO flushing. Following a lane epoch change it must not deliver pre-reset FIFO contents as new-session frames. The core additionally rejects frames with a stale session identifier.

### 4.2 Adapter obligations

A physical adapter owns:
- transceiver/PHY instantiation, configuration, reference clocks and board pin constraints;
- encoding/decoding, comma alignment and physical framing;
- per-lane TX/RX clock-domain crossings and buffering;
- synchronisation of lane state and epoch into `bond_clk`;
- conversion between the PHY's native stream and the lane-service framed stream;
- reporting of receive errors, overflow and lane restart.

The bonding core owns none of those vendor- or board-specific details.

## 5. Bonding-core datapath responsibilities

The core:
1. accepts complete client packets;
2. reserves cumulative remote byte and packet credits;
3. assigns one 32-bit packet sequence number per accepted packet;
4. selects one session-ready lane using deterministic round-robin scheduling;
5. emits a DATA frame on that lane;
6. receives and validates DATA frames from any mapped lane;
7. reorders packets within the configured bounded window;
8. delivers complete packets in sequence order;
9. returns cumulative credits after client consumption;
10. invalidates the session on unrecoverable lane/session faults or sequence-gap timeout.

The core must not split one client packet across lanes in v0. It must not silently skip a missing sequence number. It must not claim retransmission or lossless recovery across a lane failure.

The software reference model currently uses a per-lane TX queue depth of 4, a 16 KiB / 64-packet RX capacity, a 32-packet reorder window and a 1024-cycle gap timeout. These are model defaults, not yet frozen hardware defaults. RTL parameters must make buffer/window sizing explicit.

## 6. Wire-frame engine and control path

The existing `soc2soc/bonding/wire.py` is the byte-level reference codec. The RTL must implement the same wire format; it must not create a second incompatible envelope.

Current v0 codec properties:
- magic `0x5342`, version `1`;
- 24-byte fixed header;
- big-endian multi-byte header fields;
- CRC-16/CCITT-FALSE over the first 22 header bytes;
- CRC-32C trailer over header plus body;
- DATA body begins with a 32-bit packet sequence followed by up to 4096 payload bytes;
- CONTROL body starts with an opcode and has opcode-specific fixed field lengths;
- frame/session identifiers and field widths are defined by the wire codec and protocol document.

The RTL wire engine converts between the lane-service beat stream and decoded frame events. It validates the complete header and CRCs before passing a frame to the control or DATA path. It must enforce configured packet/frame limits before allocating receive storage.

Control traffic must be prioritised over DATA at frame boundaries. A frame already being transmitted is not preempted. The implementation must prevent DATA starvation of control frames. Control messages include HELLO, READY, CREDIT, PING, PONG, RESET and ERROR as defined by the current codec.

The v0 wire codec is a reference implementation; it is not yet a proof that the current control-plane recovery semantics are complete or that the codec has been implemented in RTL.

## 7. Clock-domain crossing and buffering rules

All lane-service handshakes and logical client handshakes are in `bond_clk`. Therefore:
- the bonding core contains no direct logic on per-lane recovered clocks;
- each adapter uses asynchronous FIFOs or an equivalent safe CDC mechanism between PHY clocks and `bond_clk`;
- FIFO reset/flush is coordinated with the lane epoch;
- CDC status uses synchronisers/handshakes appropriate to the signal semantics;
- FIFO depth and almost-full thresholds are explicit parameters, not inferred from a particular board.

The first implementation may use a common `bond_clk` supplied by the platform. The architecture does not require that clock to be shared between the two endpoints; the two systems may have unrelated local bonding clocks.

## 8. Initial implementation partition

Keep the first RTL change isolated from the existing single-lane path.

Proposed logical blocks (names are descriptive, not mandated HDL module names):

| Block | Responsibility | Framework/vendor dependency |
|---|---|---|
| `bonded_core` | packet buffering, scheduler, sequence/reorder, credits, session state | none in interface/architecture |
| `bonded_wire_tx` | DATA/CONTROL frame serialization, CRC generation | none |
| `bonded_wire_rx` | frame parsing, CRC validation, event extraction | none |
| `bonded_lane_port` | one lane-service handshake and status port | none |
| `serdes_lane_adapter` | maps existing PHY stream into lane-service port | Migen/LiteX for first integration |
| platform wrapper | clocks, reset, transceiver, pins and board setup | platform/vendor-specific |

A first Migen implementation would be SoC/framework-independent but Migen-dependent. This document does not claim HDL independence. The signal-level contract and wire specification are intended to permit a later SystemVerilog implementation.

## 9. Existing-code reuse

- `soc2soc/bonding/model.py` is the behavioural reference for packet scheduling, credits, ordering and failure semantics.
- `soc2soc/bonding/control.py` and `wire.py` are the reference control-plane and wire-codec implementations.
- `soc2soc/link.py:SerDesLinkPHY` is a candidate for the first lane adapter because it already presents a 32-bit stream in the LiteX `sys` domain. It is not a framework-neutral lane port and does not expose the complete SOP/EOP lane-service contract as specified here.
- `soc2soc/serdes_link.py:GTPSoCLink` is a SoC-oriented composition and should not be refactored wholesale for this milestone.
- Existing SerWB and independent two-link operation remain untouched.

The first adapter must prove the boundary with a small wrapper; do not change the existing SerDes link's public behaviour merely to fit the bonding core.

## 10. Verification required before RTL acceptance

### Interface-level tests
1. Valid/ready stability under arbitrary backpressure on client TX/RX and every lane.
2. SOP/EOP and KEEP validation, including malformed and maximum-length packets.
3. A lane becoming unavailable while a frame is queued or being transmitted.
4. Lane epoch change with stale adapter FIFO data present.
5. Independent lane TX stalls and RX arrival skew.
6. Control-frame priority without preempting an in-flight frame.
7. Bounded buffering and explicit overflow/error reporting.

### End-to-end bonded tests
1. One lane and two lanes.
2. Crossed physical lane mapping.
3. Equal and asymmetric lane latency.
4. Out-of-order packet arrival and in-order delivery.
5. Credit exhaustion and return only after final client RX handshake.
6. Missing sequence timeout.
7. Asymmetric and simultaneous endpoint reset/recovery.
8. Stale session frames after reset.
9. Protocol mismatch, malformed header, header CRC and payload CRC errors.
10. Regression of all existing non-bonded tests.

## 11. Decisions deliberately left open

These must be decided with implementation evidence rather than guessed:
- exact RTL language and simulation tool (Migen/nMigen, Verilog or SystemVerilog);
- packet RAM implementation and whether small FIFOs or block RAM are used;
- maximum packet size and buffer sizes for the first hardware target;
- whether CRC32C is implemented combinationally, pipelined or byte-serial;
- exact lane-epoch width and wrap policy;
- whether physical decoder errors are always fatal or may be thresholded;
- control-frame scheduling fairness and queue sizing;
- whether a separate `bond_clk` is required or an existing system clock is adequate for the first board.

No vendor primitive, board clock frequency, transceiver rate, or specific LiteX endpoint is mandated by this contract.
