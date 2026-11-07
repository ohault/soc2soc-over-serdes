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

from soc2soc.link        import SerDesLinkPHY
from soc2soc.serdes_link import RemoteWindow

# Migen simulation compatibility ------------------------------------------------------------------

# The stale GitHub copy of Migen (github.com/m-labs/migen, commit 7bf0214, reverted in the official
# git.m-labs.hk repository) makes SyncFIFO/AsyncFIFO write ports write-only, which its simulator
# cannot handle (AttributeError on dat_r=None). When running on it, give write-only ports a dummy
# read data signal.
from migen.fhdl import simplify
from migen.fhdl.specials import Memory

def _migen_simulates_write_only_ports():
    m = Module()
    m.specials.mem = mem = Memory(8, 4)
    try:
        m.specials.port = mem.get_port(write_capable=True, read_capable=False)
    except TypeError:
        # Official Migen: no read_capable parameter, ports are always readable.
        return True
    try:
        simplify.MemoryToArray().transform_fragment(None, m.get_fragment())
    except AttributeError:
        return False
    return True

if not _migen_simulates_write_only_ports():
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
    """Two link ends back to back.

    interconnect=None    : two SoCs, A host -> A initiator ... B target -> B SRAM.
    interconnect="shared"/"crossbar": single SoC (scenario 1, SFP0 <-> SFP1 on the same board), the
    host and the target core are both masters of the same bus, with the SRAM and the initiator
    window as slaves: host -> window -> A initiator ... B target -> same bus -> SRAM.
    """
    WINDOW_BASE = 0x0800_0000 # Word address of the window (byte 0x2000_0000) in single-SoC mode.

    def __init__(self, byte_shift=False, with_crc=False, interconnect=None):
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
        if interconnect is None:
            self.host      = core_a.bus
            self.host_base = 0
            self.comb += core_b.bus.connect(sram.bus)
        else:
            self.host      = wishbone.Interface(data_width=32, adr_width=30)
            self.host_base = self.WINDOW_BASE
            self.window    = window = RemoteWindow(core_a.bus, default_page=0)
            interconnect_cls = {
                "shared"   : wishbone.InterconnectShared,
                "crossbar" : wishbone.Crossbar,
            }[interconnect]
            self.interconnect = interconnect_cls(
                masters = [self.host, core_b.bus],
                slaves  = [
                    (lambda a: a[27] == 0, sram.bus),
                    (lambda a: a[27] == 1, window.bus),
                ],
                register       = True,
                timeout_cycles = 4096,
            )

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
        yield from dut.host.write(dut.host_base + i, d)
    readback = []
    for i in range(words):
        readback.append((yield from dut.host.read(dut.host_base + i)))
    results["errors"] = sum(a != b for a, b in zip(data, readback))
    # Direct check of the SRAM content (remote writes).
    for i, d in enumerate(data):
        if (yield dut.sram.mem[i]) != d:
            results["write_errors"] = results.get("write_errors", 0) + 1

class TestLink(unittest.TestCase):
    def run_link(self, byte_shift=False, with_crc=False, inject_error=False, interconnect=None):
        dut     = _DUT(byte_shift=byte_shift, with_crc=with_crc, interconnect=interconnect)
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
        if inject_error:
            self.assertTrue(results["dropped"], "Link did not drop on error.")
        return results

    def check_link(self, **kwargs):
        results = self.run_link(**kwargs)
        self.assertEqual(results["errors"], 0)
        self.assertEqual(results.get("write_errors", 0), 0)

    def test_link(self):
        self.check_link()

    def test_link_byte_shift(self):
        self.check_link(byte_shift=True)

    def test_link_crc(self):
        self.check_link(with_crc=True)

    def test_link_error_recovery(self):
        self.check_link(inject_error=True)

    def test_reset_counters(self):
        dut = _DUT()
        dut.phy_b.add_csr()
        results = {}

        def generator():
            assert (yield from wait_ready(dut))
            # Error -> link drop and RX error counted on B.
            yield dut.a2b.corrupt.eq(1)
            yield
            yield dut.a2b.corrupt.eq(0)
            assert (yield from wait_ready(dut))
            for _ in range(16):
                yield
            results["before"] = ((yield dut.phy_b.rx_errors), (yield dut.phy_b._link_drops.status))
            # Clear.
            yield dut.phy_b._reset_counters.re.eq(1)
            yield
            yield dut.phy_b._reset_counters.re.eq(0)
            for _ in range(16):
                yield
            results["after"] = ((yield dut.phy_b.rx_errors), (yield dut.phy_b._link_drops.status))

        run_simulation(dut, generator(), clocks=CLOCKS)
        self.assertGreater(results["before"][0], 0)
        self.assertGreater(results["before"][1], 0)
        self.assertEqual(results["after"], (0, 0))

    def test_single_soc_crossbar(self):
        # Scenario 1: the target executes the access on the bus the host is waiting on. With a
        # crossbar, the host -> window and target -> SRAM accesses proceed in parallel.
        self.check_link(interconnect="crossbar")

    def test_single_soc_shared_read_deadlock(self):
        # With a shared bus, the host holds the bus while waiting for the read response, so the
        # target cannot execute the read: every read times out (bus timeout, 0xffffffff). Writes are
        # posted by the SerWB initiator so they are not blocked. This is why the SoC uses a
        # crossbar interconnect.
        results = self.run_link(interconnect="shared")
        self.assertEqual(results["errors"], 8)

if __name__ == "__main__":
    unittest.main()
