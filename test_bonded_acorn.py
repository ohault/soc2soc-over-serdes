#!/usr/bin/env python3
# SPDX-License-Identifier: BSD-2-Clause
"""Monitor the bidirectional bonded packet tester on two Acorn boards."""

from __future__ import annotations

import argparse
import time

from litex import RemoteClient


BOARD_PORTS = {"A": 1234, "B": 1235}
SESSION_ACTIVE = 1 << 0
CONTROL_FAULT = 1 << 1
LANE0_UP = 1 << 2
LANE1_UP = 1 << 3
TESTER_ERROR = 1 << 4
PHY_TX_ERROR = (1 << 5) | (1 << 6)
PHY_RX_ERROR = (1 << 7) | (1 << 8)
GTP_RX_INVALID = (1 << 9) | (1 << 10)
ERROR_MASK = TESTER_ERROR | PHY_TX_ERROR | PHY_RX_ERROR | GTP_RX_INVALID
HEALTHY_MASK = SESSION_ACTIVE | LANE0_UP | LANE1_UP
PACKET_BYTES = 64


def open_buses(args):
    buses = {}
    for board in args.boards:
        csr_csv = args.csr_csv_b if board == "B" and args.csr_csv_b else args.csr_csv
        bus = RemoteClient(
            host=args.host,
            port=BOARD_PORTS[board] if board == "A" else args.port_b,
            csr_csv=csr_csv,
        )
        bus.open()
        buses[board] = bus
    return buses


def read_board(bus):
    return {
        "status": bus.regs.bond_status.read(),
        "tx": bus.regs.bond_tx_packets.read(),
        "rx": bus.regs.bond_rx_packets.read(),
    }


def status_text(value):
    flags = [
        ("session", bool(value & SESSION_ACTIVE)),
        ("control_fault", bool(value & CONTROL_FAULT)),
        ("lane0", bool(value & LANE0_UP)),
        ("lane1", bool(value & LANE1_UP)),
        ("tester_error", bool(value & TESTER_ERROR)),
        ("phy_tx_error0", bool(value & (1 << 5))),
        ("phy_tx_error1", bool(value & (1 << 6))),
        ("phy_rx_error0", bool(value & (1 << 7))),
        ("phy_rx_error1", bool(value & (1 << 8))),
        ("gtp_rx_invalid0", bool(value & (1 << 9))),
        ("gtp_rx_invalid1", bool(value & (1 << 10))),
    ]
    return " ".join(f"{name}={'yes' if active else 'no'}" for name, active in flags)


def healthy(snapshot):
    status = snapshot["status"]
    return (status & HEALTHY_MASK) == HEALTHY_MASK and not (status & (CONTROL_FAULT | ERROR_MASK))


def report(buses):
    snapshots = {}
    for board, bus in buses.items():
        snap = read_board(bus)
        snapshots[board] = snap
        print(
            f"{board}: {status_text(snap['status'])} "
            f"tx={snap['tx']} rx={snap['rx']}"
        )
    return snapshots


def wait_active(buses, timeout, poll_interval):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        snapshots = {board: read_board(bus) for board, bus in buses.items()}
        if all(healthy(snap) for snap in snapshots.values()):
            return snapshots
        time.sleep(poll_interval)
    print("Timed out waiting for a healthy bonded session:")
    report(buses)
    return None


def delta32(start, end):
    return (end - start) & 0xFFFFFFFF


def main():
    parser = argparse.ArgumentParser(
        description="Inspect and verify the Acorn two-lane bonded packet tester."
    )
    parser.add_argument("--boards", default="AB", choices=["A", "B", "AB"])
    parser.add_argument("--host", default="localhost", help="litex_server host.")
    parser.add_argument("--port-a", type=int, default=BOARD_PORTS["A"])
    parser.add_argument("--port-b", type=int, default=BOARD_PORTS["B"])
    parser.add_argument("--csr-csv", required=True, help="CSR CSV from the bonded Acorn build.")
    parser.add_argument("--csr-csv-b", default=None, help="Optional CSR CSV for board B.")
    parser.add_argument("--timeout", type=float, default=60.0)
    parser.add_argument("--poll-interval", type=float, default=0.25)
    parser.add_argument("--duration", type=float, default=10.0)
    parser.add_argument("command", choices=["status", "wait-active", "monitor"])
    args = parser.parse_args()
    if args.command == "monitor" and args.boards != "AB":
        parser.error("monitor requires --boards=AB")

    # Keep board A's configurable port separate from the fixed lookup table.
    BOARD_PORTS["A"] = args.port_a
    buses = open_buses(args)
    try:
        if args.command == "status":
            snapshots = report(buses)
            return 0 if all(healthy(snap) for snap in snapshots.values()) else 1

        before = wait_active(buses, args.timeout, args.poll_interval)
        if before is None:
            return 1
        if args.command == "wait-active":
            report(buses)
            return 0

        time.sleep(args.duration)
        after = report(buses)
        a_tx = delta32(before["A"]["tx"], after["A"]["tx"])
        a_rx = delta32(before["A"]["rx"], after["A"]["rx"])
        b_tx = delta32(before["B"]["tx"], after["B"]["tx"])
        b_rx = delta32(before["B"]["rx"], after["B"]["rx"])
        print(f"A: TX {a_tx} packets ({a_tx / args.duration:.2f} pkt/s)")
        print(f"A: RX {a_rx} packets ({a_rx / args.duration:.2f} pkt/s)")
        print(f"B: TX {b_tx} packets ({b_tx / args.duration:.2f} pkt/s)")
        print(f"B: RX {b_rx} packets ({b_rx / args.duration:.2f} pkt/s)")
        print(f"Aggregate TX payload: {(a_tx + b_tx) * PACKET_BYTES / args.duration:.1f} bytes/s")
        if abs(a_tx - b_rx) > 1 or abs(b_tx - a_rx) > 1:
            print("FAIL: peer TX/RX packet deltas do not match.")
            return 1
        if any(snap["status"] & ERROR_MASK for snap in after.values()):
            print("FAIL: tester or PHY error latched during the measurement.")
            return 1
        print("PASS: both peers exchanged and checked matching packet counts.")
        return 0
    finally:
        for bus in buses.values():
            bus.close()


if __name__ == "__main__":
    raise SystemExit(main())
