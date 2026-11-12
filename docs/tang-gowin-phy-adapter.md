# Tang Mega 138K Pro / Gowin Customized PHY adapter

## Board resources and clocking

The Tang Mega 138K Pro uses the GW5AST device. The two SFP+ cages route to
SERDES Quad Q1; the PCIe x4 interface uses Quad Q0. The GW5AT-138 SerDes has
two QPLLs and four CPLLs per quad; a QPLL can be shared by the four lanes in
that quad. The Gowin IP guide recommends QPLL for multi-lane use.

The two MS5351 clock generators provide reference clocks. The Sipeed
reference-clock procedure supports 100 MHz, 125 MHz and 156.25 MHz differential
outputs and selects the generator with the debugger UART command
`pll_switch 0` or `pll_switch 1`. The exact MS5351 output-to-Q1_REFCLK pin
mapping and selected output must be checked against the board schematic and
the generated IP constraints.

Do not infer the SFP line rate from the separate PCIe 8 GT/s x4 interface.

## Gowin fabric interface: exact 80/88-bit format

The Sipeed Customized PHY example exposes:

- TX data: 80 bits.
- RX data: 88 bits.
- Separate TX PCS and recovered RX PCS clocks.
- TX FIFO almost-full/full and write-enable.
- RX FIFO almost-empty/empty, read-enable, read-data-valid and occupancy.
- PLL lock, RX CDR lock, lane ready, K-lock and word-alignment status.

The Gowin IP guide defines the user fabric width as
`internal_width * external_ratio`. With a 20-bit internal datapath, ratio
1:2 gives a 40-bit TX / 44-bit RX interface (four symbols), while ratio1:4
gives an 80-bit TX / 88-bit RX interface (eight symbols). The RX bus is wider
because it also carries one decoder-error flag per symbol.

For the 8b/10b-enabled 80-bit TX bus, each of the eight 10-bit symbol slots is:

| Bits within symbol slot | Meaning |
|---|---|
| `[7:0]` | 8-bit data character |
| `[8]` | K-character indicator |
| `[9]` | Reserved / unused; drive zero |

For the 8b/10b-decoded 88-bit RX bus, each symbol's 10-bit slot has:

| Bits | Meaning |
|---|---|
| `[10*i +: 8]` | Decoded data byte for symbol `i` |
| `[10*i + 8]` | K-character indicator for symbol `i` |
| `[10*i + 9]` | Disparity error for symbol `i` |

The eight decoder-error flags are packed separately in `rx_data[87:80]`,
one bit per symbol. These mappings are from Gowin IPUG1024-1.7.1E, Tables
3-6 and 3-9.

The new `rtl/bonded_gowin_8b10b_word_adapter.sv` performs this exact mapping
for two, four or eight symbols per word. It maps the Gowin 10-bit TX slots to
generic data/K fields, and maps the RX data/K/disparity/decoder-error fields
back to generic data/K plus error vectors. Its regression checks both
four-symbol and eight-symbol mappings.

## Recommended common Acorn/Tang profile

A useful *candidate* common serial line rate is 5.0 Gb/s per lane. It is
within the Acorn GTP's documented line-rate ceiling and the Gowin PHY's
1--12.5 Gb/s range. With the Gowin IP configured for internal width20 and
ratio1:2, its user clock is 5.0 Gb/s / 40 = 125 MHz and the interface is
40-bit TX / 44-bit RX (four symbols). The Acorn GTP uses its 20-bit interface
(two symbols) and a 250 MHz user clock at the same 5.0 Gb/s line rate. The
user clocks are deliberately independent; the lane bridge handles them.

This is a candidate only: the Acorn 250 MHz timing path and the Gowin QPLL
configuration must pass their respective build/timing checks before adopting
it. The current Acorn target remains at its conservative 2.5 Gb/s default.

Use the Gowin IP with:

- Two independent lanes in SERDES Quad Q1.
- QPLL selected for both lanes, sharing the quad's QPLL resource.
- Internal data width 20.
- TX and RX external data ratio 1:2 for the common four-symbol profile
  (40-bit TX / 44-bit RX). Ratio 1:4 (80/88-bit, eight-symbol profile) is
  also supported by the generic mapper.
- 8b/10b TX encoding enabled.
- 8b/10b RX decoding enabled.
- RX word alignment enabled, using K28.5 as the alignment pattern.
- RX and TX channel bonding disabled in the PHY IP; packet-level bonding is
  performed by this project above the two independent lanes.
- RX clock correction disabled for the initial profile unless the generated
  IP requires it for the selected clocking mode.

The Sipeed example's checked-in `.ipc` files currently show
`ENABLE_ENCODING=false`, `ENABLE_DECODING=false`, and
`WORD_ALIGNMENT=false`, despite the example top-level logic using K-character
patterns. Those settings are not the recommended profile for this transport:
the generic adapter expects decoded bytes plus K flags. Generate a separate
IP configuration with encoding/decoding and RX word alignment enabled, then
verify the generated port list and timing report.

The line rate and reference-clock pair must be selected together in Gowin
Designer. For an 80-bit user word, the user clock is line-rate / 80. Thus
10.0 Gb/s corresponds to 125 MHz and 12.5 Gb/s corresponds to 156.25 MHz.
The checked-in Sipeed `12.5G` and `10.3125G` project configuration files
both currently report `TX_RATE=10`, `RX_RATE=10` and
`REFERENCE_CLOCK_FREQ=100`; do not treat the directory names as proof of
the configured line rate.

## RX FIFO and clock-domain adapter

The Gowin guide specifies that an RX FIFO read request produces valid data
after **three RX clock cycles**, and `rx_valid_o` indicates when
`rx_data_o` is valid. The read request and data-valid pulse are therefore
not a same-cycle ready/valid handshake.

Use the generic `rtl/bonded_phy_fifo_read_adapter.sv` between the Gowin RX
FIFO and the lane bridge:

- `fifo_empty` = Gowin RX FIFO empty flag.
- `fifo_rdreq` = Gowin RX FIFO read-enable.
- `fifo_data_valid` = Gowin `rx_valid_o`.
- `fifo_data` = Gowin 88-bit RX data.
- `out_valid/out_ready/out_data` = ready/valid word stream to the
  Gowin 88-to-72 mapper and then to the generic lane bridge.

The adapter reserves a word slot for every outstanding read request, so the
three-cycle response latency cannot overrun its output FIFO during downstream
backpressure. Configure it with `DATA_WIDTH=44` for the common four-symbol profile or
`DATA_WIDTH=88` for the eight-symbol profile; choose a depth large enough
for the expected read latency and local backpressure.

On TX, map the generic eight-symbol adapter to Gowin's TX FIFO:

- `tx_phy_ready = !tx_fifo_afull` (or use `!tx_fifo_full` if a more
  conservative margin is desired).
- `tx_fifo_wren = tx_phy_valid && tx_phy_ready`.
- `tx_fifo_data = gowin_tx_data[79:0]`.

The TX and RX bridge clock domains are separate. Use the Gowin TX PCS clock
for the TX bridge and the recovered RX PCS clock for the RX bridge. The Gowin
FIFO read/write clock inputs must be connected as required by the selected IP
clocking mode; do not assume the TX and RX clocks are identical.

## Generic bonded node integration

The generic RTL now accepts `SYMBOLS_PER_WORD=8` in its byte packer, 8b/10b
word adapter, lane bridge and two-lane node. The end-to-end two-node regression
is parameterized for 2-, 4- and 8-symbol PHY words. The safe initial setting
remains `PHY_DATA_BYTES_PER_WORD=1`: one payload byte per PHY word, with
K28.5 comma and K28.0 empty symbols. Do not enable eight payload bytes per
word in the integrated node until the complete multi-byte framing, reorder
and logical RX datapath is widened end to end.

## Board-wrapper responsibilities

The future `soc2soc/bonded_tang.py` wrapper should:

1. Instantiate two independent Gowin Customized PHY channels on SERDES Q1.
2. Select the same valid reference-clock/PLL profile for both lanes.
3. Export separate TX PCS clocks and recovered RX PCS clocks.
4. Map the 40-bit TX (or optional 80-bit) interface through the generic Gowin
   symbol mapper.
5. Map the 44-bit RX FIFO (or optional 88-bit) through the reservation-aware
   read adapter and corresponding RX symbol mapper.
6. Latch disparity/decoder errors in each recovered RX clock domain before
   crossing lane health into the bonding clock domain.
7. Feed PLL/CDR lock, lane-ready and K-lock/word-align status into local
   lane-up signals.
8. Keep all Gowin primitives and generated-IP dependencies outside the
   generic bonding RTL.

## Remaining checks before a Tang wrapper can be called build-ready

- Confirm the MS5351 output connected to SERDES Q1_REFCLK0/1 from the board
  schematic and choose the actual frequency.
- Generate the Gowin IP with 20-bit internal width, 1:4 ratio, 8b/10b encode
  and decode enabled, and RX word alignment enabled.
- Confirm the generated IP's exact port names, polarity and reset sequencing.
- Confirm that `rx_valid_o` is exactly three RX clock cycles after an
  accepted read request in the generated IP version.
- Run Gowin synthesis and timing, then PRBS/loopback and two-board tests.

No Tang bitstream or hardware has been validated yet.
