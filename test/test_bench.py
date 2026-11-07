#
# This file is part of soc2soc-over-serdes.
#
# SPDX-License-Identifier: BSD-2-Clause

# Bandwidth/latency simulation of the three cabling scenarios (one and two DAC cables), with the
# transceivers replaced by direct connections (see test_link.py). Each SoC has a crossbar with:
# - masters: WishboneBench + the SerWB core of each target link end,
# - slaves : mailbox SRAM (0x2000_0000) + the remote window of each initiator link end
#            (SFP0: 0x8000_0000, SFP1: 0x9000_0000, page = remote mailbox).
#
# Every SoC has the same configuration (SFP0 = initiator, SFP1 = target) and every cable joins an
# SFP0 to an SFP1:
# Scenario 1   : A.SFP0 <-> A.SFP1 (single SoC).
# Scenario 1AB : A.SFP0 <-> A.SFP1 and B.SFP0 <-> B.SFP1, both used at once.
# Scenario 2   : A.SFP0 <-> B.SFP1.
# Scenario 3   : A.SFP0 <-> B.SFP1 and B.SFP0 <-> A.SFP1, both used at once.
#
# Clocks model the hardware: sys = 100MHz (10ns), SerDes TX/RX = 125MHz (8ns, 2.5Gbps).
#
# Run with "python3 -m unittest test.test_bench -v"; the measured figures are printed.

import unittest

from migen import *

from litex.gen import *

from litex.soc.interconnect import wishbone

from liteiclink.serwb.core import SERWBCore

from soc2soc.link        import SerDesLinkPHY
from soc2soc.serdes_link import RemoteWindow
from soc2soc.bench       import WishboneBench, bench_pattern

from test.test_link import _Channel # Also applies the Migen compatibility fix.

SYS_CLK_FREQ = 100e6
LINERATE     = 2.5e9
MAILBOX      = 0x2000_0000
WINDOWS      = {0: 0x8000_0000, 1: 0x9000_0000}
MAILBOX_SIZE = 0x2000 # Bytes, as in the SoC.

# Scenarios: list of links (initiator SoC, initiator SFP, target SoC, target SFP).
SCENARIOS = {
    "1"   : [("a", 0, "a", 1)],
    "1AB" : [("a", 0, "a", 1), ("b", 0, "b", 1)],
    "2"   : [("a", 0, "b", 1)],
    "3"   : [("a", 0, "b", 1), ("b", 0, "a", 1)],
}

def _page(addr):
    return addr >> 28

def _region(addr):
    # Word address decoder for a 256MB region.
    return lambda a: a[26:30] == _page(addr)

# Topology -----------------------------------------------------------------------------------------

class _Topology(LiteXModule):
    def __init__(self, scenario, with_crc=False, burst_depth=64, sys_clk_freq=SYS_CLK_FREQ, linerate=LINERATE):
        links = SCENARIOS[scenario]
        socs  = sorted({s for l in links for s in (l[0], l[2])})
        self.cd_sys = ClockDomain()
        # Clock periods in 0.1ns units.
        self.clocks = {"sys": round(1e10/sys_clk_freq)}
        tx_period   = round(1e10/(linerate/20))
        self.trx_ready = Signal(reset=1)

        masters = {s: [] for s in socs}
        slaves  = {s: [] for s in socs}
        self.benches = {}
        self.srams   = {}
        for s in socs:
            self.benches[s] = bench = WishboneBench()
            self.srams[s]   = sram  = wishbone.SRAM(MAILBOX_SIZE)
            self.add_module(f"bench_{s}", bench)
            self.add_module(f"sram_{s}",  sram)
            masters[s].append(bench.bus)
            slaves[s].append((_region(MAILBOX), sram.bus))

        self.phys = []
        for n, (init_soc, init_sfp, tgt_soc, tgt_sfp) in enumerate(links):
            # One DAC cable: initiator TX -> target RX (cd i2t), target TX -> initiator RX (cd t2i).
            cd_i2t, cd_t2i = f"l{n}_i2t", f"l{n}_t2i"
            for cd in [cd_i2t, cd_t2i]:
                self.clock_domains += ClockDomain(cd)
                self.clocks[cd] = tx_period
            i2t = _Channel(cd_i2t)
            t2i = _Channel(cd_t2i)
            self.add_module(f"l{n}_i2t", i2t)
            self.add_module(f"l{n}_t2i", t2i)
            phy_i = SerDesLinkPHY(i2t.sink, t2i.source, t2i.invalid, self.trx_ready,
                cd_tx=cd_i2t, cd_rx=cd_t2i, cdc_common_rst=False)
            phy_t = SerDesLinkPHY(t2i.sink, i2t.source, i2t.invalid, self.trx_ready,
                cd_tx=cd_t2i, cd_rx=cd_i2t, cdc_common_rst=False)
            core_i = SERWBCore(phy_i, sys_clk_freq, mode="slave",  with_crc=with_crc, burst_depth=burst_depth)
            core_t = SERWBCore(phy_t, sys_clk_freq, mode="master", with_crc=with_crc, burst_depth=burst_depth)
            window = RemoteWindow(core_i.bus, default_page=_page(MAILBOX))
            for name, m in [("phy_i", phy_i), ("phy_t", phy_t), ("core_i", core_i),
                            ("core_t", core_t), ("window", window)]:
                self.add_module(f"l{n}_{name}", m)
            self.phys += [phy_i, phy_t]
            slaves[init_soc].append((_region(WINDOWS[init_sfp]), window.bus))
            masters[tgt_soc].append(core_t.bus)

        for s in socs:
            self.add_module(f"crossbar_{s}", wishbone.Crossbar(
                masters        = masters[s],
                slaves         = slaves[s],
                register       = True,
                timeout_cycles = 4096,
            ))

        # Bench of each initiator SoC targets its own initiator window(s).
        self.runs = [(init_soc, WINDOWS[init_sfp]) for init_soc, init_sfp, _, _ in links]

# Simulation helpers -------------------------------------------------------------------------------

def _wait_ready(top, timeout=2000):
    for _ in range(timeout):
        ready = True
        for phy in top.phys:
            ready &= bool((yield phy.init.ready))
        if ready:
            return True
        yield
    return False

def _start(bench, base, length, wrap, write, seed=0x5eed):
    yield bench._base.storage.eq(base)
    yield bench._length.storage.eq(length)
    yield bench._wrap.storage.eq(wrap)
    yield bench._seed.storage.eq(seed)
    yield bench._control.storage.eq(int(write))
    yield bench._start.re.eq(1)
    yield
    yield bench._start.re.eq(0)
    yield

def _wait_done(benches, timeout=1_000_000):
    for _ in range(timeout):
        done = True
        for b in benches:
            done &= bool((yield b._done.status))
        if done:
            break
        yield
    results = []
    for b in benches:
        results.append({
            "done"    : bool((yield b._done.status)),
            "cycles"  : (yield b._cycles.status),
            "latency" : (yield b._latency.status),
            "errors"  : (yield b._errors.status),
        })
    return results

def _mbps(length, cycles, sys_clk_freq=SYS_CLK_FREQ):
    return length*4/(cycles/sys_clk_freq)/1e6 if cycles else 0.0

def link_capacity(linerate=LINERATE):
    """Link layer payload capacity per direction (bytes/s): 2 bytes per TX clock, 1 IDLE every
    64 32-bit words (128 cycles)."""
    return linerate/20*2*128/129

def run_scenario(scenario, length=512, concurrent=True, with_crc=False, burst_depth=64,
    sys_clk_freq=SYS_CLK_FREQ, linerate=LINERATE):
    """Returns {"write"/"read": [result per run]}, result = dict(soc, base, mbps, latency_ns,
    errors, done)."""
    top  = _Topology(scenario, with_crc=with_crc, burst_depth=burst_depth,
        sys_clk_freq=sys_clk_freq, linerate=linerate)
    wrap = MAILBOX_SIZE//4 - 1
    out  = {}

    def generator():
        assert (yield from _wait_ready(top)), "Links not ready."
        for mode in ["write", "read"]:
            groups = [top.runs] if concurrent else [[r] for r in top.runs]
            out[mode] = []
            for group in groups:
                benches = [top.benches[soc] for soc, _ in group]
                for (soc, base), bench in zip(group, benches):
                    yield from _start(bench, base, length, wrap, write=(mode == "write"))
                results = yield from _wait_done(benches)
                for (soc, base), r in zip(group, results):
                    out[mode].append(dict(r, soc=soc, base=base,
                        mbps       = _mbps(length, r["cycles"], sys_clk_freq),
                        latency_ns = r["latency"]*1e9/sys_clk_freq))
        # Remote writes landed in the remote mailbox?
        out["mailbox_errors"] = 0
        for init_soc, init_sfp, tgt_soc, _ in SCENARIOS[scenario]:
            for i in range(min(length, wrap + 1)):
                if (yield top.srams[tgt_soc].mem[i]) != bench_pattern(0x5eed, i):
                    out["mailbox_errors"] += 1

    run_simulation(top, generator(), clocks=top.clocks)
    return out

def _print(scenario, out):
    print(f"\nScenario {scenario} (link capacity {link_capacity()/1e6:.1f} MB/s per direction):")
    for mode in ["write", "read"]:
        for r in out[mode]:
            print(f"  {r['soc'].upper()} -> window 0x{r['base']:08x} {mode:5s}: "
                  f"{r['mbps']:7.2f} MB/s, worst-case access latency {r['latency_ns']:7.1f} ns, "
                  f"{r['errors']} errors")
        if len(out[mode]) > 1:
            print(f"  aggregate {mode:5s}: {sum(r['mbps'] for r in out[mode]):7.2f} MB/s")

# Tests --------------------------------------------------------------------------------------------

class TestBench(unittest.TestCase):
    def check(self, scenario, **kwargs):
        out = run_scenario(scenario, **kwargs)
        _print(scenario, out)
        for mode in ["write", "read"]:
            self.assertEqual(len(out[mode]), len(SCENARIOS[scenario]))
            for r in out[mode]:
                self.assertTrue(r["done"], f"{mode} run not done.")
                self.assertEqual(r["errors"], 0, f"{mode} errors.")
                self.assertGreater(r["mbps"], 0)
        self.assertEqual(out["mailbox_errors"], 0)
        return out

    def test_bench_detects_errors(self):
        # Write with one seed, read back expecting another: every read must be counted as an error.
        top   = _Topology("1")
        bench = top.benches["a"]
        wrap  = MAILBOX_SIZE//4 - 1
        out   = {}
        def generator():
            assert (yield from _wait_ready(top))
            yield from _start(bench, MAILBOX, 64, wrap, write=True, seed=1)
            yield from _wait_done([bench])
            yield from _start(bench, MAILBOX, 64, wrap, write=False, seed=2)
            out["read"] = (yield from _wait_done([bench]))[0]
        run_simulation(top, generator(), clocks=top.clocks)
        self.assertTrue(out["read"]["done"])
        self.assertEqual(out["read"]["errors"], 64)

    def test_scenario1_one_dac_single_soc(self):
        self.check("1")

    def test_scenario1ab_one_dac_per_soc(self):
        self.check("1AB")

    def test_scenario2_one_dac_two_socs(self):
        self.check("2")

    def test_scenario3_two_dacs_concurrent(self):
        out = self.check("3")
        # Each direction has its own cable: running both at once must not halve the bandwidth.
        alone = run_scenario("3", concurrent=False)
        for mode in ["write", "read"]:
            for r_conc, r_alone in zip(out[mode], alone[mode]):
                self.assertGreater(r_conc["mbps"], 0.8*r_alone["mbps"])

    # With CRC, the receiver is slower than the link: requires the link layer flow control.
    def test_scenario2_crc(self):
        self.check("2", with_crc=True)

if __name__ == "__main__":
    unittest.main()
