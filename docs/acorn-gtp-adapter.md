# Acorn CLE-215+ / LiteICLink GTP adapter plan

## Scope

This is the first board-specific PHY wrapper for the board-neutral
`bonded_two_lane_phy_word_node`. It must be a separate target or an explicitly
selected alternative to the existing SerWB/`GTPSoCLink` target. Do not
instantiate a second GTP on an SFP cage already owned by the existing link.

The generic bonding RTL remains free of LiteX, Migen, LiteICLink and Xilinx
primitives. The adapter owns only GTP creation, clock/reset mapping, decoder
error reporting and the PHY stream pin mapping.

## Existing Acorn implementation facts

The current `soc2soc/serdes_link.py` constructs each GTP with:

- `data_width=20`: two 8b/10b symbols per user-clock word.
- TX and RX elastic buffers enabled.
- GTP comma alignment enabled by the transceiver; no extra LiteICLink clock
  aligner is instantiated for this link.
- `GTPQuadPLL` shared by the two SFP channels.
- Independent TX and RX clock domains, renamed per SFP channel.

The LiteICLink GTP stream endpoint is:

- TX `sink.data[15:0]`: two data bytes, byte 0 in bits 7:0.
- TX `sink.ctrl[1:0]`: one K-character flag per byte.
- RX `source.data[15:0]` and `source.ctrl[1:0]`: decoded symbols and K flags.
- `sink.ready` is tied high and `source.valid` is tied high by
  `GTP.add_stream_endpoints()`. The endpoint itself has no per-word
  backpressure.

The GTP exposes `tx_ready`, `rx_ready`, and per-symbol decoder
`invalid` indications. The first two indicate transceiver initialization
completion; they are the starting point for the local lane-up signal, while
decoder invalid indications must also invalidate the lane/session.

## Generic node mapping

For each of the two SFP channels:

| Generic node port | LiteICLink GTP signal |
|---|---|
| `laneN_tx_clk` | GTP TX user clock domain |
| `laneN_tx_rst_n` | inverse of local TX-domain reset |
| `laneN_phy_tx_data[15:0]` | `serdes.sink.data` |
| `laneN_phy_tx_ctrl[1:0]` | `serdes.sink.ctrl` |
| `laneN_phy_tx_ready` | `serdes.sink.ready` (constant 1) |
| `laneN_rx_clk` | GTP recovered RX user clock domain |
| `laneN_rx_rst_n` | inverse of local RX-domain reset |
| `laneN_phy_rx_valid` | `serdes.source.valid` (constant 1) |
| `laneN_phy_rx_data[15:0]` | `serdes.source.data` |
| `laneN_phy_rx_ctrl[1:0]` | `serdes.source.ctrl` |
| `laneN_up` | TX ready AND RX ready AND no latched decoder error |

Use `SYMBOLS_PER_WORD=2`, `RX_PHY_STALLABLE=0`, and
`PHY_DATA_BYTES_PER_WORD=1` for the initial Acorn integration. The GTP
source cannot be stalled. The one-byte-per-word setting matches the current
byte-wide wire framing pipeline and avoids the RX FIFO overrun that would
occur if two decoded bytes per clock were sent into a one-byte-per-clock
consumer.

This profile is a safe protocol bring-up configuration, not maximum GTP
throughput. Full two-byte-per-clock operation requires the wire TX/RX framing
and packet paths to be widened end to end first.

## Decoder error handling

The two `Decoder.invalid` flags are in the recovered RX clock domain. Latch
their OR in that domain until the physical RX reset. Feed the sticky result
into the lane-up decision so the generic node's normal lane/session
supervision sees a persistent lane drop. Do not pass a one-cycle asynchronous
error pulse directly into the bonding clock domain.

The generic word adapter separately checks illegal K-character placement,
comma alignment and malformed empty-symbol placement. Those checks do not
replace the GTP decoder's code/disparity error flags. The wrapper exposes the
latched GTP decoder error and per-lane readiness for diagnostics. The sticky
GTP decoder latch clears only when the GTP RX domain is reset; for the first
prototype, use the GTP RX-enable CSR from `add_base_control()` to restart that
receiver after a decoder fault. The node then re-negotiates a new session when
both lanes are ready again.

## Clock and reset rules

- Keep the bonding/control clock independent of the GTP TX and recovered RX
  clocks.
- Each SFP channel has its own TX and RX user-clock domain.
- Never use the TX user clock for RX decoding.
- Reset assertion may be asynchronous, but release must be synchronized in
  each local user-clock domain.
- The two physical lanes may share a QPLL but must not share recovered RX
  clocks.
- The GTP RX source is continuous; configure the generic RX adapter as
  non-stallable and rely on its buffering plus the byte-wide one-byte profile.

## Implementation status

A first LiteX/Migen wrapper prototype is now present in
`soc2soc/bonded_acorn.py`. It instantiates two 20-bit LiteICLink GTP channels,
uses independent per-lane TX and recovered-RX clocks, maps the two data and K
control bits, latches GTP decoder-invalid indications in the RX clock domain,
and connects the generic two-lane RTL node. It defaults to the safe
one-byte-per-PHY-word mode. The existing SerWB target is not modified.

The separate `acorn_bonded.py` target now reuses the established CRG/QPLL
setup while leaving the existing SerWB target unchanged. The image starts the
control plane but leaves application DATA idle; a packet generator/checker is
still needed. The wrapper and target have not yet been imported in a LiteX
build, elaborated to Verilog, synthesized or hardware-tested. The next steps
are:

1. Elaborate the target in a LiteX environment and verify both SFP channels
   map to the correct GTP clocks and byte/control slices.
2. Add a hardware-free packet generator/checker for bidirectional DATA tests.
3. Run the full RTL CI suite before attempting Vivado synthesis.
4. Check GTP PLL lock, TX/RX initialization, PRBS, polarity, comma alignment,
   and sustained one-byte-per-word traffic on hardware.

## Separate Acorn bring-up target

The target `acorn_bonded.py` reuses the existing Acorn CRG and shared QPLL,
but leaves the legacy SerWB GTP links uninstantiated. It creates the two GTP
channels through `AcornBondedSerdes` and connects a bidirectional fixed-size
packet pattern generator/checker. Traffic starts after the HELLO/READY session
has been active for a short settling interval.

Build one image per peer with complementary identities and the same initial
session seed:

```sh
# Board A
./acorn_bonded.py --build --peer-id=1 --expected-peer-id=2 --session-id=1

# Board B
./acorn_bonded.py --build --peer-id=2 --expected-peer-id=1 --session-id=1
```

Both SFP ports on each board belong to this bonded transport. Connect both DAC
cables between the boards; either straight or crossed lane wiring is supported
by dynamic remote lane-ID discovery. The default polarity values are inherited
from the existing Acorn target and may need to be verified with PRBS.

LED1 and LED2 indicate local lane readiness; LED3 remains the QPLL lock
indicator. The `bond_status` CSR reports session-active, control-fault, both
local lane-up bits, packet-test errors, PHY errors and GTP decoder errors.
The `bond_tx_packets` and `bond_rx_packets` CSRs expose packet counts. Each
board sends 64-byte packets whose contents depend on its peer ID and packet
counter; the opposite board checks every received byte and packet boundary.

No board-specific wrapper is hardware-validated by this document.
