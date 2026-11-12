# Parallel RX payload-memory architecture

## Decision

Do not replace the current receiver buffer in-place until the candidate has
independent simulation coverage and a synthesis comparison. The current
byte-addressed frame store is a correctness reference, not a proven BRAM
implementation.

The preferred next implementation is a **header-register + word-wide payload
RAM** architecture. It preserves integrity-before-delivery: payload is not
presented downstream until the complete frame has passed header, frame CRC,
session, lane and sequence checks.

## Current implementation cost

For the default 4096-byte maximum payload, `frame_mem` contains
`24 + 4 + 4096 + 4 = 4128` bytes. Collection writes individual bytes from
each accepted input word. Output combinational logic can read up to four
different byte addresses in the same cycle.

That shape has two synthesis risks:

- Multiple byte writes in one clock may become byte-enable logic, replicated
  registers or a memory implementation with expensive write steering.
- Four independently addressed asynchronous byte reads are not a natural
  single-port block-RAM access pattern.

No inference claim can be made without a vendor synthesis report.

## Candidate organization

Keep the fixed-size protocol metadata in registers:

- 24-byte header (or only the fields needed after validation);
- four-byte packet-sequence prefix;
- incremental header CRC-16;
- incremental frame CRC-32C and four-byte rolling trailer;
- received byte count and expected payload length.

Store only payload bytes in a word-wide memory:

- Width: `DATA_WIDTH` (8, 16 or 32 bits).
- Depth: `ceil(MAX_PAYLOAD / (DATA_WIDTH/8))` words.
- Write address: payload byte offset divided by `WORD_BYTES`.
- Write data: incoming word lanes, with byte enables from the accepted KEEP
  mask intersected with the payload interval.
- Final-word KEEP: retain the actual number of payload bytes in the last word.
- No header, packet-sequence or CRC-trailer bytes consume payload RAM capacity.

The payload starts at wire offset 28. That offset is aligned to 1-, 2- and
4-byte words, so the existing supported widths do not require a cross-word
payload shifter. The receiver must nevertheless mask bytes outside the
payload interval; it must not assume a well-formed sender always separates
payload and trailer on word boundaries.

## Read pipeline and backpressure

Use a synchronous read port to give block RAM inference a realistic chance.
After the complete frame passes validation:

1. Issue a read for payload word zero.
2. Capture the RAM response into an output holding register.
3. Assert output VALID only when the holding register contains a word.
4. Keep DATA, KEEP, SOP and EOP stable while VALID is high and READY is low.
5. On a transfer, issue the next read only when the holding register can accept
   its response; do not advance the externally visible word index on a stall.
6. Derive EOP from the final payload word, including a partial final KEEP.
7. For a zero-byte payload, preserve the protocol's defined empty-payload
   representation without issuing a RAM read.

A small explicit read-pending state is preferable to a combinational memory
read. The implementation must define the one-cycle RAM response and output
register ownership precisely so a response cannot overwrite a stalled word.

## Collection and error handling

- Accept at most one word-wide payload write per input handshake.
- Continue calculating CRCs over the complete wire frame, including bytes
  outside the payload RAM region.
- A failed header, length, CRC, session, lane or sequence check must never
  expose bytes from the RAM.
- A new SOP while collecting abandons the prior candidate frame and restarts
  all metadata, CRC and payload write pointers.
- Reset during collection or output invalidates the pending frame and output
  holding register. RAM contents need not be cleared; valid state and pointers
  are sufficient to make old bytes unreachable.
- A frame that stops before EOP remains incomplete until a new SOP or reset.
  A protocol timeout is a separate policy decision; do not add an arbitrary
  cycle timeout to the RTL without a specified PHY/transport timeout contract.

## Required validation before replacement

1. Build the candidate as a separate module or branch of the implementation,
   leaving the existing full-frame receiver available as a reference.
2. Differentially compare both receivers for valid frames at 8, 16 and 32 bits.
3. Cover payload lengths 0, 1, WORD_BYTES-1, WORD_BYTES, WORD_BYTES+1,
   multiple full words, MAX_PAYLOAD-1 and MAX_PAYLOAD.
4. Cover stalls on the first, middle and final output word; assert stability
   of every output signal while stalled.
5. Corrupt header fields, header CRC, payload, trailer, session, lane and
   sequence independently; no failed frame may release payload.
6. Cover premature SOP, reset during collection, reset during output and
   incomplete frames.
7. Run synthesis for the target FPGA families and record RAM primitive count,
   LUT/FF count, maximum frequency and latency. Compare against the existing
   byte-addressed implementation.

## Current disposition

This is an implementation specification, not a claim that a word-wide RAM
has already been inferred. The current RTL remains unchanged until the
candidate can be compiled, simulated and compared. In particular, do not
enable the candidate in the bonded node based only on source-level inspection.


## Reusable synchronous payload RAM primitive

The first RTL building block is now isolated as `rtl/bonded_payload_word_ram.sv`.
It provides one word-wide write port with per-byte enables and a one-cycle
synchronous read port. The data array is not reset, preserving the possibility
of block-RAM inference; reset only invalidates the read response and clears its
output register.

The primitive is parameterized for 8-, 16-, and 32-bit words. Its focused
self-checking testbench covers independent addresses, byte-enable preservation,
read-valid timing, and reset without memory clearing. A dedicated GitHub Actions
matrix compiles and simulates all three widths.

This is deliberately **not yet connected** to
`bonded_wire_rx_lane_parallel`. The receiver still uses its existing byte
array until the primitive's CI evidence and a differential receiver test are
available. Same-address read/write behavior is not part of the contract because
the intended receiver writes during frame collection and reads only after
integrity validation.


## Experimental RAM-backed receiver candidate

`rtl/bonded_wire_rx_lane_parallel_ram.sv` is now a separate experimental
implementation. It keeps the 28-byte header and integrity metadata in
registers, writes only payload bytes into `bonded_payload_word_ram`, and
uses an explicit synchronous-read request/wait pipeline plus output holding
registers. The original byte-array receiver remains untouched as the reference.

The candidate has a parallel testbench derived from the reference receiver's
current regression cases. This is an initial independent regression, not yet
a true side-by-side differential comparison. Do not select the candidate for
the bonded endpoint until the dedicated CI matrix is green and a differential
test compares both implementations under identical input and backpressure.
