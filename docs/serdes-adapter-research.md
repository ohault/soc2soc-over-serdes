# SERDES adapter research and throughput implications

This note records the first vendor-neutral comparison for the two intended
hardware targets. It does not add a dependency on either vendor's HDL or SoC
framework to the bonding core.

## LiteX Acorn Baseboard Mini + SQRL Acorn CLE-215+

The Mini carrier provides two independent SFP cages, SFP0 and SFP1. The
CLE-215+ is an Artix-7 XC7A200T with four GTP transceivers, rated up to
6.6 Gb/s per transceiver.

The public `enjoy-digital/litex-acorn-baseboard` bring-up design
`bringup/mini/acorn_serdes/sqrl_acorn.py` provides a useful reference:

- It instantiates `GTPQuadPLL` and `GTP` from LiteICLink.
- It generates a 125 MHz reference clock from the 200 MHz board clock for
  the GTP PLL in its default example.
- The GTP data width is configurable as 20 or 40 bits.
- With 20-bit width there are two 8b/10b symbols (two data bytes plus two
  control bits) per user-clock cycle; with 40-bit width there are four.
- The GTP user-clock frequency is `linerate / data_width`.
- It exposes separate TX and recovered RX clock domains.
- The existing 1000BASE-X bring-up uses both SFP cages and documents the
  Acorn RX polarity inversion; TX polarity is configured separately.

In the current LiteICLink GTP stream wrapper, the PHY source is continuously
valid and the PHY sink is continuously ready. The generic adapter should
therefore use `tx_phy_ready=1` and `RX_PHY_STALLABLE=0`, relying on its local RX
byte FIFO to absorb finite stalls and reporting overflow if that FIFO fills.

The source is a valuable implementation reference, but the board-specific
GTP primitive and LiteICLink wrapper must remain outside the generic bonding
RTL. The existing example's SFP polarity comments are not fully consistent
across its test and Ethernet designs, so the adapter must use the actual
schematic and a PRBS/loopback check rather than assume polarity.

Two details need resolution from the exact Mini schematic/revision before
writing pin constraints:

- The standalone GTP test lists SFP1 RX as B8/C8, while the 1000BASE-X example
  lists B8/A8. Do not copy either pin pair blindly; resolve it against the
  carrier schematic and the actual board revision.
- The 1000BASE-X example uses RX polarity inversion and no TX polarity
  inversion, while the standalone GTP test leaves both at zero with FIXME
  comments. Start from the proven Ethernet example only as a reference, then
  confirm with PRBS/loopback.

The baseboard repository also records a known SFP TX_DISABLE issue: 4.7-kOhm
pull-downs may be too weak for some modules. Before debugging a dark TX link,
check the module's TX_DISABLE level and the carrier revision; do not assume a
SERDES configuration fault or modify resistors without measuring first.


References:

- https://github.com/enjoy-digital/litex-acorn-baseboard
- https://github.com/enjoy-digital/liteiclink/blob/master/liteiclink/serdes/gtp_7series.py
- https://github.com/enjoy-digital/litex-acorn-baseboard/blob/master/bringup/mini/acorn_serdes/sqrl_acorn.py
- https://github.com/enjoy-digital/litex-acorn-baseboard/blob/master/bringup/mini/acorn_sfp_eth_1000basex/sqrl_acorn.py

## Sipeed Tang Mega 138K Pro Dock

The SOM uses a Gowin GW5AST-LV138FPG676A. The documented device resources
include eight high-speed transceivers rated up to 12.5 Gb/s. The dock provides
two SFP+ cages. The board block diagram routes the two SFP+ cages to SERDES
Quad Q1; Q0 is used for the PCIe x4 interface. Two MS5351 clock generators
provide SERDES reference clocks. Sipeed's reference-clock instructions expose
100 MHz, 125 MHz and 156.25 MHz differential output examples, and select which
MS5351 to configure with the onboard debugger's UART command `pll_switch 0`
or `pll_switch 1`.

The Gowin Customized PHY IP documentation is particularly relevant:

- The fabric-side TX/RX width is configurable through the internal width and
  external data ratio. Supported configurations include wide parallel buses;
  40-bit fabric data can be built from a 20-bit internal interface with a
  1:2 ratio.
- The RX fabric clock is derived from the lane rate and fabric data width.
- 8b/10b encode/decode is available for the supported 10/20-bit internal
  widths; RX word alignment is required when decoding is enabled.
- The IP includes optional TX channel bonding and RX word alignment. Those
  are PHY-level functions, not a replacement for this project's packet-level
  bonding, sequencing, credits and reassembly.
- For GW5AST-138, TX and RX internal data widths must match.

For the Gowin FIFO interface, map TX full to `tx_phy_ready` and only issue RX
read requests when sufficient adapter capacity has been reserved for the PHY
FIFO's documented read-valid latency.

The first adapter should use the Gowin IP as a PHY boundary only. It should
export decoded data, recovered RX clock, TX user clock, byte/control
indications, PLL/CDR lock and error status. The PHY guide describes a FIFO-style
user interface: TX writes are qualified by a FIFO write enable/full flag, and
RX data is read with an enable and a documented valid latency. The board
wrapper must translate those semantics into the generic adapter's
ready/valid interface; they are not direct ready/valid ports. The generic node must not depend
on the Gowin IP's internal FIFO or channel-bonding controls.

References:

- https://en.wiki.sipeed.com/hardware/en/tang/tang-mega-138k/mega-138k-pro.html
- https://dl.sipeed.com/fileList/TANG/Mega_138K_Pro/01_Specification/Tang_MEGA_138K_Pro_Specification_V1.0_en-US.pdf
- https://www.gowinsemi.com/upload/database_doc/2567/document/683a135ba221f.pdf
- https://github.com/sipeed/TangMega-138KPro-example

## Implication for the current RTL

The current autonomous node exposes one 8-bit byte per lane clock. This is
excellent as a simple, portable functional boundary and for low-rate
bring-up, but it is not a full-rate interface for either transceiver family.

Examples, before protocol/line-code overhead:

| PHY configuration | User clock | Bytes per PHY cycle | Current 1-byte/cycle node ceiling |
|---|---:|---:|---:|
| Acorn GTP, 2.5 Gb/s, 20-bit | 125 MHz | 2 | 1.0 Gb/s |
| Acorn GTP, 6.25 Gb/s, 40-bit | 156.25 MHz | 4 | 1.25 Gb/s |
| Tang SERDES, 10 Gb/s, 40-bit | 250 MHz | 4 | 2.0 Gb/s |

In the first bring-up profile, the symbol adapter transmits exactly one data
byte per PHY word and fills the remaining symbol slots with control/filler
symbols. The node's byte clock is the PHY word clock, so the table gives its
sustainable payload ceiling. The RX FIFO can absorb finite downstream stalls,
but it cannot absorb a peer that sends multiple data bytes per PHY word
continuously; both peers must use the same bring-up profile. This is not a
full-line-rate solution.

## First bring-up adapter

`rtl/bonded_phy_8b10b_adapter.sv` provides a vendor-neutral bridge for a
2-symbol (20-bit encoded) or 4-symbol (40-bit encoded) 8b/10b PHY word:

- TX places a unique K28.5 comma in symbol 0, one application byte (or a
  K28.0 empty marker) in symbol 1, and zero-valued data fillers in remaining
  slots. This gives the receiver an unambiguous word-alignment comma.
- RX validates that symbol pattern, strips the comma/empty/filler symbols and
  places the one data byte into a ready/valid FIFO.
- A non-stallable PHY source can use the internal RX FIFO and reports overflow
  if it cannot keep up. A synchronous stallable source can use the ready output.
  A vendor FIFO with delayed read-valid (such as the Gowin RX FIFO) needs its
  board wrapper to reserve space for all outstanding read-latency cycles before
  issuing another read; the ready output alone is not a credit for in-flight
  reads.
- Unexpected control characters or data in unused symbol positions set a
  sticky symbol-error indication. The board adapter should combine this with
  its PHY error/lock status and drive the node's sticky `laneN_rx_overflow`
  fault input.

This deliberately uses one data symbol per PHY word, matching the current
one-byte-per-cycle node. It provides a practical low-rate hardware bring-up
path without pretending to use the full transceiver bandwidth. The RTL
regression covers 2- and 4-symbol words, K28.5 alignment, K28.0 empty markers,
FIFO backpressure, non-stallable overflow and malformed symbol reporting.

## Recommended next architecture step

Before claiming multi-gigabit throughput, introduce a **parallel lane-word
interface** into the generic transport:

1. Parameterize the physical lane datapath by `PHY_DATA_WIDTH` and the
   corresponding per-byte control/keep information.
2. Keep PHY-specific primitives, PLLs, 8b/10b settings, comma alignment,
   polarity and clock/reset sequencing in separate adapters.
3. Process multiple bytes per cycle in the generic wire framing, demux,
   CRC and packet path. Merely packing a 40-bit PHY word into the existing
   8-bit, one-byte-per-cycle pipeline will not improve throughput.
4. Preserve the same v0 byte sequence on the wire so 20-bit and 40-bit
   adapters remain interoperable.
5. Verify width conversion, partial words, frame boundaries, clock skew,
   backpressure and CRC across at least 8-, 20-, 32- and 40-bit configurations.

The current 8-bit implementation remains the functional reference until the
parallel datapath has its own passing regression. Hardware bring-up can first
use a conservative line rate and then move to wider/faster operation once the
parallel path is verified.
