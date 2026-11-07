#
# This file is part of soc2soc-over-serdes.
#
# SPDX-License-Identifier: BSD-2-Clause

# SerWB native MMAP Slave with read prefetch.
#
# LiteICLink's SERWBMMAPSlave sends one read request per Wishbone read and waits for its response:
# reads are limited to 4 bytes per link round trip (~5 MB/s). The native protocol supports read
# requests of up to burst_depth words, so when prefetch is enabled, a read miss requests the words
# from the read address up to the end of its burst_depth-aligned block, and the next sequential reads
# are served from the buffer as soon as the words are received.
#
# - Once a sequential stream is detected, the next block is requested while the current one is
#   being received/consumed (look-ahead, up to 2 responses outstanding), so the link round trip
#   overlaps with the consumption. Look-ahead never crosses a ``lookahead_boundary`` (4KB): memories
#   are normally 4KB-aligned multiples, so it never reads past the end of one into unmapped space,
#   where each word would wait for the remote bus timeout.
# - Prefetch is enabled by the ``prefetch`` signal (e.g. a CSR): only enable it on regions without
#   read side effects (memories), since prefetched words are read on the remote bus.
# - The buffer is discarded on any write or non-sequential read (no stale data from before a local
#   write). Remote changes between the prefetch and the reads are not seen (as with any cache).
# - Blocks never cross a burst_depth-aligned boundary, so prefetching from the last block of a memory
#   does not read past its end if its size is a multiple of the block size. If a block returns a bus
#   error, the read is retried as a single-word read, so errors are reported as without prefetch. A
#   failed look-ahead block only ends the stream (the next read misses and is retried).
#
# Same interface and write path as SERWBMMAPSlave (protocol compatible with SERWBMMAPMaster).

from migen import *

from litex.gen import *
from litex.gen.genlib.misc import WaitTimer

from litex.soc.interconnect import stream
from litex.soc.interconnect import wishbone

from liteiclink.serwb.packet import packet_description
from liteiclink.serwb.mmap   import MMAP_MAGIC, MMAP_OP_WRITE, MMAP_OP_READ
from liteiclink.serwb        import core as serwb_core_module
from liteiclink.serwb.core   import SERWBCore

# SerWB MMAP Slave with Prefetch -------------------------------------------------------------------

class SERWBMMAPSlavePrefetch(LiteXModule):
    def __init__(self, burst_depth=4, coalescing_timeout=4, lookahead_boundary=4096):
        assert 1 <= burst_depth <= 256
        assert burst_depth & (burst_depth - 1) == 0, "burst_depth must be a power of 2."
        assert lookahead_boundary & (lookahead_boundary - 1) == 0
        assert lookahead_boundary >= 4*burst_depth
        boundary_bits = log2_int(lookahead_boundary) - 2 # In words.
        self.bus      = bus    = wishbone.Interface(data_width=32, adr_width=30)
        self.source   = source = stream.Endpoint(packet_description(32))
        self.sink     = sink   = stream.Endpoint(packet_description(32))
        self.prefetch = Signal() # Enable read prefetch.

        # # #

        access = Signal()
        self.comb += access.eq(bus.cyc & bus.stb)

        # Pending Write Request (same as SERWBMMAPSlave).
        # -----------------------------------------------
        self.wr_fifo = wr_fifo = stream.SyncFIFO([("data", 32)], burst_depth)
        wr_adr     = Signal(30)
        wr_sel     = Signal(4)
        wr_count   = Signal(max=burst_depth + 1)
        wr_next    = Signal(30)
        wr_pending = Signal()
        wr_append  = Signal()
        wr_accept  = Signal()
        wr_send    = Signal()
        self.comb += [
            wr_pending.eq(wr_count != 0),
            wr_append.eq(wr_pending & (wr_count != burst_depth) & (bus.adr == wr_next) & (bus.sel == wr_sel)),
            wr_accept.eq(access & bus.we & (~wr_pending | wr_append)),
        ]
        if coalescing_timeout:
            self.wr_timer = wr_timer = WaitTimer(coalescing_timeout)
            self.comb += [
                wr_timer.wait.eq(wr_pending & ~access),
                wr_send.eq(wr_pending & (wr_timer.done | (wr_count == burst_depth) | (access & ~wr_accept))),
            ]
        else:
            self.comb += wr_send.eq(wr_pending)

        # Read Buffer.
        # ------------
        # Stream of words requested from buf_adr on (current block + look-ahead block), consumed in
        # order by sequential reads.
        self.rd_fifo = rd_fifo = ResetInserter()(stream.SyncFIFO([("data", 32)], 2*burst_depth))
        buf_adr  = Signal(30)                     # Address of the next word to consume.
        buf_left = Signal(max=2*burst_depth + 1)  # Words requested and not consumed yet.
        buf_req  = Signal(max=burst_depth + 1)    # Words of the first request (miss).
        buf_sel  = Signal(4)                      # Byte enables of the stream.
        single   = Signal()                       # Next read request: single word (error retry).
        hits     = Signal(2)                      # Sequential hits since the miss (saturating).

        # Read Response Receiver (independent of the request FSM).
        # ---------------------------------------------------------
        # Up to 2 responses outstanding (current + look-ahead), received in order.
        rx_pending = Signal(2) # Responses expected.
        rx_busy    = Signal()  # Response expected/being received.
        rx_status  = Signal()  # Status of the current response received.
        rx_err     = Signal()  # Error reported for the current response.
        rx_discard = Signal()  # Stream invalidated: drop the words of the outstanding responses.
        rx_la      = Signal()  # Current response is a look-ahead.
        rx_la_next = Signal()  # Next response is a look-ahead.
        rx_start   = Signal()  # Request sent (response expected).
        rx_end     = Signal()  # Last word of the current response.
        req_la     = Signal()  # Request being sent is a look-ahead.
        status_err = Signal()
        flush      = Signal()
        self.comb += [
            rx_busy.eq(rx_pending != 0),
            rx_end.eq(rx_busy & sink.valid & sink.last),
            sink.ready.eq(rx_busy),
            rd_fifo.sink.valid.eq(sink.valid & rx_busy & rx_status & ~rx_discard & ~rx_err),
            rd_fifo.sink.data.eq(sink.data),
            rd_fifo.reset.eq(flush),
            # Truncated response (no data) or invalid magic: error.
            status_err.eq(sink.data[0] | sink.last | (sink.data[16:32] != MMAP_MAGIC)),
        ]
        self.sync += [
            # Status word of the current response.
            If(rx_busy & sink.valid & ~rx_status,
                rx_status.eq(1),
                rx_err.eq(status_err),
            ),
            # End of the current response: the next one (if any) becomes current.
            If(rx_end,
                rx_status.eq(0),
                rx_err.eq(0),
                rx_la.eq(rx_la_next),
            ),
            If(rx_start,
                If(rx_pending == 0,
                    rx_status.eq(0),
                    rx_err.eq(0),
                    rx_discard.eq(0),
                    rx_la.eq(req_la),
                ).Elif((rx_pending == 1) & rx_end,
                    rx_la.eq(req_la),
                ).Else(
                    rx_la_next.eq(req_la),
                )
            ),
            rx_pending.eq(rx_pending + rx_start - rx_end),
        ]

        # Words to consume (single update point).
        # ----------------------------------------
        consume = Signal() # One word consumed (read hit).
        add     = Signal() # Words requested (add_k).
        add_k   = Signal(max=burst_depth + 1)
        drop    = Signal() # Look-ahead request failed: its words will not come.
        clear   = Signal() # Stream invalidated.
        self.comb += drop.eq(rx_busy & sink.valid & ~rx_status & status_err & rx_la & ~rx_discard)
        self.sync += If(clear,
            buf_left.eq(0),
        ).Else(
            buf_left.eq(buf_left + Mux(add, add_k, 0) - consume - Mux(drop, burst_depth, 0)),
        )

        # Request.
        # --------
        op    = Signal()
        adr   = Signal(30)
        sel   = Signal(4)
        count = Signal(max=burst_depth + 1)
        index = Signal(max=burst_depth + 1)

        # Read hit: sequential read of the current stream.
        is_read    = Signal()
        hit        = Signal()
        block_err  = Signal()
        to_end     = Signal(max=burst_depth + 1) # Words from the address to the end of its block.
        rd_count   = Signal(max=burst_depth + 1)
        lookahead  = Signal()
        stream_end = Signal(30)
        self.comb += [
            is_read.eq(access & ~bus.we),
            hit.eq(is_read & (buf_left != 0) & (bus.adr == buf_adr) & (bus.sel == buf_sel)),
            # Errors of the first request only (a failed look-ahead just shortens the stream).
            block_err.eq(rx_status & rx_err & ~rx_la),
            to_end.eq(burst_depth - (bus.adr & (burst_depth - 1))),
            rd_count.eq(Mux(self.prefetch & ~single, to_end, 1)),
            # Look-ahead: request the next block of a sequential stream once the previous response
            # is received, if the buffer has room for it.
            stream_end.eq(buf_adr + buf_left),
            lookahead.eq(self.prefetch & ~single & (rx_pending <= 1) & ~rx_err & ~rx_discard &
                (hits == 3) & ((buf_left - 1) <= burst_depth) & ~wr_pending &
                # Never cross a lookahead_boundary (4KB): no read ahead past the end of a memory
                # into unmapped space (remote bus timeouts).
                (stream_end[boundary_bits:] == buf_adr[boundary_bits:])),
        ]
        invalidate = [
            clear.eq(1),
            If(rx_busy,
                NextValue(rx_discard, 1),
            ).Else(
                flush.eq(1),
            )
        ]

        # FSM.
        # ----
        self.fsm = fsm = FSM(reset_state="IDLE")
        fsm.act("IDLE",
            If(wr_send,
                NextValue(op,     MMAP_OP_WRITE),
                NextValue(adr,    wr_adr),
                NextValue(sel,    wr_sel),
                NextValue(count,  wr_count),
                NextValue(req_la, 0),
                NextState("SEND-CMD")
            ).Elif(wr_accept,
                # Posted write: buffer it and ack (and drop the read buffer: no stale data).
                bus.ack.eq(1),
                wr_fifo.sink.valid.eq(1),
                wr_fifo.sink.data.eq(bus.dat_w),
                If(~wr_pending,
                    NextValue(wr_adr, bus.adr),
                    NextValue(wr_sel, bus.sel),
                ),
                NextValue(wr_next,  bus.adr + 1),
                NextValue(wr_count, wr_count + 1),
                If(buf_left != 0, *invalidate),
            ).Elif(hit,
                If(block_err,
                    If(buf_req == 1,
                        # Single-word read error: report it.
                        bus.err.eq(1),
                        NextValue(single, 0),
                    ).Else(
                        # Block error: retry as a single-word read.
                        NextValue(single, 1),
                    ),
                    *invalidate,
                ).Elif(rd_fifo.source.valid,
                    bus.ack.eq(1),
                    bus.dat_r.eq(rd_fifo.source.data),
                    rd_fifo.source.ready.eq(1),
                    consume.eq(1),
                    NextValue(buf_adr, buf_adr + 1),
                    NextValue(single, 0),
                    If(hits != 3,
                        NextValue(hits, hits + 1),
                    ),
                    If(lookahead,
                        add.eq(1),
                        add_k.eq(burst_depth),
                        NextValue(op,     MMAP_OP_READ),
                        NextValue(adr,    stream_end),
                        NextValue(sel,    buf_sel),
                        NextValue(count,  burst_depth),
                        NextValue(req_la, 1),
                        NextState("SEND-CMD")
                    )
                )
            ).Elif(is_read,
                If(buf_left != 0,
                    # Non-sequential read: drop the current stream first.
                    *invalidate,
                ).Elif(rx_busy,
                    # Wait for the end of a discarded response.
                ).Else(
                    flush.eq(1),
                    add.eq(1),
                    add_k.eq(rd_count),
                    NextValue(op,      MMAP_OP_READ),
                    NextValue(adr,     bus.adr),
                    NextValue(sel,     bus.sel),
                    NextValue(count,   rd_count),
                    NextValue(req_la,  0),
                    NextValue(buf_adr, bus.adr),
                    NextValue(buf_req, rd_count),
                    NextValue(buf_sel, bus.sel),
                    NextValue(hits,    0),
                    NextState("SEND-CMD")
                )
            )
        )
        self.comb += [
            source.port.eq(0),
            source.length.eq(Mux(op == MMAP_OP_WRITE, 4*(2 + count), 4*2)),
        ]
        fsm.act("SEND-CMD",
            source.valid.eq(1),
            source.data[0].eq(op),
            source.data[4:8].eq(sel),
            source.data[8:16].eq(count - 1),
            source.data[16:32].eq(MMAP_MAGIC),
            If(source.ready,
                NextState("SEND-ADDR")
            )
        )
        fsm.act("SEND-ADDR",
            source.valid.eq(1),
            source.last.eq(op == MMAP_OP_READ),
            source.data.eq(adr),
            If(source.ready,
                NextValue(index, 0),
                If(op == MMAP_OP_READ,
                    rx_start.eq(1),
                    NextState("IDLE")
                ).Else(
                    NextState("SEND-DATA")
                )
            )
        )
        fsm.act("SEND-DATA",
            source.valid.eq(1),
            source.last.eq(index == (count - 1)),
            source.data.eq(wr_fifo.source.data),
            If(source.ready,
                wr_fifo.source.ready.eq(1),
                NextValue(index, index + 1),
                If(source.last,
                    NextValue(wr_count, 0),
                    NextState("IDLE")
                )
            )
        )

# SerWB Core ---------------------------------------------------------------------------------------

def SERWBCorePrefetch(phy, clk_freq, mode, **kwargs):
    """SERWBCore (native protocol) whose slave side supports read prefetch (``core.mmap.prefetch``).

    SERWBCore instantiates SERWBMMAPSlave internally: substitute it during construction."""
    assert kwargs.get("protocol", "native") == "native"
    if mode != "slave":
        return SERWBCore(phy, clk_freq, mode=mode, **kwargs)
    original = serwb_core_module.SERWBMMAPSlave
    serwb_core_module.SERWBMMAPSlave = SERWBMMAPSlavePrefetch
    try:
        return SERWBCore(phy, clk_freq, mode=mode, **kwargs)
    finally:
        serwb_core_module.SERWBMMAPSlave = original
