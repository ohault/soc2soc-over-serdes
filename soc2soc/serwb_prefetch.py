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
# - Prefetch is enabled by the ``prefetch`` signal (e.g. a CSR): only enable it on regions without
#   read side effects (memories), since prefetched words are read on the remote bus.
# - The buffer is discarded on any write or non-sequential read (no stale data from before a local
#   write). Remote changes between the prefetch and the reads are not seen (as with any cache).
# - Blocks never cross a burst_depth-aligned boundary, so prefetching from the last block of a memory
#   does not read past its end if its size is a multiple of the block size. If a block returns a bus
#   error, the read is retried as a single-word read, so errors are reported as without prefetch.
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
    def __init__(self, burst_depth=4, coalescing_timeout=4):
        assert 1 <= burst_depth <= 256
        assert burst_depth & (burst_depth - 1) == 0, "burst_depth must be a power of 2."
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
        # Words of the current read block, consumed in order by sequential reads.
        self.rd_fifo = rd_fifo = ResetInserter()(stream.SyncFIFO([("data", 32)], burst_depth))
        buf_adr  = Signal(30)                     # Address of the next word to consume.
        buf_left = Signal(max=burst_depth + 1)    # Words of the block not consumed yet.
        buf_req  = Signal(max=burst_depth + 1)    # Words requested for the block.
        buf_sel  = Signal(4)                      # Byte enables of the block.
        single   = Signal()                       # Next read request: single word (error retry).

        # Read Response Receiver (independent of the request FSM).
        # ---------------------------------------------------------
        rx_busy    = Signal() # Response expected/being received.
        rx_status  = Signal() # Status received.
        rx_err     = Signal() # Error reported for the block.
        rx_discard = Signal() # Block invalidated while being received: drop its words.
        rx_start   = Signal()
        flush      = Signal()
        self.comb += [
            sink.ready.eq(rx_busy),
            rd_fifo.sink.valid.eq(sink.valid & rx_busy & rx_status & ~rx_discard & ~rx_err),
            rd_fifo.sink.data.eq(sink.data),
            rd_fifo.reset.eq(flush),
        ]
        self.sync += [
            If(rx_start,
                rx_busy.eq(1),
                rx_status.eq(0),
                rx_err.eq(0),
                rx_discard.eq(0),
            ).Elif(rx_busy & sink.valid,
                If(~rx_status,
                    rx_status.eq(1),
                    # Truncated response (no data) or invalid magic: error.
                    rx_err.eq(sink.data[0] | sink.last | (sink.data[16:32] != MMAP_MAGIC)),
                ),
                If(sink.last,
                    rx_busy.eq(0),
                )
            )
        ]

        # Request.
        # --------
        op    = Signal()
        adr   = Signal(30)
        sel   = Signal(4)
        count = Signal(max=burst_depth + 1)
        index = Signal(max=burst_depth + 1)

        # Read hit: sequential read of the current block.
        is_read   = Signal()
        hit       = Signal()
        block_err = Signal()
        to_end    = Signal(max=burst_depth + 1) # Words from the address to the end of its block.
        rd_count  = Signal(max=burst_depth + 1)
        self.comb += [
            is_read.eq(access & ~bus.we),
            hit.eq(is_read & (buf_left != 0) & (bus.adr == buf_adr) & (bus.sel == buf_sel)),
            block_err.eq(rx_status & rx_err),
            to_end.eq(burst_depth - (bus.adr & (burst_depth - 1))),
            rd_count.eq(Mux(self.prefetch & ~single, to_end, 1)),
        ]
        invalidate = [
            NextValue(buf_left, 0),
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
                NextValue(op,    MMAP_OP_WRITE),
                NextValue(adr,   wr_adr),
                NextValue(sel,   wr_sel),
                NextValue(count, wr_count),
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
                    NextValue(buf_adr,  buf_adr + 1),
                    NextValue(buf_left, buf_left - 1),
                    NextValue(single, 0),
                )
            ).Elif(is_read,
                If(buf_left != 0,
                    # Non-sequential read: drop the current block first.
                    *invalidate,
                ).Elif(rx_busy,
                    # Wait for the end of a discarded response.
                ).Else(
                    flush.eq(1),
                    NextValue(op,       MMAP_OP_READ),
                    NextValue(adr,      bus.adr),
                    NextValue(sel,      bus.sel),
                    NextValue(count,    rd_count),
                    NextValue(buf_adr,  bus.adr),
                    NextValue(buf_left, rd_count),
                    NextValue(buf_req,  rd_count),
                    NextValue(buf_sel,  bus.sel),
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
