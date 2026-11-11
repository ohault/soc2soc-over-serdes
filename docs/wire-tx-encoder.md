# v0 DATA wire TX encoder

`bonded_wire_tx_lane` serializes one logical packet into the v0 DATA frame
envelope on one lane. It is framework- and vendor-neutral RTL.

## Input contract

The input is a packet stream using ready/valid, SOP/EOP and a low-contiguous
KEEP mask. Bytes within each input word are consumed least-significant byte
first. `in_packet_sequence` and `in_packet_length` are packet metadata and
must remain valid with the first beat. The caller supplies the complete packet
length (payload bytes only). Non-final beats must have every KEEP bit set;
the final beat may have a low-contiguous partial KEEP mask.

The upstream packet scheduler must provide a complete, well-formed packet and
the declared length must equal the number of accepted payload bytes. The
encoder flags a length mismatch through sticky `frame_error`; because header
bytes are streamed before the entire payload arrives, a mismatch can already
have put an invalid-length frame on the wire. Integrators must therefore use
the complete-packet scheduler/buffer as the admission boundary.

## Output format

For each accepted packet the encoder emits:
1. The 24-byte v0 header: magic, version, DATA type, flags, lane ID, header
   length, session ID, per-lane frame sequence, body length and CRC-16.
2. The 4-byte big-endian packet sequence prefix.
3. Payload bytes.
4. The 4-byte big-endian CRC-32C trailer.

The body length is payload length plus four bytes for packet_sequence. Header
CRC is CRC-16/CCITT-FALSE over header bytes 0..21. Frame CRC-32C covers the
entire 24-byte header (including header CRC) and body, excluding the trailer.
Output SOP marks the first magic byte; output EOP marks the final CRC byte.

The frame sequence increments only after the complete frame has been accepted
by the downstream byte stream. Session ID must be non-zero. DATA payload
length is limited to 4096 bytes.

## Verification

`tb_bonded_wire_tx_lane` checks a 35-byte golden frame generated
independently from the Python reference codec. It verifies every byte, both
CRC values as part of the complete vector, SOP/EOP placement and frame
sequence advancement.

This first RTL block implements DATA only. CONTROL encoding, RX parsing,
frame-boundary recovery, lane scheduling/credit integration and target FPGA
timing/resource validation remain separate tasks.
