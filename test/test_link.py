#
# This file is part of soc2soc-over-serdes.
#
# SPDX-License-Identifier: BSD-2-Clause

# Simulation of two SerDes link layers connected back-to-back (transceivers replaced by a direct
# 16-bit + K-flags connection, optional 1-byte misalignment and error injection) with SerWB on top:
# Board A initiator -> link -> Board B target -> Wishbone SRAM.

import random
import unittest

from migen import *

from litex.gen import *

from litex.soc.interconnect import wishbone

from liteiclink.serwb.core import SERWBCore

from soc2soc.link import SerDesLinkPHY

# Migen simulation compatibility ------------------------------------------------------------------

# Some Migen versions fail to simulate write-only memory ports (dat_r=None, used by AsyncFIFO):
# give them a dummy read data signal.
from migen.fhdl import simplify
from migen.fhdl.specials import Memory

_memory_to_array = simplify.MemoryToArray.transform_fragment
def _transform_fragment(self, i, f):
    for mem in f.specials:
        if isinstance(mem, Memory):
            for port in mem.ports:
                if port.dat_r is None:
                    port.dat_r = Signal(mem.width)
    return _memory_to_array(self, i, f)
simplify.MemoryToArray.transform_fragment = _transform_fragment

# Channel ------------------------------------------------------------------------------------------

class _Channel(LiteXModule):
    """TX (cd) -> RX (cd) channel: same clock (RX recovered clock = remote TX clock)."""
    def __init__(self, cd, byte_shift=False):
        from litex.soc.interconnect import stream
        self.sink    = stream.Endpoint([("data", 16), ("ctrl", 2)])
        self.source  = stream.Endpoint([("data", 16), ("ctrl", 2)])
        self.invalid = Signal(2)
        self.corrupt = Signal() # Inject an 8b/10b error on byte 0.

        # # #

        sync = getattr(self.sync, cd)
        data = Signal(16)
        ctrl = Signal(2)
        sync += [data.eq(self.sink.data), ctrl.eq(self.sink.ctrl)]
        if byte_shift:
            data_d = Signal(16)
            ctrl_d = Signal(2)
            sync += [data_d.eq(data), ctrl_d.eq(ctrl)]
            self.comb += [
                self.source.data.eq(Cat(data_d[8:], data[:8])),
                self.source.ctrl.eq(Cat(ctrl_d[1],  ctrl[0])),
            ]
        else:
            self.comb += [
                self.source.data.eq(data),
                self.source.ctrl.eq(ctrl),
            ]
        self.comb += [
            self.sink.ready.eq(1),
            self.source.valid.eq(1),
            self.invalid.eq(Cat(self.corrupt, 0)),
        ]

# DUT ----------------------------------------------------------------------------------------------

class _DUT(LiteXModule):
    def __init__(self, byte_shift=False, with_crc=False):
        self.cd_sys  = ClockDomain()
        self.cd_a_tx = ClockDomain()
        self.cd_b_tx = ClockDomain()

        # Channels (A TX -> B RX in a_tx, B TX -> A RX in b_tx).
        self.a2b = a2b = _Channel("a_tx", byte_shift=byte_shift)
        self.b2a = b2a = _Channel("b_tx")

        self.trx_ready = Signal(reset=1)

        # PHYs.
        # (No CDC common reset: derived clock domains are not supported by the simulator).
        self.phy_a = phy_a = SerDesLinkPHY(a2b.sink, b2a.source, b2a.invalid, self.trx_ready,
            cd_tx="a_tx", cd_rx="b_tx", cdc_common_rst=False)
        self.phy_b = phy_b = SerDesLinkPHY(b2a.sink, a2b.source, a2b.invalid, self.trx_ready,
            cd_tx="b_tx", cd_rx="a_tx", cdc_common_rst=False)

        # SerWB: A initiator (Wishbone Slave), B target (Wishbone Master) -> SRAM.
        self.core_a = core_a = SERWBCore(phy_a, 100e6, mode="slave",  with_crc=with_crc)
        self.core_b = core_b = SERWBCore(phy_b, 100e6, mode="master", with_crc=with_crc)
        self.sram   = sram   = wishbone.SRAM(1024)
        self.comb += core_b.bus.connect(sram.bus)

# Test ---------------------------------------------------------------------------------------------

CLOCKS = {"sys": 10, "a_tx": 8, "b_tx": 7}

def wait_ready(dut, timeout=1000):
    for _ in range(timeout):
        if (yield dut.phy_a.init.ready) and (yield dut.phy_b.init.ready):
            return True
        yield
    return False

def wb_test(dut, results, words=8, seed=0):
    rng  = random.Random(seed)
    data = [rng.getrandbits(32) for _ in range(words)]
    for i, d in enumerate(data):
        yield from dut.core_a.bus.write(i, d)
    readback = []
    for i in range(words):
        readback.append((yield from dut.core_a.bus.read(i)))
    results["errors"] = sum(a != b for a, b in zip(data, readback))

class TestLink(unittest.TestCase):
    def run_link(self, byte_shift=False, with_crc=False, inject_error=False):
        dut     = _DUT(byte_shift=byte_shift, with_crc=with_crc)
        results = {}

        def generator():
            results["ready"] = yield from wait_ready(dut)
            if not results["ready"]:
                return
            if inject_error:
                # Link must drop on error and recover.
                yield dut.a2b.corrupt.eq(1)
                for _ in range(4):
                    yield
                yield dut.a2b.corrupt.eq(0)
                for _ in range(8):
                    yield
                results["dropped"] = not (yield dut.phy_b.init.ready)
                results["ready"]   = yield from wait_ready(dut)
                if not results["ready"]:
                    return
            yield from wb_test(dut, results)

        run_simulation(dut, generator(), clocks=CLOCKS)
        self.assertTrue(results["ready"], "Link not ready.")
        self.assertEqual(results["errors"], 0)
        if inject_error:
            self.assertTrue(results["dropped"], "Link did not drop on error.")

    def test_link(self):
        self.run_link()

    def test_link_byte_shift(self):
        self.run_link(byte_shift=True)

    def test_link_crc(self):
        self.run_link(with_crc=True)

    def test_link_error_recovery(self):
        self.run_link(inject_error=True)

if __name__ == "__main__":
    unittest.main()
