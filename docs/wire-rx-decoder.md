# v0 DATA wire RX decoder

`bonded_wire_rx_lane` is a framework-neutral, byte-stream receiver for one
physical lane. It accepts one byte per ready/valid transfer, with SOP on the
first frame byte and EOP on the final CRC byte.

## Validation and release boundary

The decoder buffers one complete frame (up to 24 + 4 + MAX_PAYLOAD + 4
bytes). It releases no payload until all of the following checks pass:

- magic, version, DATA frame type, reserved flags and 24-byte header length;
- configured lane ID and expected non-zero session ID;
- exact expected per-lane frame sequence (no wrap);
- CRC-16/CCITT-FALSE over header bytes 0..21;
- body length between 4 and 4 + MAX_PAYLOAD;
- exact received frame length, including the 4-byte trailer;
- CRC-32C over header and body.

After validation, it emits the DATA packet sequence and payload as a byte
ready/valid stream. SOP/EOP delimit the payload. For a legal zero-length DATA
payload, the byte-stream interface emits one zero-valued SOP/EOP marker; a
future packet-level interface may represent empty packets without this marker.

A malformed/truncated frame sets sticky `frame_error` (cleared by reset).
A new SOP while collecting discards the incomplete frame and starts a fresh
candidate frame, providing a clear resynchronization boundary. Frames with a
bad CRC or wrong session/lane/sequence are discarded without payload leakage.
The receiver accepts the next expected frame sequence only; recovery from a
lost frame is a session-level responsibility in v0.

## Verification

`tb_bonded_wire_rx_lane` uses the same complete 35-byte golden frame as the
TX regression. The vector is independently generated from the Python v0
codec. The test checks packet sequence, frame sequence, payload bytes and
SOP/EOP. It then corrupts the CRC trailer and verifies that no payload is
released.

The implementation currently supports DATA frames only. CONTROL frame parsing,
per-lane CONTROL queues, packet reorder across lanes, credit accounting,
diagnostic counters and physical-lane reset/epoch integration remain future
work. The single-frame buffer also means input collection pauses while the
validated payload is being drained; throughput optimization and RAM inference
are not yet addressed.
