# Parallel lane-word interface proposal

## Motivation

The current node consumes and emits one byte per lane clock. The generic
8b/10b bring-up adapter maps one byte into a 2- or 4-symbol PHY word and fills
the rest with control/filler symbols. This is portable and useful for initial
hardware bring-up, but it leaves most of a 20-/40-bit transceiver interface
unused.

The next performance step is to process multiple bytes per lane clock without
changing the v0 DATA/CONTROL byte sequence.

## PHY word format

For 8b/10b PHYs, use one K28.5 comma at symbol 0 of each frame-start word:

- Idle word: symbol 0 is K28.5; all remaining symbols are K28.0 empty markers.
- Frame-start word: symbol 0 is K28.5; symbols 1..N-1 carry the first
  N-1 frame bytes, with K28.0 in unused trailing positions.
- Continuation word: symbols 0..N-1 carry frame bytes; unused trailing
  positions in the final word use K28.0.
- Data bytes always use the 8b/10b data-character indication, even when the
  byte value happens to equal 0xBC or 0x1C. Only control-character indications
  identify K28.5/K28.0.

The comma is a PHY-level alignment marker and is removed before the v0 byte
stream reaches the generic wire parser. It is not included in CRCs or packet
lengths. A new comma at each frame start also gives the receiver a recovery
point after a truncated frame.

## Internal lane-word handshake

The generic wide lane interface should carry:

- `valid/ready`
- `data[PHY_DATA_WIDTH-1:0]`
- `keep[PHY_DATA_WIDTH/8-1:0]`
- `sop` on the first word of a wire frame

The byte order is little-endian: byte 0 is the least-significant byte slice.
For a 40-bit encoded PHY word (four 8b/10b symbols), the decoded data bus is
32 bits wide with four control-character flags. The first frame word has
three valid data bytes because symbol 0 is the comma; continuation words can
carry four bytes.

For a 20-bit encoded PHY word (two symbols), the decoded data bus is 16 bits
wide. The first frame word carries one data byte after the comma; continuation
words carry two bytes.

The RX adapter removes control characters and emits data words with a keep
mask and SOP indication. The wire parser still validates the v0 header CRC,
length and frame CRC; the PHY comma does not replace protocol-level checks.

## TX/RX adapter requirements

1. TX inserts K28.5 at frame start and during idle. It inserts K28.0 in unused
   positions of partial words. It never marks payload bytes as control symbols.
2. RX recognizes K28.5 only when its control flag is set, so payload byte
   values cannot create false commas.
3. RX removes K28.5/K28.0 and preserves all payload bytes in order.
4. The adapter must support ready/valid backpressure or buffer the decoded
   words when the PHY source cannot stall.
5. A malformed symbol word, disparity/code error, FIFO overrun or loss of
   word alignment must invalidate the lane/session.
6. A new SOP while a frame is open must abandon the truncated frame and
   restart parsing at the new frame boundary.
7. The implementation must support both two-symbol and four-symbol PHY
   words, with the same byte sequence and CRC results.

## Integration strategy

Keep the current byte-wide node and `bonded_phy_8b10b_adapter` as the simple
reference/bring-up path. Implement the parallel adapter and parallel wire
framing as a separate path first, with standalone regressions. Do not silently
change the existing byte-wide modules or claim full-rate support until the
parallel two-node simulation passes.

The target configurations are:

- Acorn GTP: two or four 8b/10b symbols per user clock (20-/40-bit encoded
  datapath), using LiteICLink only in the board wrapper.
- Tang Mega 138K Pro: a four-symbol 8b/10b user datapath using Gowin Customized
  PHY only in the board wrapper.

The bonding scheduler, packet sequence space, cumulative credits, session
manager and application packet interface remain independent of the PHY word
width.
