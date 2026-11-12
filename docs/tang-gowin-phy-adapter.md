# Tang Mega 138K Pro / Gowin Customized PHY adapter plan

## Board resources and clocking

The Tang Mega 138K Pro uses the GW5AST-LV138FPG676A. The device provides
eight high-speed transceivers rated up to 12.5 Gb/s. The two SFP+ cages route
to SERDES Quad Q1; the PCIe x4 interface uses Quad Q0. Two MS5351 clock
generators provide reference clocks. The Sipeed reference-clock procedure
supports 100 MHz, 125 MHz and 156.25 MHz differential outputs and selects the
clock generator with the debugger UART command `pll_switch 0` or
`pll_switch 1`.

The clock output must be selected and measured/configured to match the
Gowin PHY PLL profile. Do not infer the SFP line rate from the board's
separate PCIe 8 GT/s x4 interface.

## Candidate PHY configuration

The Gowin Customized PHY supports configurable internal width and external
fabric width. Its documentation describes a 40-bit fabric datapath built
from a 20-bit internal interface with a 1:2 ratio. It also provides 8b/10b
encode/decode for supported 10-/20-bit internal widths. For a first
four-symbol adapter experiment, the candidate is:

- Two SFP+ lanes, each independently configured.
- 20-bit internal PHY datapath and 1:2 external data ratio.
- 40-bit external/fabric word, representing four 8b/10b symbols.
- 32 decoded data bits plus four K-character flags at the generic boundary.
- A 156.25 MHz user clock, if the selected line rate and 8b/10b profile
  calculate to that frequency (for example, 6.25 Gb/s at 40 encoded bits per
  user clock).

This is a candidate configuration, not a validated bitstream. The exact
generated-IP port widths, K-character flag polarity, word byte order, line
rate and PLL divider values must be checked against the generated Gowin IP
and its timing report before writing the board wrapper.

Enable RX word alignment required by 8b/10b decoding. Disable the PHY's
optional cross-lane channel-bonding feature for the initial experiment: this
project performs packet-level bonding, lane discovery, sequencing, credits
and reassembly above two independent PHY lanes.

## FIFO-style user interface

The Gowin PHY user interface is not assumed to be a ready/valid stream:

- TX writes are controlled by a write-enable and a FIFO-full indication.
- RX data is requested with a read-enable; returned data has a separate
  data-valid indication and a documented latency.
- The PHY wrapper must keep the TX and recovered RX clocks separate.
- Decoder code/disparity errors, PLL/CDR lock, TX/RX initialization status and
  FIFO overflow must be surfaced to the generic lane/session supervisor.

TX mapping is straightforward:

- `tx_phy_ready = !tx_fifo_full`.
- `tx_fifo_wr_en = tx_phy_valid && tx_phy_ready`.
- Drive the decoded data and K-character flag buses from the generic PHY
  adapter into the Gowin TX FIFO.

RX needs reservation-aware buffering. The generic lane bridge's
`rx_phy_ready` is a ready/valid capacity indication, but a Gowin read request
may return several clocks later. Issuing multiple reads based only on the
current ready signal can overrun the downstream FIFO when responses arrive.

The new generic module `rtl/bonded_phy_fifo_read_adapter.sv` converts a
read-enable/data-valid FIFO into a ready/valid stream. It reserves one output
slot for every outstanding read request, tracks responses until the
data-valid pulse arrives, and only issues another read when reserved capacity
is available. Its depth, data width and returned-data latency are independent
of Gowin and can be reused for other vendor FIFO interfaces. The regression
`rtl/tb_bonded_phy_fifo_read_adapter.sv` models a delayed response and
downstream backpressure.

For a four-symbol decoded interface, instantiate it with
`DATA_WIDTH=44` (32 data bits plus four control flags). Connect its
ready/valid output to the generic lane bridge with
`RX_PHY_STALLABLE=1`. The bridge must see decoded data and K flags, not raw
10-bit serial symbols. If the selected Gowin IP configuration exposes raw
encoded symbols instead, add a separate decoder stage before this adapter.

## Board-wrapper responsibilities

The future `soc2soc/bonded_tang.py` wrapper should:

1. Instantiate two independent Gowin Customized PHY channels on SERDES Q1.
2. Use one reference-clock source/profile consistently for both lanes.
3. Export separate TX user clocks and recovered RX user clocks.
4. Map TX FIFO full/write-enable and RX FIFO read-enable/data-valid through
   the generic FIFO adapter.
5. Latch decoder errors in each recovered RX clock domain before crossing
   lane health into the bonding clock domain.
6. Feed PLL/CDR lock and TX/RX initialization into the local lane-up signals.
7. Configure `SYMBOLS_PER_WORD=4` and keep
   `PHY_DATA_BYTES_PER_WORD=1` for the initial safe byte-wide node profile.
8. Keep all Gowin primitives and generated-IP dependencies outside the
   generic bonding RTL.

The one-byte-per-PHY-word profile is important: the current logical wire
framing and packet RX/application path is byte-wide. Do not enable four
payload bytes per PHY word in the integrated node until the complete
multi-byte datapath is implemented.

## Remaining checks before a Tang wrapper can be called build-ready

- Confirm the exact MS5351 output connected to SERDES Q1 and its selected
  156.25 MHz setting.
- Confirm the Gowin IP's external data/control widths and K-flag convention.
- Confirm RX FIFO read latency and whether data-valid can be asserted in the
  same cycle as read-enable.
- Confirm how the IP exposes per-symbol code/disparity errors and lock.
- Generate the PHY IP and inspect the actual Verilog ports before connecting
  the generic adapter.
- Run a Gowin synthesis/timing build, then PRBS/loopback and two-board tests.

No Tang hardware or generated Gowin IP has been validated by this document.
