#
# This file is part of soc2soc-over-serdes.
#
# SPDX-License-Identifier: BSD-2-Clause

# SerWB Stream Port: 32-bit streaming between two SoCs over a SerWB link, alongside the memory-mapped
# (register access) port, with credit-based flow control.
#
#   SoC A                                                      SoC B
#   sink ──▶ chunker ──▶ [credits] ──▶ SerWB port 1 ═════▶ RX buffer ──▶ source
#   source ◀── RX buffer ◀═════ SerWB port 1 ◀── [credits] ◀── chunker ◀── sink
#
# - Each side has a ``sink`` (local -> remote) and a ``source`` (remote -> local): the port is
#   bidirectional and symmetric, independent of the initiator/target role of the link.
# - Stream data is cut into chunks of at most ``max_packet_words`` words (a chunk also ends on
#   ``last``, or after ``flush_timeout`` cycles without new data) and sent as one SerWB packet:
#     DATA   : header word (type=0, [0] = chunk ends a frame), then the chunk words.
#     CREDIT : single word (type=1, [15:0] = number of freed RX buffer words).
#   Header type is in bits [31:28].
# - Credit-based flow control: a chunk is only sent when the remote RX buffer has room for it, so
#   received stream data never stalls the SerWB link: a slow (or stopped) stream consumer only
#   pauses the stream, register accesses keep working. The receiver returns credits when its buffer
#   is drained (at least ``credit_threshold`` words, or after ``credit_timeout`` cycles).
# - ``last`` (frame boundaries) is preserved end to end.
# - On link loss, the TX buffers are flushed (data not yet sent is lost, a frame in flight can be
#   truncated) and the sink is stalled until the link is back. Data already received in the RX
#   buffer is kept, and the RX buffer space is re-advertised on link up.
#
# Both sides of a link must enable the stream port with the same ``port``.

from migen import *

from litex.gen import *

from litex.soc.interconnect     import stream
from litex.soc.interconnect.csr import *

from liteiclink.serwb.packet import packet_description

# Constants ----------------------------------------------------------------------------------------

STREAM_PORT        = 1
STREAM_TYPE_DATA   = 0
STREAM_TYPE_CREDIT = 1

# SerWB Stream Port --------------------------------------------------------------------------------

class SerWBStreamPort(LiteXModule):
    def __init__(self, core, ready, port=STREAM_PORT,
        rx_buffer_depth  = 512,
        max_packet_words = 64,
        credit_threshold = None,
        credit_timeout   = 256,
        flush_timeout    = 64):
        assert 1 <= max_packet_words <= 1024
        assert max_packet_words <= rx_buffer_depth < 2**16
        if credit_threshold is None:
            credit_threshold = min(max_packet_words, rx_buffer_depth//4)
        self.max_packet_words = max_packet_words

        self.sink   = sink   = stream.Endpoint([("data", 32)]) # Local -> Remote.
        self.source = source = stream.Endpoint([("data", 32)]) # Remote -> Local.

        # Status (sys domain).
        self.tx_credits   = tx_credits   = Signal(17) # Words the remote can accept.
        self.rx_overflows = rx_overflows = Signal(32) # RX words lost (credit protocol violation).
        self.tx_words     = tx_words     = Signal(32) # Words sent.
        self.rx_words     = rx_words     = Signal(32) # Words received.

        # # #

        # SerWB endpoints.
        # ----------------
        tx = stream.Endpoint(packet_description(32))
        rx = stream.Endpoint(packet_description(32))
        core.add_downstream_endpoint(port=port, endpoint=tx)
        core.add_upstream_endpoint(  port=port, endpoint=rx)

        # Shared signals.
        credit_add   = Signal(16) # Credits received from remote (pulse).
        credits_ret  = Signal(17) # Credits to return to remote.
        credit_value = Signal(16) # Credits sent in current CREDIT packet.
        credit_sent  = Signal()
        data_sent    = Signal()

        # TX ---------------------------------------------------------------------------------------

        # Buffering.
        # ----------
        self.tx_data = tx_data = ResetInserter()(stream.SyncFIFO([("data", 32)], 2*max_packet_words, buffered=True))
        self.tx_desc = tx_desc = ResetInserter()(stream.SyncFIFO([("count", 16), ("eof", 1)], 8))
        self.comb += [
            tx_data.reset.eq(~ready),
            tx_desc.reset.eq(~ready),
        ]

        # Chunker: cut the stream in chunks (descriptors: word count + end of frame).
        # ---------------------------------------------------------------------------
        accept      = Signal()
        close       = Signal()
        chunk_count = Signal(16)
        idle_timer  = Signal(max=flush_timeout + 1, reset=flush_timeout)
        self.comb += [
            sink.ready.eq(ready & tx_data.sink.ready & tx_desc.sink.ready),
            accept.eq(sink.valid & sink.ready),
            tx_data.sink.valid.eq(accept),
            tx_data.sink.data.eq(sink.data),
            If(accept,
                If(sink.last | (chunk_count == (max_packet_words - 1)),
                    close.eq(1),
                    tx_desc.sink.count.eq(chunk_count + 1),
                    tx_desc.sink.eof.eq(sink.last),
                )
            ).Elif((chunk_count != 0) & (idle_timer == 0) & tx_desc.sink.ready,
                # Flush partial chunk.
                close.eq(1),
                tx_desc.sink.count.eq(chunk_count),
                tx_desc.sink.eof.eq(0),
            ),
            tx_desc.sink.valid.eq(close),
        ]
        self.sync += [
            If(~ready | close,
                chunk_count.eq(0),
                idle_timer.eq(flush_timeout),
            ).Elif(accept,
                chunk_count.eq(chunk_count + 1),
                idle_timer.eq(flush_timeout),
            ).Elif(idle_timer != 0,
                idle_timer.eq(idle_timer - 1),
            )
        ]

        # Credit return timer.
        # --------------------
        credit_timer   = Signal(max=credit_timeout + 1, reset=credit_timeout)
        credit_pending = Signal()
        self.comb += credit_pending.eq((credits_ret >= credit_threshold) |
                                       ((credits_ret != 0) & (credit_timer == 0)))
        self.sync += [
            If(~ready | credit_sent | (credits_ret == 0),
                credit_timer.eq(credit_timeout)
            ).Elif(credit_timer != 0,
                credit_timer.eq(credit_timer - 1)
            )
        ]

        # Sender FSM.
        # -----------
        remaining = Signal(16)
        self.fsm = fsm = ResetInserter()(FSM(reset_state="IDLE"))
        self.comb += fsm.reset.eq(~ready)
        fsm.act("IDLE",
            # Credits first (small, keep the remote flowing).
            If(credit_pending,
                NextValue(credit_value, credits_ret[:16]),
                NextState("CREDIT")
            ).Elif(tx_desc.source.valid & (tx_credits >= tx_desc.source.count),
                NextState("HEADER")
            )
        )
        fsm.act("CREDIT",
            tx.valid.eq(1),
            tx.last.eq(1),
            tx.length.eq(4),
            tx.data[ 0:16].eq(credit_value),
            tx.data[28:32].eq(STREAM_TYPE_CREDIT),
            If(tx.ready,
                credit_sent.eq(1),
                NextState("IDLE")
            )
        )
        fsm.act("HEADER",
            tx.valid.eq(1),
            tx.length.eq(4*(tx_desc.source.count + 1)),
            tx.data[0].eq(tx_desc.source.eof),
            tx.data[28:32].eq(STREAM_TYPE_DATA),
            If(tx.ready,
                data_sent.eq(1),
                NextValue(remaining, tx_desc.source.count),
                NextState("DATA")
            )
        )
        fsm.act("DATA",
            tx.valid.eq(tx_data.source.valid),
            tx.length.eq(4*(tx_desc.source.count + 1)),
            tx.last.eq(remaining == 1),
            tx.data.eq(tx_data.source.data),
            tx_data.source.ready.eq(tx.ready),
            If(tx.valid & tx.ready,
                NextValue(remaining, remaining - 1),
                If(tx.last,
                    tx_desc.source.ready.eq(1),
                    NextState("IDLE")
                )
            )
        )

        # TX credits.
        # -----------
        self.sync += [
            If(~ready,
                tx_credits.eq(0)
            ).Else(
                tx_credits.eq(tx_credits + credit_add - Mux(data_sent, tx_desc.source.count, 0))
            ),
            If(tx_data.source.valid & tx_data.source.ready & (tx_words != (2**32 - 1)),
                tx_words.eq(tx_words + 1)
            )
        ]

        # RX ---------------------------------------------------------------------------------------

        # Buffering.
        # ----------
        self.rx_buffer = rx_buffer = stream.SyncFIFO([("data", 32)], rx_buffer_depth, buffered=True)
        self.comb += rx_buffer.source.connect(source)

        # Parser.
        # -------
        rx_header  = Signal(reset=1) # Next word is a packet header.
        rx_is_data = Signal()
        rx_eof     = Signal()
        self.comb += [
            rx.ready.eq(1), # Never stall the link: room is guaranteed by the credits.
            If(rx.valid & rx_header & (rx.data[28:32] == STREAM_TYPE_CREDIT),
                credit_add.eq(rx.data[0:16])
            ),
            rx_buffer.sink.valid.eq(rx.valid & ~rx_header & rx_is_data),
            rx_buffer.sink.data.eq(rx.data),
            rx_buffer.sink.last.eq(rx.last & rx_eof),
        ]
        self.sync += [
            If(~ready,
                rx_header.eq(1)
            ).Elif(rx.valid,
                rx_header.eq(rx.last),
                If(rx_header,
                    rx_is_data.eq(rx.data[28:32] == STREAM_TYPE_DATA),
                    rx_eof.eq(rx.data[0]),
                )
            ),
            If(rx_buffer.sink.valid,
                If(~rx_buffer.sink.ready,
                    If(rx_overflows != (2**32 - 1), rx_overflows.eq(rx_overflows + 1))
                ).Elif(rx_words != (2**32 - 1),
                    rx_words.eq(rx_words + 1)
                )
            )
        ]

        # Credits to return (freed RX buffer words).
        # ------------------------------------------
        pop = Signal()
        self.comb += pop.eq(source.valid & source.ready)
        self.sync += [
            If(~ready,
                # Link down: advertise the free RX buffer space on link up.
                credits_ret.eq(rx_buffer_depth - rx_buffer.level + pop)
            ).Else(
                credits_ret.eq(credits_ret + pop - Mux(credit_sent, credit_value, 0))
            )
        ]
        self.rx_level = rx_buffer.level

    def add_csr(self):
        self._tx_credits   = CSRStatus(17, description="Remote RX buffer words available (TX credits).")
        self._rx_level     = CSRStatus(len(self.rx_level), description="Local RX buffer level (words).")
        self._tx_words     = CSRStatus(32, description="Stream words sent (saturating).")
        self._rx_words     = CSRStatus(32, description="Stream words received (saturating).")
        self._rx_overflows = CSRStatus(32, description="Stream words lost on RX (should stay 0).")

        # # #

        self.comb += [
            self._tx_credits.status.eq(self.tx_credits),
            self._rx_level.status.eq(self.rx_level),
            self._tx_words.status.eq(self.tx_words),
            self._rx_words.status.eq(self.rx_words),
            self._rx_overflows.status.eq(self.rx_overflows),
        ]

# Stream Tester ------------------------------------------------------------------------------------

class StreamTester(LiteXModule):
    """Stream traffic generator/checker (32-bit counter, frames of ``frame_words`` words).

    The checker resynchronizes on the first received word after being enabled; ``rx_throttle``
    accepts one word every ``rx_throttle + 1`` cycles (slow consumer, exercises the flow control).
    """
    def __init__(self):
        self.source = source = stream.Endpoint([("data", 32)]) # To stream port sink.
        self.sink   = sink   = stream.Endpoint([("data", 32)]) # From stream port source.

        self._control = CSRStorage(fields=[
            CSRField("tx_enable", size=1, description="Generate counter traffic."),
            CSRField("rx_enable", size=1, description="Check received traffic (resync when enabled)."),
        ])
        self._frame_words = CSRStorage(16, reset=256, description="TX frame length in words (``last`` every N words).")
        self._rx_throttle = CSRStorage(16, description="RX: accept one word every N+1 cycles (0: full speed).")
        self._tx_words    = CSRStatus(32, description="Words generated.")
        self._rx_words    = CSRStatus(32, description="Words checked.")
        self._rx_errors   = CSRStatus(32, description="Data errors (unexpected word).")
        self._rx_frame_errors = CSRStatus(32, description="Frame errors (``last`` at unexpected position).")

        # # #

        tx_enable   = self._control.fields.tx_enable
        rx_enable   = self._control.fields.rx_enable
        frame_words = self._frame_words.storage

        # Generator.
        # ----------
        tx_counter = Signal(32)
        tx_index   = Signal(16)
        self.comb += [
            source.valid.eq(tx_enable),
            source.data.eq(tx_counter),
            source.last.eq(tx_index == (frame_words - 1)),
        ]
        self.sync += [
            If(source.valid & source.ready,
                tx_counter.eq(tx_counter + 1),
                tx_index.eq(Mux(source.last, 0, tx_index + 1)),
                self._tx_words.status.eq(self._tx_words.status + 1),
            )
        ]

        # Checker.
        # ---------
        throttle     = Signal(16)
        expected     = Signal(32)
        synced       = Signal()
        rx_index     = Signal(16)
        frame_synced = Signal()
        self.comb += sink.ready.eq(~rx_enable | (throttle == 0))
        self.sync += [
            If(~rx_enable | (throttle == 0),
                If(sink.valid, throttle.eq(self._rx_throttle.storage))
            ).Else(
                throttle.eq(throttle - 1)
            ),
            If(~rx_enable,
                synced.eq(0),
                frame_synced.eq(0),
            ).Elif(sink.valid & sink.ready,
                synced.eq(1),
                expected.eq(sink.data + 1),
                self._rx_words.status.eq(self._rx_words.status + 1),
                If(synced & (sink.data != expected),
                    self._rx_errors.status.eq(self._rx_errors.status + 1)
                ),
                # Frames: after the first ``last``, one ``last`` every frame_words words.
                If(sink.last,
                    frame_synced.eq(1),
                    rx_index.eq(0),
                    If(frame_synced & (rx_index != (frame_words - 1)),
                        self._rx_frame_errors.status.eq(self._rx_frame_errors.status + 1)
                    )
                ).Else(
                    rx_index.eq(rx_index + 1),
                    If(frame_synced & (rx_index == (frame_words - 1)),
                        self._rx_frame_errors.status.eq(self._rx_frame_errors.status + 1)
                    )
                ),
            )
        ]
