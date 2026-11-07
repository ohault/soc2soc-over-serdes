#!/usr/bin/env python3

#
# This file is part of soc2soc-over-serdes.
#
# SPDX-License-Identifier: BSD-2-Clause

# SoC2SoC over SerDes bring-up/test utility (through litex_server).
#
# Single board (scenario 1, SFP0 <-> SFP1 on the same board):
#   litex_server --uart --uart-port=/dev/ttyUSBX
#   ./test_soc2soc.py status
#   ./test_soc2soc.py autopolarity
#   ./test_soc2soc.py prbs
#   ./test_soc2soc.py remote
#
# Two boards (scenarios 2/3): one litex_server per board on different ports, e.g.:
#   litex_server --uart --uart-port=/dev/ttyUSBX --bind-port=1234   (board A)
#   litex_server --uart --uart-port=/dev/ttyUSBY --bind-port=1235   (board B)
#   ./test_soc2soc.py --csr-csv=a/csr.csv --port=1234 --peer-csr-csv=b/csr.csv --peer-port=1235 status
#   (prbs/autopolarity/remote then use both boards; status/autopolarity also work on a single board).

import sys
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
        deadline = time.time() + timeout
        while time.time() < deadline:
            if self.ready():
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
            deadline = time.time() + timeout
            while time.time() < deadline:
                if self.rx_ok():
                    return self.reg("rx_polarity").read()
                time.sleep(0.01)
            self.reg("rx_polarity").write(self.reg("rx_polarity").read() ^ 1)
            self.rx_reset()
        return None

# Helpers ------------------------------------------------------------------------------------------

def open_buses(args):
    buses = {}
    bus = RemoteClient(host=args.host, port=args.port, csr_csv=args.csr_csv)
    bus.open()
    buses["local"] = bus
    if args.peer_port is not None:
        peer = RemoteClient(host=args.peer_host, port=args.peer_port, csr_csv=args.peer_csr_csv)
        peer.open()
        buses["peer"] = peer
    return buses

def get_links(buses):
    links = []
    for board, bus in buses.items():
        for n in [0, 1]:
            if SFPLink.present(bus, n):
                links.append(SFPLink(board, bus, n))
    return links

def get_pairs(buses):
    # Returns the (tx, rx) directions of the cabling.
    local = buses["local"]
    if "peer" not in buses:
        # Single board: SFP0 <-> SFP1.
        a, b = SFPLink("local", local, 0), SFPLink("local", local, 1)
        return [(a, b), (b, a)]
    # Two boards: local SFPn <-> peer SFPn.
    peer  = buses["peer"]
    pairs = []
    for n in [0, 1]:
        if SFPLink.present(local, n) and SFPLink.present(peer, n):
            a, b = SFPLink("local", local, n), SFPLink("peer", peer, n)
            pairs += [(a, b), (b, a)]
    return pairs

def read_ident(bus, base):
    ident = ""
    for i in range(256):
        c = bus.read(base + 4*i) & 0xff
        if c == 0:
            break
        ident += chr(c)
    return ident

# Commands -----------------------------------------------------------------------------------------

def cmd_ident(buses, args):
    for board, bus in buses.items():
        print(f"{board}: {read_ident(bus, bus.bases.identifier_mem)}")

def cmd_status(buses, args):
    for link in get_links(buses):
        link.print_status()

def cmd_autopolarity(buses, args):
    for link in get_links(buses):
        polarity = link.autopolarity()
        if polarity is None:
            print(f"{link.name}: no valid IDLEs received with either RX polarity (check cabling/linerate/remote).")
        else:
            print(f"{link.name}: RX OK with rx_polarity={polarity} (build option: --sfp{link.n}-rx-polarity={polarity}).")
    links = get_links(buses)
    ready = {link.name: link.wait_ready() for link in links}
    # Polarity changes cause RX errors and link drops: start from clean counters.
    for link in links:
        link.reset_counters()
    for link in links:
        print(f"{link.name}: link ready: {int(ready[link.name])}")

def cmd_prbs(buses, args):
    mode  = PRBS_MODES[args.mode]
    pairs = get_pairs(buses)
    if not pairs:
        print("No SFP pair found (two boards: same SFP must be enabled on both).")
        return
    # Configure PRBS.
    for tx, rx in pairs:
        tx.reg("serdes_tx_prbs_config").write(mode)
        rx.reg("serdes_rx_prbs_config").write(mode)
    time.sleep(0.1)
    # Run PRBS/BER test.
    print(f"Running {args.mode.upper()} test for {args.duration}s at {args.linerate/1e9:.3f}Gbps...")
    errors_last = {}
    errors_total = {}
    for tx, rx in pairs:
        rx.reg("serdes_rx_prbs_config").write(PRBS_PAUSE | mode)
        errors_last[rx.name] = rx.reg("serdes_rx_prbs_errors").read()
        rx.reg("serdes_rx_prbs_config").write(mode)
        errors_total[rx.name] = 0
    elapsed  = 0.0
    interval = 1.0
    try:
        while elapsed < args.duration:
            time.sleep(interval)
            elapsed += interval
            line = []
            for tx, rx in pairs:
                rx.reg("serdes_rx_prbs_config").write(PRBS_PAUSE | mode)
                errors = rx.reg("serdes_rx_prbs_errors").read()
                rx.reg("serdes_rx_prbs_config").write(mode)
                errors_total[rx.name] += (errors - errors_last[rx.name]) % 2**32
                errors_last[rx.name] = errors
                ber = errors_total[rx.name]/(elapsed*args.linerate)
                line.append(f"{tx.name}->{rx.name}: {errors_total[rx.name]:10d} errors, BER<={max(ber, 1/(elapsed*args.linerate)):1.2e}")
            print(f"{elapsed:6.1f}s | " + " | ".join(line))
    except KeyboardInterrupt:
        pass
    # Restore normal operation.
    for tx, rx in pairs:
        tx.reg("serdes_tx_prbs_config").write(0)
        rx.reg("serdes_rx_prbs_config").write(0)
    # The link layer sees the PRBS pattern as errors and the links drop: once they are back up,
    # clear the counters so that status reflects normal operation again.
    links = {rx.name: rx for tx, rx in pairs}.values()
    ready = {link.name: link.wait_ready() for link in links}
    for link in links:
        if link.reset_counters():
            print(f"{link.name}: link ready: {int(ready[link.name])} (RX errors / link drops counters cleared).")
        else:
            print(f"{link.name}: link ready: {int(ready[link.name])} (RX errors / link drops include the PRBS test).")

def cmd_remote(buses, args):
    # Access the remote SoC through each initiator link.
    for board, bus in buses.items():
        for n in [0, 1]:
            if not SFPLink.present(bus, n):
                continue
            link = SFPLink(board, bus, n)
            if link.role != "initiator":
                continue
            if not link.ready():
                print(f"{link.name}: link not ready, skipping.")
                continue
            # Remote memory map: from the peer board when connected, else same gateware (loopback).
            if "peer" in buses:
                remote = buses["peer" if board == "local" else "local"]
            else:
                remote = bus
            window = getattr(bus.mems, f"sfp{n}_remote").base

            def remote_addr(addr):
                link.reg("window_page").write(addr >> 28)
                return window + (addr & (WINDOW_SIZE - 1))

            # Remote Identifier.
            ident = read_ident(bus, remote_addr(remote.bases.identifier_mem))
            print(f"{link.name}: remote identifier: {ident}")

            # Remote Mailbox Write/Read.
            mailbox = remote.mems.mailbox
            words   = min(args.length, mailbox.size//4)
            data    = [random.getrandbits(32) for _ in range(words)]
            base    = remote_addr(mailbox.base)
            start   = time.time()
            for i, d in enumerate(data):
                bus.write(base + 4*i, d)
            readback = [bus.read(base + 4*i) for i in range(words)]
            duration = time.time() - start
            errors = sum(a != b for a, b in zip(data, readback))
            print(f"{link.name}: remote mailbox write/read of {words} words: {errors} errors ({duration:.2f}s).")
            # Direct check on remote board when connected.
            if remote is not bus:
                direct = [remote.read(mailbox.base + 4*i) for i in range(words)]
                errors = sum(a != b for a, b in zip(data, direct))
                print(f"{link.name}: direct check on remote board: {errors} errors.")

# Run ----------------------------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description="SoC2SoC over SerDes test utility.")
    parser.add_argument("--host",         default="localhost",     help="litex_server host (local board).")
    parser.add_argument("--port",         default=1234, type=int,  help="litex_server port (local board).")
    parser.add_argument("--csr-csv",      default="csr.csv",       help="CSR configuration file (local board).")
    parser.add_argument("--peer-host",    default="localhost",     help="litex_server host (peer board).")
    parser.add_argument("--peer-port",    default=None, type=int,  help="litex_server port (peer board, two-board setups).")
    parser.add_argument("--peer-csr-csv", default="peer_csr.csv",  help="CSR configuration file (peer board).")
    parser.add_argument("--mode",         default="prbs31", choices=list(PRBS_MODES.keys()), help="PRBS mode.")
    parser.add_argument("--duration",     default=10, type=int,    help="PRBS test duration (s).")
    parser.add_argument("--linerate",     default=2.5e9, type=float, help="Linerate (for BER computation).")
    parser.add_argument("--length",       default=256, type=int,   help="Remote mailbox test length (words).")
    parser.add_argument("command", choices=["ident", "status", "autopolarity", "prbs", "remote"])
    args = parser.parse_args()

    buses = open_buses(args)
    try:
        {
            "ident"        : cmd_ident,
            "status"       : cmd_status,
            "autopolarity" : cmd_autopolarity,
            "prbs"         : cmd_prbs,
            "remote"       : cmd_remote,
        }[args.command](buses, args)
    finally:
        for bus in buses.values():
            bus.close()

if __name__ == "__main__":
    main()
