#
# This file is part of soc2soc-over-serdes.
#
# SPDX-License-Identifier: BSD-2-Clause

# Wishbone traffic generator to measure the SoC-to-SoC bandwidth and latency from the FPGA itself
# (host accesses through a UART bridge are far too slow to measure the link).
#
# The generator is a Wishbone master on the SoC bus. On start, it performs ``length`` back-to-back
# 32-bit writes or reads at ``base`` + (i & ``wrap``) words, with one access in flight at a time
# (classic Wishbone, as a CPU or a host bridge does), and measures:
# - cycles  : total duration of the run, in sys clock cycles.
# - latency : worst-case duration of a single access (from request to ack), in sys clock cycles.
# - errors  : read data mismatches (reads check the pattern written by a previous write run) and
#             bus errors (e.g. bus timeout).
#
# The data pattern only depends on the seed and on the word offset in the wrapped area, so a read
# run checks the data of a previous write run with the same base/wrap/seed whatever the lengths.

from migen import *

from litex.gen import *

from litex.soc.interconnect     import wishbone
from litex.soc.interconnect.csr import *

# Wishbone Bench -----------------------------------------------------------------------------------

def bench_pattern(seed, offset):
    """Data written at word ``offset`` (Python model of the gateware pattern)."""
    offset &= 0xffff
    return seed ^ ((((~offset) & 0xffff) << 16) | offset)

class WishboneBench(LiteXModule):
    def __init__(self):
        self.bus = bus = wishbone.Interface(data_width=32, adr_width=30, addressing="word")

        self._base    = CSRStorage(32, description="Base byte address (32-bit aligned).")
        self._length  = CSRStorage(32, reset=1024, description="Number of 32-bit accesses.")
        self._wrap    = CSRStorage(32, reset=0x3ff, description="Word offset mask: address = base + 4*(i & wrap).")
        self._seed    = CSRStorage(32, description="Data pattern seed.")
        self._control = CSRStorage(fields=[
            CSRField("write", size=1, values=[
                ("``0b0``", "Read (and check the pattern)."),
                ("``0b1``", "Write the pattern."),
            ]),
        ])
        self._start   = CSR()
        self._done    = CSRStatus(reset=1, description="Run done.")
        self._cycles  = CSRStatus(32, description="Run duration (sys clock cycles).")
        self._latency = CSRStatus(32, description="Worst-case access duration (sys clock cycles).")
        self._errors  = CSRStatus(32, description="Read data mismatches + bus errors.")

        # # #

        count   = Signal(32)
        offset  = Signal(32)
        pattern = Signal(32)
        access  = Signal(32)
        self.comb += [
            offset.eq(count & self._wrap.storage),
            pattern.eq(self._seed.storage ^ Cat(offset[:16], ~offset[:16])),
            bus.adr.eq(self._base.storage[2:] + offset),
            bus.dat_w.eq(pattern),
            bus.sel.eq(0xf),
            bus.we.eq(self._control.storage[0]),
        ]

        self.fsm = fsm = FSM(reset_state="IDLE")
        fsm.act("IDLE",
            If(self._start.re,
                NextValue(count, 0),
                NextValue(access, 0),
                NextValue(self._done.status,    0),
                NextValue(self._cycles.status,  0),
                NextValue(self._latency.status, 0),
                NextValue(self._errors.status,  0),
                If(self._length.storage != 0,
                    NextState("RUN")
                ).Else(
                    NextValue(self._done.status, 1),
                )
            )
        )
        fsm.act("RUN",
            bus.cyc.eq(1),
            bus.stb.eq(1),
            NextValue(self._cycles.status, self._cycles.status + 1),
            NextValue(access, access + 1),
            If(bus.ack | bus.err,
                NextValue(access, 0),
                If(access + 1 > self._latency.status,
                    NextValue(self._latency.status, access + 1),
                ),
                If(bus.err | (~self._control.storage[0] & (bus.dat_r != pattern)),
                    NextValue(self._errors.status, self._errors.status + 1),
                ),
                NextValue(count, count + 1),
                If(count == (self._length.storage - 1),
                    NextValue(self._done.status, 1),
                    NextState("IDLE")
                )
            )
        )
