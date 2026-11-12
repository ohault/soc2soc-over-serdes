# CDC implementation and timing-constraint guidance

This document defines the implementation requirements for the generic asynchronous
FIFO and per-lane PHY bridges. It is deliberately vendor-neutral; board projects
must translate these requirements into their FPGA tool's constraint language.

## 1. Clock domains

Each lane has at least three potentially unrelated clocks:

- bonding/application clock;
- lane TX user clock;
- lane RX recovered user clock.

Never declare these clocks synchronous merely because they originate from the
same nominal reference oscillator. Use the actual generated-clock definitions
from the selected transceiver IP and board clock tree.

## 2. Asynchronous FIFO reset contract

`bonded_async_fifo` has separate `wr_rst_n` and `rd_rst_n` ports, but its
contract requires them to be asserted together for a flush. Each side releases
reset through a two-stage synchronizer in its own clock domain.

The surrounding logic must:
- assert both resets for the same FIFO flush event;
- hold write and read traffic disabled until both domains have completed reset
  release;
- not reset only one pointer domain while the other side continues operating;
- treat a lane/session reset as a FIFO flush, not as a transparent continuation.

The FIFO's first-word-fall-through memory read is asynchronous. FPGA synthesis
may map it to distributed RAM rather than block RAM. Check the inferred memory
resources and timing in the target tool; a synchronous block-RAM implementation
would require a different read pipeline and handshake.

## 3. Synchronizer implementation

The RTL marks reset and Gray-pointer synchronizer registers with
`(* async_reg = "true" *)`. Preserve these attributes through synthesis.
Do not insert combinational logic between the first and second synchronizer
stages. Keep the stages physically close where the FPGA tool supports placement
guidance.

For each Gray pointer crossing:
- only the Gray-coded pointer crosses the clock boundary;
- the destination synchronizer must be at least two stages;
- downstream full/empty logic must use only the final synchronized stage;
- constrain the source-to-first-stage path as asynchronous;
- constrain the Gray bus so routing skew cannot span multiple source pointer
  transitions.

A blanket false-path constraint between the two clock domains is insufficient:
it can suppress the timing analysis needed to control Gray-bus skew.

## 4. Constraint intent

For each FIFO instance, identify these paths:

| Crossing | Source | Destination |
|---|---|---|
| Read pointer to write domain | `rd_gray` | `rd_gray_sync1` |
| Write pointer to read domain | `wr_gray` | `wr_gray_sync1` |
| Reset release | asynchronous reset input | first reset synchronizer stage |

Apply asynchronous clock-group or false-path treatment only as appropriate for
the first synchronizer stage, then apply a maximum datapath delay and/or bus-skew
constraint to each Gray bus according to the FPGA vendor's CDC guidance. The
constraint bound must be derived from the fastest source clock period and the
device/tool routing model; do not copy an arbitrary numeric value between
boards.

## 5. PHY bridge crossings

`bonded_lane_phy_word_bridge` synchronizes `session_active` independently
into TX and RX clocks. Its TX packer and RX unpacker are in their respective
local domains. The transceiver adapter must expose its actual user clocks and
reset-done / CDR-lock status to the board wrapper.

The generic bridge is not a substitute for vendor transceiver reset controllers.
The board wrapper must wait for PLL lock, CDR lock, and TX/RX reset completion
before asserting the corresponding lane-up indication.

## 6. Required pre-hardware checks

For every supported FPGA target, archive:

1. CDC report with no unexplained unsynchronized crossings.
2. Timing report showing the Gray-pointer skew/delay constraints are active.
3. Inferred RAM report for the asynchronous FIFO.
4. Post-synthesis and post-route timing for bonding, TX-user and RX-user clocks.
5. Reset-domain analysis for simultaneous FIFO flush and lane loss.
6. Resource utilization for each configured lane count and PHY word width.

Simulation and CI do not validate metastability MTBF, placement, routing skew,
transceiver lock, signal integrity, or timing closure. Those remain target-board
implementation and hardware-validation tasks.

## 7. Board wrapper responsibilities

A vendor-specific wrapper may instantiate transceiver primitives and generate
the PHY clocks, but it must preserve the generic byte/word handshakes and report:

- TX user clock and reset completion;
- RX recovered user clock and reset completion;
- decoded data and K-character/control indications;
- disparity/code error indications where available;
- buffer overrun/underrun indications;
- lane-up only after the PHY is actually usable.

No vendor primitive or board pin assignment belongs in the common bonding core.
