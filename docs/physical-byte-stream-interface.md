# Physical byte-stream adapter contract

The bonding core does not directly instantiate a vendor transceiver, SFP
controller or board-specific SERDES primitive. The board adapter presents one
independent byte stream per physical lane.

## TX boundary

For each lane, the node exposes:

- `laneN_tx_valid`
- `laneN_tx_ready`
- `laneN_tx_data[7:0]`

The autonomous node intentionally does not expose SOP/EOP on its physical TX
ports. The lower-level endpoint has those internal sidebands, but **they are
not transmitted over the serial cable.** The physical adapter serializes only
the data bytes and must preserve their order without dropping or duplicating
bytes. A small TX elastic buffer is appropriate if the transceiver cannot
accept a byte on every cycle.

## RX boundary

For each lane, the node accepts only:

- `laneN_rx_valid`
- `laneN_rx_ready`
- `laneN_rx_data[7:0]`
- `laneN_rx_overflow` (adapter error indication)

There are no physical SOP/EOP inputs. A per-lane synchronous elastic FIFO
(`bonded_sync_byte_fifo`, configurable depth) absorbs parser stalls and uses
standard ready/valid semantics. A continuous serial receiver cannot pause
the cable, so the board adapter must buffer recovered bytes until the node
accepts them. If the adapter's own receive buffer overruns or a byte is lost,
it must assert the corresponding `laneN_rx_overflow` input; the autonomous
node propagates this through the lane RX frame error output and synchronizes
the overrun into the bonding clock domain as a lane-down event, invalidating
the current session. It must never
silently discard a byte and continue. The `bonded_wire_rx_framer` then:

1. Searches the raw byte stream for the v0 magic/version/type prefix.
2. Captures the 24-byte header.
3. Validates header CRC-16 before trusting the body length.
4. Rescans the captured header if a false prefix is encountered.
5. Replays the header with a generated SOP.
6. Streams the body and CRC, generating EOP from the validated header length.

The downstream demultiplexer routes DATA and CONTROL to independent decoders.

## What the board-specific adapter must provide

The adapter around the FPGA transceiver must implement the vendor-specific
parts, while preserving the byte-stream contract:

- CDR / recovered clock and transceiver reset sequencing.
- Byte alignment and any required 8b/10b or other line-code decoding.
- A stable 8-bit byte order and no silent byte loss or duplication.
- TX serialization and any required line coding.
- A reliable `lane_up` indication based on PLL/CDR lock, byte alignment and
  the chosen physical error policy. The node synchronizes this status into
  its bonding clock domain.
- Error/overflow handling: a PHY error, adapter RX-buffer overflow
  (`laneN_rx_overflow`) or byte-alignment loss must drop the lane/session or reset the framer so the
  receiver does not continue parsing a corrupted byte count.

The core currently assumes an error-free byte stream between such reset/error
events. It does not yet provide an arbitrary byte-deletion recovery protocol
inside a frame. The physical adapter must surface uncorrectable link errors.

## Initial hardware target

The first implementation target remains two independent SFP/DAC byte lanes.
The same byte-stream adapter contract should be usable by both the LiteX Acorn
Baseboard Mini and the Sipeed Tang Mega 138K Pro Dock, with only the transceiver
primitive, reference clocks, resets and pin constraints being board-specific.

The raw-byte two-node simulation deliberately does not transmit SOP/EOP
sidebands across its virtual cables; it exercises the same boundary expected
from the real SERDES adapter.
