#!/usr/bin/env python3

#
# This file is part of soc2soc-over-serdes.
#
# SPDX-License-Identifier: BSD-2-Clause

# SoC2SoC over SerDes bring-up/test utility (through litex_server).
#
# All boards run the same gateware (SFP0 = initiator, SFP1 = target) and every DAC cable joins an
# SFP0 to an SFP1. The cabling is detected at run time (see the wiring command), so the same
# commands work in every scenario:
# 1) A.SFP0 <-> A.SFP1 (and/or B.SFP0 <-> B.SFP1 at the same time).
# 2) A.SFP0 <-> B.SFP1.
# 3) A.SFP0 <-> B.SFP1 and B.SFP0 <-> A.SFP1.
#
# One litex_server per board, board A on port 1234 and board B on port 1235:
#   litex_server --uart --uart-port=/dev/serial/by-path/<board A UART> --bind-port=1234
#   litex_server --uart --uart-port=/dev/serial/by-path/<board B UART> --bind-port=1235
#   ./test_soc2soc.py --boards=AB run --report=results.md   # Full test sequence on what is connected.
#   ./test_soc2soc.py --boards=AB autopolarity | wiring | status | prbs | remote | bandwidth

import time
import random
import argparse

from litex import RemoteClient

# Constants ----------------------------------------------------------------------------------------

PRBS_MODES = {"prbs7": 0b01, "prbs15": 0b10, "prbs31": 0b11}
PRBS_PAUSE = 0b100

STATUS_READY     = (1 << 0)
STATUS_RX_OK     = (1 << 1)
STATUS_REMOTE_OK = (1 << 2)

WINDOW_SIZE = 0x1000_0000

BOARD_PORTS = {"A": 1234, "B": 1235}

# SFP Link -----------------------------------------------------------------------------------------

class SFPLink:
    def __init__(self, board, bus, n):
        self.board = board
        self.bus   = bus
        self.n     = n
        self.name  = f"{board}.sfp{n}"

    @staticmethod
    def present(bus, n):
        return hasattr(bus.regs, f"sfp{n}_phy_status")

    def reg(self, name):
        return getattr(self.bus.regs, f"sfp{self.n}_{name}")

    @property
    def role(self):
        return "initiator" if hasattr(self.bus.regs, f"sfp{self.n}_window_page") else "target"

    def status(self):
        return self.reg("phy_status").read()

    def ready(self):
        return bool(self.status() & STATUS_READY)

    def rx_ok(self):
        return bool(self.status() & STATUS_RX_OK)

    def measure_clocks(self, duration=1.0):
        # Time the interval between the two latches (not the sleep): the CSR reads in between take
        # tens of ms through a UART bridge.
        t_start = time.time()
        self.reg("serdes_clock_latch").write(1)
        tx_start = self.reg("serdes_clock_tx_cycles").read()
        rx_start = self.reg("serdes_clock_rx_cycles").read()
        time.sleep(duration)
        t_end = time.time()
        self.reg("serdes_clock_latch").write(1)
        tx_end = self.reg("serdes_clock_tx_cycles").read()
        rx_end = self.reg("serdes_clock_rx_cycles").read()
        elapsed = t_end - t_start
        tx_freq = ((tx_end - tx_start) % 2**32)/elapsed
        rx_freq = ((rx_end - rx_start) % 2**32)/elapsed
        return tx_freq, rx_freq

    def reset_counters(self):
        # Clear RX errors / link drops (gateware with the phy_reset_counters CSR only).
        if hasattr(self.bus.regs, f"sfp{self.n}_phy_reset_counters"):
            self.reg("phy_reset_counters").write(1)
            return True
        return False

    def wait_ready(self, timeout=2.0):
        return self._wait(self.ready, timeout)

    def wait_rx_ok(self, timeout=2.0):
        return self._wait(self.rx_ok, timeout)

    @staticmethod
    def _wait(cond, timeout):
        deadline = time.time() + timeout
        while time.time() < deadline:
            if cond():
                return True
            time.sleep(0.01)
        return False

    def print_status(self):
        status = self.status()
        tx_freq, rx_freq = self.measure_clocks()
        print(f"{self.name} ({self.role})")
        print(f"  GTP TX ready     : {self.reg('serdes_tx_ready').read()}")
        print(f"  GTP RX ready     : {self.reg('serdes_rx_ready').read()}")
        print(f"  TX/RX clk        : {tx_freq/1e6:.3f}MHz / {rx_freq/1e6:.3f}MHz")
        print(f"  TX/RX polarity   : {self.reg('tx_polarity').read()} / {self.reg('rx_polarity').read()}")
        print(f"  RX OK            : {int(bool(status & STATUS_RX_OK))}")
        print(f"  Remote OK        : {int(bool(status & STATUS_REMOTE_OK))}")
        print(f"  Link ready       : {int(bool(status & STATUS_READY))}")
        print(f"  RX errors        : {self.reg('phy_rx_errors').read()}")
        print(f"  RX overflow      : {self.reg('phy_rx_overflow').read()}")
        print(f"  Link drops       : {self.reg('phy_link_drops').read()}")
        print(f"  SerWB overflows  : {self.reg('core_rx_overflows').read()}")
        if self.role == "initiator":
            print(f"  Window page      : 0x{self.reg('window_page').read():x}")

    def rx_reset(self):
        self.reg("serdes_rx_enable").write(0)
        self.reg("serdes_rx_enable").write(1)

    def autopolarity(self, timeout=0.5):
        # Toggle local RX polarity until valid IDLEs are received from the remote TX.
        for attempt in range(2):
            if self.wait_rx_ok(timeout):
                return self.reg("rx_polarity").read()
            self.reg("rx_polarity").write(self.reg("rx_polarity").read() ^ 1)
            self.rx_reset()
        return None

# Boards / Links -----------------------------------------------------------------------------------

def open_buses(args):
    buses = {}
    for board in args.boards:
        csr_csv = args.csr_csv_b if (board == "B" and args.csr_csv_b) else args.csr_csv
        port    = {"A": args.port_a, "B": args.port_b}[board]
        bus = RemoteClient(host=args.host, port=port, csr_csv=csr_csv)
        bus.open()
        buses[board] = bus
    return buses

def get_links(buses):
    links = []
    for board, bus in buses.items():
        for n in [0, 1]:
            if SFPLink.present(bus, n):
                links.append(SFPLink(board, bus, n))
    return links

def read_ident(bus, base):
    ident = ""
    for i in range(256):
        c = bus.read(base + 4*i) & 0xff
        if c == 0:
            break
        ident += chr(c)
    return ident

# Wiring -------------------------------------------------------------------------------------------

def discover_wiring(buses, log=print):
    """Detect the cabling: the TX of each link is silenced in turn (GTP TX inhibit, no reset) and
    the link that stops receiving is its peer. Returns the (tx, rx) directions."""
    links = get_links(buses)
    for link in links:
        if not hasattr(link.bus.regs, f"sfp{link.n}_serdes_tx_inhibit"):
            raise RuntimeError("Gateware without serdes_tx_inhibit CSR: cannot detect the wiring.")
    rx_ok = {link.name: link.rx_ok() for link in links}
    pairs = []
    for link in links:
        link.reg("serdes_tx_inhibit").write(1)
        time.sleep(0.05)
        lost = [o for o in links if (o is not link) and rx_ok[o.name] and not o.rx_ok()]
        link.reg("serdes_tx_inhibit").write(0)
        for o in lost:
            if not o.wait_rx_ok(1.0):
                o.rx_reset()
                o.wait_rx_ok(2.0)
        if len(lost) == 1:
            pairs.append((link, lost[0]))
        elif len(lost) > 1:
            log(f"{link.name}: ambiguous wiring ({', '.join(o.name for o in lost)} lost RX).")
    # Silencing TX drops the links: wait for them and start from clean counters.
    for link in links:
        if rx_ok[link.name]:
            link.wait_ready()
        link.reset_counters()
    return pairs

class Wiring:
    """Detected cabling: cables (both directions receive), one-way directions, unconnected links,
    directions (tx, rx) of the cables, initiator -> target paths and scenario."""
    def __init__(self, buses, pairs):
        names = {(tx.name, rx.name) for tx, rx in pairs}
        self.cables = []
        self.oneway = []
        for tx, rx in pairs:
            if (rx.name, tx.name) in names:
                if tx.name < rx.name:
                    self.cables.append((tx, rx))
            else:
                self.oneway.append((tx, rx))
        used = {l.name for c in self.cables + self.oneway for l in c}
        self.unconnected = [l for l in get_links(buses) if l.name not in used]
        self.mismatched  = [(a, b) for a, b in self.cables if a.role == b.role]
        self.directions  = [d for a, b in self.cables for d in [(a, b), (b, a)]]
        self.paths       = [(tx, rx) for tx, rx in self.directions
            if tx.role == "initiator" and rx.role == "target"]
        between = [c for c in self.cables if c[0].board != c[1].board]
        local   = [c for c in self.cables if c[0].board == c[1].board]
        if len(between) == 2:
            self.scenario = "3"
        elif len(between) == 1:
            self.scenario = "2"
        elif local:
            self.scenario = "1 (board " + ", ".join(sorted({a.board for a, b in local})) + ")"
        else:
            self.scenario = None
        if between and local:
            self.scenario += " + 1 (board " + ", ".join(sorted({a.board for a, b in local})) + ")"

    def cable_name(self, a, b):
        return f"{a.name} <-> {b.name}"

    def describe(self, log=print):
        for a, b in self.cables:
            if a.role == b.role:
                note = f"both {a.role}s: not SFP0 <-> SFP1, remote access will not work"
            elif a.board == b.board:
                note = f"scenario 1 on board {a.board}"
            else:
                note = "between boards"
            log(f"cable: {self.cable_name(a, b)} ({note})")
        for tx, rx in self.oneway:
            log(f"one-way: {tx.name} -> {rx.name} (the other direction does not receive: check {tx.name} RX/polarity)")
        for link in self.unconnected:
            log(f"{link.name}: not connected.")
        if self.scenario is None:
            log("No cable detected: run autopolarity first and check the cabling.")
        else:
            log(f"=> scenario {self.scenario}.")

def get_wiring(buses, log=print):
    wiring = Wiring(buses, discover_wiring(buses, log=log))
    wiring.describe(log=log)
    return wiring

# Bench (bandwidth/latency, see soc2soc/bench.py) ---------------------------------------------------

class Bench:
    """Wishbone traffic generator of one board."""
    def __init__(self, board, bus):
        self.board   = board
        self.bus     = bus
        self.sys_clk = bus.constants.config_clock_frequency

    @staticmethod
    def present(bus):
        return hasattr(bus.regs, "bench_start")

    def reg(self, name):
        return getattr(self.bus.regs, f"bench_{name}")

    def start(self, base, length, wrap, write, seed=0x5eed1234):
        assert wrap & (wrap + 1) == 0, "wrap must be 2**n - 1."
        self.length = length
        self.reg("base").write(base)
        self.reg("length").write(length)
        self.reg("wrap").write(wrap)
        self.reg("seed").write(seed)
        self.reg("control").write(int(write))
        self.reg("start").write(1)

    def wait(self, timeout=60.0):
        deadline = time.time() + timeout
        while not self.reg("done").read():
            if time.time() > deadline:
                raise TimeoutError(f"{self.board}: bench run not done after {timeout}s.")
            time.sleep(0.01)
        cycles  = self.reg("cycles").read()
        latency = self.reg("latency").read()
        seconds = cycles/self.sys_clk
        return {
            "mbps"       : self.length*4/seconds/1e6 if cycles else 0.0,
            "access_ns"  : seconds/self.length*1e9,
            "latency_ns" : latency/self.sys_clk*1e9,
            "errors"     : self.reg("errors").read(),
        }

def run_bench(runs, length, log=print):
    """Write then read (with check) runs = [(name, bench, link, page, base, wrap)], all at the same
    time. Returns {name: {"write": result, "read": result}}."""
    results = {run[0]: {} for run in runs}
    for name, bench, link, page, base, wrap in runs:
        if link is not None:
            link.reg("window_page").write(page)
    for mode in ["write", "read"]:
        for name, bench, link, page, base, wrap in runs:
            bench.start(base, length, wrap, write=(mode == "write"))
        for name, bench, *_ in runs:
            results[name][mode] = r = bench.wait()
            log(f"  {name:28s} {mode:5s}: {r['mbps']:8.2f} MB/s ({r['mbps']*8:7.1f} Mbit/s), "
                f"access {r['access_ns']:7.1f} ns avg / {r['latency_ns']:7.1f} ns max, {r['errors']} errors")
    return results

# Tests (return results, used by the commands and by run) ------------------------------------------

def test_autopolarity(links, log=print):
    """Returns {link.name: polarity or None (no signal)}."""
    results = {}
    for link in links:
        results[link.name] = polarity = link.autopolarity()
        if polarity is None:
            log(f"{link.name}: no signal with either RX polarity (not connected?).")
        else:
            log(f"{link.name}: RX OK with rx_polarity={polarity} (build option: --sfp{link.n}-rx-polarity={polarity}).")
    for link in links:
        if results[link.name] is not None:
            link.wait_ready()
    # Polarity changes cause RX errors and link drops: start from clean counters.
    for link in links:
        link.reset_counters()
    return results

def test_status(link, linerate, log=None):
    """Checks the status of a connected link. Returns (pass, notes)."""
    status = link.status()
    tx_freq, rx_freq = link.measure_clocks()
    ref = linerate/20
    checks = {
        "GTP TX ready"    : link.reg("serdes_tx_ready").read() == 1,
        "GTP RX ready"    : link.reg("serdes_rx_ready").read() == 1,
        "TX clk"          : abs(tx_freq - ref)/ref < 1e-3,
        "RX clk"          : abs(rx_freq - ref)/ref < 1e-3,
        "RX OK"           : bool(status & STATUS_RX_OK),
        "Remote OK"       : bool(status & STATUS_REMOTE_OK),
        "Link ready"      : bool(status & STATUS_READY),
        "RX errors"       : link.reg("phy_rx_errors").read() == 0,
        "RX overflow"     : link.reg("phy_rx_overflow").read() == 0,
        "Link drops"      : link.reg("phy_link_drops").read() == 0,
        "SerWB overflows" : link.reg("core_rx_overflows").read() == 0,
    }
    failed = [k for k, ok in checks.items() if not ok]
    notes  = f"clk {tx_freq/1e6:.3f}/{rx_freq/1e6:.3f}MHz" + (f", FAILED: {', '.join(failed)}" if failed else "")
    if log is not None:
        log(f"{link.name}: {'PASS' if not failed else 'FAIL'} ({notes})")
    return (not failed), notes

def test_prbs(directions, mode="prbs31", duration=10, linerate=2.5e9, log=print):
    """PRBS/BER test on (tx, rx) directions. Returns {"tx->rx": (errors, ber_bound)}."""
    code = PRBS_MODES[mode]
    # Configure PRBS.
    for tx, rx in directions:
        tx.reg("serdes_tx_prbs_config").write(code)
        rx.reg("serdes_rx_prbs_config").write(code)
    time.sleep(0.1)
    # Run PRBS/BER test.
    log(f"Running {mode.upper()} test for {duration}s at {linerate/1e9:.3f}Gbps...")
    errors_last = {}
    errors_total = {}
    for tx, rx in directions:
        rx.reg("serdes_rx_prbs_config").write(PRBS_PAUSE | code)
        errors_last[rx.name] = rx.reg("serdes_rx_prbs_errors").read()
        rx.reg("serdes_rx_prbs_config").write(code)
        errors_total[rx.name] = 0
    elapsed  = 0.0
    interval = 1.0
    try:
        while elapsed < duration:
            time.sleep(interval)
            elapsed += interval
            line = []
            for tx, rx in directions:
                rx.reg("serdes_rx_prbs_config").write(PRBS_PAUSE | code)
                errors = rx.reg("serdes_rx_prbs_errors").read()
                rx.reg("serdes_rx_prbs_config").write(code)
                errors_total[rx.name] += (errors - errors_last[rx.name]) % 2**32
                errors_last[rx.name] = errors
                ber = errors_total[rx.name]/(elapsed*linerate)
                line.append(f"{tx.name}->{rx.name}: {errors_total[rx.name]:10d} errors, BER<={max(ber, 1/(elapsed*linerate)):1.2e}")
            log(f"{elapsed:6.1f}s | " + " | ".join(line))
    except KeyboardInterrupt:
        pass
    # Restore normal operation.
    for tx, rx in directions:
        tx.reg("serdes_tx_prbs_config").write(0)
        rx.reg("serdes_rx_prbs_config").write(0)
    # The link layer sees the PRBS pattern as errors and the links drop: once they are back up,
    # clear the counters so that status reflects normal operation again.
    links = list({rx.name: rx for tx, rx in directions}.values())
    ready = {link.name: link.wait_ready() for link in links}
    for link in links:
        if link.reset_counters():
            log(f"{link.name}: link ready: {int(ready[link.name])} (RX errors / link drops counters cleared).")
        else:
            log(f"{link.name}: link ready: {int(ready[link.name])} (RX errors / link drops include the PRBS test).")
    elapsed = max(elapsed, interval)
    return {f"{tx.name}->{rx.name}": (errors_total[rx.name], max(errors_total[rx.name], 1)/(elapsed*linerate))
        for tx, rx in directions}

def test_remote(paths, length=256, log=print):
    """Remote access through each (initiator, target) path. Returns {"init->target": dict(ready,
    ident_ok, errors, direct_errors)}."""
    results = {}
    for link, target in paths:
        name   = f"{link.name}->{target.name}"
        bus    = link.bus
        remote = target.bus
        results[name] = r = {"ready": link.ready()}
        if not r["ready"]:
            log(f"{name}: link not ready, skipping.")
            continue
        window = getattr(bus.mems, f"sfp{link.n}_remote").base

        def remote_addr(addr):
            link.reg("window_page").write(addr >> 28)
            return window + (addr & (WINDOW_SIZE - 1))

        # Remote Identifier (compared with a direct read on the target board).
        ident    = read_ident(bus, remote_addr(remote.bases.identifier_mem))
        expected = read_ident(remote, remote.bases.identifier_mem)
        r["ident_ok"] = (ident == expected)
        log(f"{name}: remote identifier: {ident} ({'OK' if r['ident_ok'] else 'MISMATCH'})")

        # Remote Mailbox Write/Read, then direct check on the target board.
        mailbox = remote.mems.mailbox
        words   = min(length, mailbox.size//4)
        data    = [random.getrandbits(32) for _ in range(words)]
        base    = remote_addr(mailbox.base)
        start   = time.time()
        for i, d in enumerate(data):
            bus.write(base + 4*i, d)
        readback = [bus.read(base + 4*i) for i in range(words)]
        duration = time.time() - start
        r["words"]  = words
        r["errors"] = sum(a != b for a, b in zip(data, readback))
        log(f"{name}: remote mailbox write/read of {words} words: {r['errors']} errors ({duration:.2f}s).")
        direct = [remote.read(mailbox.base + 4*i) for i in range(words)]
        r["direct_errors"] = sum(a != b for a, b in zip(data, direct))
        log(f"{name}: direct check on board {target.board}: {r['direct_errors']} errors.")
    return results

def test_bandwidth(buses, paths, length, linerate, log=print):
    """Bandwidth/latency: local mailbox of each board (reference), each path alone, then all paths
    at the same time (one per board). Returns {"alone": {...}, "concurrent": {...} or None}."""
    for board, bus in buses.items():
        if not Bench.present(bus):
            raise RuntimeError(f"{board}: no bench in the gateware (built with --no-bench?).")
    capacity = linerate/20*2*128/129
    log(f"Link layer payload capacity: {capacity/1e6:.1f} MB/s per direction at {linerate/1e9:.3f}Gbps.")
    log(f"Each run: {length} x 32-bit accesses, one in flight at a time.")
    benches = {board: Bench(board, bus) for board, bus in buses.items()}
    runs = []
    # Local mailbox of each board: reference without link.
    for board, bus in buses.items():
        mailbox = bus.mems.mailbox
        runs.append((f"{board} local mailbox", benches[board], None, None, mailbox.base, mailbox.size//4 - 1))
    # Remote mailbox through each initiator -> target path.
    remote = []
    for link, target in paths:
        if not link.ready():
            log(f"{link.name}: link not ready, skipping.")
            continue
        mailbox = target.bus.mems.mailbox
        window  = getattr(link.bus.mems, f"sfp{link.n}_remote").base
        remote.append((f"{link.name}->{target.name}", benches[link.board], link, mailbox.base >> 28,
            window + (mailbox.base & (WINDOW_SIZE - 1)), mailbox.size//4 - 1))
    results = {"alone": {}, "concurrent": None}
    log("Each path alone:")
    for run in runs + remote:
        results["alone"].update(run_bench([run], length, log=log))
    # All paths at the same time (one bench per board: one path per board at a time).
    boards = [run[1].board for run in remote]
    if len(boards) > 1 and len(set(boards)) == len(boards):
        log("All paths at the same time:")
        results["concurrent"] = run_bench(remote, length, log=log)
        for mode in ["write", "read"]:
            total = sum(r[mode]["mbps"] for r in results["concurrent"].values())
            log(f"  {'aggregate':28s} {mode:5s}: {total:8.2f} MB/s ({total*8:7.1f} Mbit/s)")
    return results

# Commands -----------------------------------------------------------------------------------------

def cmd_ident(buses, args):
    for board, bus in buses.items():
        print(f"{board}: {read_ident(bus, bus.bases.identifier_mem)}")

def cmd_status(buses, args):
    for link in get_links(buses):
        link.print_status()

def cmd_autopolarity(buses, args):
    links   = get_links(buses)
    results = test_autopolarity(links)
    for link in links:
        if results[link.name] is not None:
            print(f"{link.name}: link ready: {int(link.ready())}")

def cmd_wiring(buses, args):
    get_wiring(buses)

def cmd_prbs(buses, args):
    wiring = get_wiring(buses)
    if wiring.directions:
        test_prbs(wiring.directions, mode=args.mode, duration=args.duration, linerate=args.linerate)

def cmd_remote(buses, args):
    wiring = get_wiring(buses)
    if not wiring.paths:
        print("No initiator -> target cable detected.")
        return
    test_remote(wiring.paths, length=args.length)

def cmd_bandwidth(buses, args):
    wiring = get_wiring(buses)
    test_bandwidth(buses, wiring.paths, length=args.bench_length, linerate=args.linerate)

# Run (full test sequence) -------------------------------------------------------------------------

def cmd_run(buses, args):
    """Full test sequence on whatever is connected: ident, autopolarity, wiring, status, PRBS, remote,
    bandwidth and final status, with the pass criteria of docs/test-procedure.md."""
    steps = [] # (step, result, notes)
    def step(name, ok, notes=""):
        result = {True: "PASS", False: "FAIL", None: "SKIP"}[ok]
        steps.append((name, result, notes))
        print(f"### {name}: {result}" + (f" ({notes})" if notes else ""))

    def section(title):
        print(f"\n=== {title} " + "="*max(0, 90 - len(title)))

    links = get_links(buses)

    section("Ident")
    idents = {board: read_ident(bus, bus.bases.identifier_mem) for board, bus in buses.items()}
    for board, ident in idents.items():
        print(f"{board}: {ident}")
    step("Ident", all("SoC2SoC" in i for i in idents.values()), ", ".join(sorted(idents)))

    section("Autopolarity")
    before = {link.name: link.reg("rx_polarity").read() for link in links}
    polarities = test_autopolarity(links)

    section("Wiring")
    wiring = get_wiring(buses)
    connected = {l.name for c in wiring.cables for l in c}
    changed = [f"{n} rx_polarity={p}" for n, p in polarities.items()
        if n in connected and p is not None and p != before[n]]
    no_rx = [n for n in connected if polarities[n] is None]
    step("Autopolarity", not no_rx,
        (f"changed: {', '.join(changed)}" if changed else "connected SFPs OK with current polarities") +
        (f"; no signal: {', '.join(no_rx)}" if no_rx else ""))
    wiring_ok = bool(wiring.cables) and not wiring.oneway and not wiring.mismatched
    step("Wiring", wiring_ok,
        "; ".join([f"scenario {wiring.scenario}"] +
                  [wiring.cable_name(a, b) for a, b in wiring.cables] +
                  [f"one-way {tx.name}->{rx.name}" for tx, rx in wiring.oneway] +
                  [f"not connected: {', '.join(l.name for l in wiring.unconnected)}"] * bool(wiring.unconnected)))
    if not wiring.cables:
        print("No cable detected: stopping.")
        return finish(args, buses, idents, wiring, polarities, steps, None)
    cable_links = [l for c in wiring.cables for l in c]

    section("Status")
    status = {link.name: test_status(link, args.linerate, log=print) for link in cable_links}
    step("Status", all(ok for ok, _ in status.values()),
        "; ".join(f"{n}: {notes}" for n, (ok, notes) in status.items()))

    section("PRBS")
    prbs = test_prbs(wiring.directions, mode=args.mode, duration=args.duration, linerate=args.linerate)
    step(f"PRBS ({args.mode}, {args.duration}s)", all(e == 0 for e, _ in prbs.values()),
        "; ".join(f"{d}: {e} errors, BER<={ber:.2e}" for d, (e, ber) in prbs.items()))

    section("Remote")
    if wiring.paths:
        remote = test_remote(wiring.paths, length=args.length)
        ok = all(r["ready"] and r.get("ident_ok") and r.get("errors") == 0 and r.get("direct_errors") == 0
            for r in remote.values())
        step("Remote", ok, "; ".join(
            f"{n}: " + ("link not ready" if not r["ready"] else
                f"ident {'OK' if r['ident_ok'] else 'MISMATCH'}, {r['errors']} errors, direct {r['direct_errors']} errors")
            for n, r in remote.items()))
    else:
        step("Remote", None, "no initiator -> target cable")

    section("Bandwidth")
    bandwidth = None
    if args.bench_length and wiring.paths:
        bandwidth = test_bandwidth(buses, wiring.paths, length=args.bench_length, linerate=args.linerate)
        all_runs  = list(bandwidth["alone"].values()) + list((bandwidth["concurrent"] or {}).values())
        ok = all(r[m]["errors"] == 0 for r in all_runs for m in ["write", "read"])
        step("Bandwidth", ok, "; ".join(
            f"{n}: {r['write']['mbps']:.1f}/{r['read']['mbps']:.2f} MB/s"
            for n, r in bandwidth["alone"].items() if "->" in n))
    else:
        step("Bandwidth", None, "disabled (--bench-length=0)" if not args.bench_length else "no initiator -> target cable")

    section("Final status")
    status = {link.name: test_status(link, args.linerate, log=print) for link in cable_links}
    step("Final status", all(ok for ok, _ in status.values()),
        "counters still 0" if all(ok for ok, _ in status.values()) else
        "; ".join(f"{n}: {notes}" for n, (ok, notes) in status.items() if not ok))

    return finish(args, buses, idents, wiring, polarities, steps, bandwidth)

def finish(args, buses, idents, wiring, polarities, steps, bandwidth):
    failed = [s for s in steps if s[1] == "FAIL"]
    print("\n=== Summary " + "="*82)
    for name, result, notes in steps:
        print(f"{name:22s} {result:4s}  {notes}")
    print(f"=> {'PASS' if not failed else 'FAIL'}"
          + (f" (scenario {wiring.scenario})" if wiring is not None and wiring.scenario else ""))
    if args.report:
        with open(args.report, "w") as f:
            f.write(report(args, buses, idents, wiring, polarities, steps, bandwidth))
        print(f"Report written to {args.report}.")
    return not failed

def report(args, buses, idents, wiring, polarities, steps, bandwidth):
    links = get_links(buses)
    pol   = ", ".join(f"{l.name} TX/RX {l.reg('tx_polarity').read()}/{l.reg('rx_polarity').read()}" for l in links)
    lines = [
        f"### SoC2SoC test results: scenario {wiring.scenario if wiring and wiring.scenario else '-'}",
        "",
        f"- Date: {time.strftime('%Y-%m-%d %H:%M')}",
        "- Boards: " + ", ".join(f"{b} (litex_server port {args.port_a if b == 'A' else args.port_b})" for b in buses),
        f"- Gateware: {', '.join(f'{b}: {i}' for b, i in idents.items())}",
        f"- Cabling: " + ("; ".join(wiring.cable_name(a, b) for a, b in wiring.cables) or "none")
            + ("; not connected: " + ", ".join(l.name for l in wiring.unconnected) if wiring.unconnected else ""),
        f"- Polarities: {pol}",
        f"- Line rate: {args.linerate/1e9:.3f} Gbps",
        "",
        "| Step | Result | Notes |",
        "|------|--------|-------|",
    ] + [f"| {n} | {r} | {notes} |" for n, r, notes in steps]
    if bandwidth:
        lines += [
            "",
            f"#### Bandwidth ({args.bench_length} x 32-bit accesses per run, one in flight at a time)",
            "",
            f"Link layer payload capacity: {args.linerate/20*2*128/129/1e6:.1f} MB/s per direction.",
            "",
            "| Path | Write | Read | Access avg / max (write) | Access avg / max (read) | Errors |",
            "|------|-------|------|--------------------------|-------------------------|--------|",
        ]
        def row(name, r):
            w, rd = r["write"], r["read"]
            return (f"| {name} | {w['mbps']:.2f} MB/s | {rd['mbps']:.2f} MB/s | "
                    f"{w['access_ns']:.1f} / {w['latency_ns']:.0f} ns | {rd['access_ns']:.1f} / {rd['latency_ns']:.0f} ns | "
                    f"{w['errors'] + rd['errors']} |")
        for name, r in bandwidth["alone"].items():
            lines.append(row(name, r))
        if bandwidth["concurrent"]:
            for name, r in bandwidth["concurrent"].items():
                lines.append(row(f"{name} (all paths at once)", r))
            w = sum(r["write"]["mbps"] for r in bandwidth["concurrent"].values())
            rd = sum(r["read"]["mbps"] for r in bandwidth["concurrent"].values())
            lines.append(f"| Aggregate (all paths at once) | {w:.2f} MB/s | {rd:.2f} MB/s | | | |")
    return "\n".join(lines) + "\n"

# Run ----------------------------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description="SoC2SoC over SerDes test utility.")
    parser.add_argument("--boards",       default="A", choices=["A", "B", "AB"], help="Boards to use (one litex_server each).")
    parser.add_argument("--host",         default="localhost",     help="litex_server host.")
    parser.add_argument("--port-a",       default=BOARD_PORTS["A"], type=int, help="litex_server port of board A.")
    parser.add_argument("--port-b",       default=BOARD_PORTS["B"], type=int, help="litex_server port of board B.")
    parser.add_argument("--csr-csv",      default="build/sqrl_acorn/csr.csv", help="CSR configuration file (all boards).")
    parser.add_argument("--csr-csv-b",    default=None,            help="CSR configuration file of board B, if it runs a different build.")
    parser.add_argument("--mode",         default="prbs31", choices=list(PRBS_MODES.keys()), help="PRBS mode.")
    parser.add_argument("--duration",     default=10, type=int,    help="PRBS test duration (s).")
    parser.add_argument("--linerate",     default=2.5e9, type=float, help="Linerate (for clocks, BER and capacity).")
    parser.add_argument("--length",       default=256, type=int,   help="Remote mailbox test length (words).")
    parser.add_argument("--bench-length", default=2**22, type=int, help="Bandwidth test length (32-bit accesses per run, 0: skip in run).")
    parser.add_argument("--report",       default=None,            help="run: write a Markdown results report to this file.")
    parser.add_argument("command", choices=["ident", "status", "autopolarity", "wiring", "prbs", "remote", "bandwidth", "run"])
    args = parser.parse_args()

    buses = open_buses(args)
    try:
        result = {
            "ident"        : cmd_ident,
            "status"       : cmd_status,
            "autopolarity" : cmd_autopolarity,
            "wiring"       : cmd_wiring,
            "prbs"         : cmd_prbs,
            "remote"       : cmd_remote,
            "bandwidth"    : cmd_bandwidth,
            "run"          : cmd_run,
        }[args.command](buses, args)
    finally:
        for bus in buses.values():
            bus.close()
    if args.command == "run" and result is False:
        raise SystemExit(1)

if __name__ == "__main__":
    main()
