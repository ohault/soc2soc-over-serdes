#!/usr/bin/env python3

#
# This file is part of soc2soc-over-serdes.
#
# SPDX-License-Identifier: BSD-2-Clause

# SoC-to-SoC over SerDes on LiteX Acorn Baseboard Mini + Acorn CLE-215+ (GTP / SFP / DAC cables).
#
# Each SFP port can be configured as:
# - none      : not used.
# - initiator : local SoC accesses the remote SoC through a 256MB window of its memory map.
# - target    : remote SoC accesses the local SoC bus.
#
# Default: SFP0 = initiator, SFP1 = target, the same gateware on every board. Every DAC cable joins
# an SFP0 to an SFP1, so moving from one scenario to another is only a matter of moving cables:
# 1) Single board, A.SFP0 <-DAC-> A.SFP1 (can run on boards A and B at the same time).
# 2) Two boards, A.SFP0 <-DAC-> B.SFP1 (A accesses B).
# 3) Two boards, A.SFP0 <-DAC-> B.SFP1 and B.SFP0 <-DAC-> A.SFP1 (each board accesses the other).
#
#   ./acorn_soc2soc.py --build
#   ./acorn_soc2soc.py --load --usb-port=1-3     # Board A (host USB port, see README).
#   ./acorn_soc2soc.py --load --usb-port=1-5     # Board B.
#
# --with-stream adds a bidirectional 32-bit stream port with flow control on each link, next to
# register access (a stream tester is connected to it, see soc2soc/stream.py for your own logic).

import os

from migen import *

from litex.gen import *

from litex.build.io import DifferentialInput
from litex.build.openfpgaloader import OpenFPGALoader

from litex_boards.platforms import sqrl_acorn

from litex.soc.interconnect     import wishbone
from litex.soc.integration.soc  import SoCRegion
from litex.soc.integration.soc_core import SoCCore
from litex.soc.integration.builder  import Builder
from litex.soc.cores.clock import S7PLL

from liteiclink.serdes.gtp_7series import GTPQuadPLL

from soc2soc.serdes_link import GTPSoCLink
import board_lock
from soc2soc.bench       import WishboneBench

# Board Polarities ---------------------------------------------------------------------------------

# Default GTP polarities of the SFP ports (TX, RX). SFP0 values are the ones used by LiteX-Boards for
# 1000BASE-X on this board (RX inverted on Acorn, TX inverted on Acorn and on baseboard). SFP1 is
# assumed to be identical: verify with test_soc2soc.py autopolarity and override with
# --sfp1-tx-polarity/--sfp1-rx-polarity if needed (polarities are also runtime-configurable).
SFP_POLARITIES = {
    0: (0, 1),
    1: (0, 1),
}

# CRG ----------------------------------------------------------------------------------------------

class CRG(LiteXModule):
    def __init__(self, platform, sys_clk_freq, refclk_freq):
        self.rst       = Signal()
        self.cd_sys    = ClockDomain()
        self.cd_refclk = ClockDomain()

        # # #

        # Clk.
        clk200    = platform.request("clk200")
        clk200_se = Signal()
        self.specials += DifferentialInput(clk200.p, clk200.n, clk200_se)

        # Sys PLL.
        self.pll = pll = S7PLL()
        self.comb += pll.reset.eq(self.rst)
        pll.register_clkin(clk200_se, 200e6)
        pll.create_clkout(self.cd_sys, sys_clk_freq)
        platform.add_false_path_constraints(self.cd_sys.clk, pll.clkin)

        # GTP RefClk PLL (no MGTREFCLK routed to the SFPs: GTP QPLL fed from the fabric).
        self.refclk_pll = refclk_pll = S7PLL()
        self.comb += refclk_pll.reset.eq(self.rst)
        refclk_pll.register_clkin(clk200_se, 200e6)
        refclk_pll.create_clkout(self.cd_refclk, refclk_freq, margin=0)

# SoC2SoC ------------------------------------------------------------------------------------------

class SoC2SoC(SoCCore):
    mem_map = {**SoCCore.mem_map, **{
        "mailbox"     : 0x2000_0000,
        "sfp0_remote" : 0x8000_0000,
        "sfp1_remote" : 0x9000_0000,
    }}

    def __init__(self, variant="cle-215+", sys_clk_freq=100e6,
        sfp_roles        = {0: "initiator", 1: "target"},
        sfp_polarities   = SFP_POLARITIES,
        linerate         = 2.5e9,
        refclk_freq      = 125e6,
        with_crc         = False,
        burst_depth      = 64,
        with_stream      = False,
        mailbox_size     = 0x2000,
        with_bench       = True,
        with_led_chaser  = False,
        **kwargs):
        platform = sqrl_acorn.Platform(variant=variant)
        platform.add_extension(sqrl_acorn.litex_acorn_baseboard_mini, prepend=True)

        roles = " / ".join(f"SFP{n}: {r}" for n, r in sfp_roles.items())
        if with_stream:
            roles += " / stream"
        kwargs.setdefault("ident", f"LiteX SoC2SoC over SerDes on Acorn Baseboard Mini ({roles})")
        kwargs.setdefault("ident_version", True)
        # Crossbar interconnect: with SFP0 <-> SFP1 on the same board, the target link executes the
        # remote access on the same bus the initiator access is waiting on. With a shared bus, the
        # initiator holds the bus and remote reads deadlock until the bus timeout.
        kwargs.setdefault("bus_interconnect", "crossbar")

        # SoCCore ----------------------------------------------------------------------------------
        SoCCore.__init__(self, platform, sys_clk_freq, **kwargs)

        # CRG --------------------------------------------------------------------------------------
        self.crg = CRG(platform, sys_clk_freq, refclk_freq)

        # Mailbox (shared memory, accessible locally and from the remote SoC) ----------------------
        if mailbox_size:
            self.mailbox = wishbone.SRAM(mailbox_size)
            self.bus.add_slave("mailbox", self.mailbox.bus,
                SoCRegion(origin=self.mem_map["mailbox"], size=mailbox_size))

        # Bandwidth/latency bench (Wishbone traffic generator, see soc2soc/bench.py) ---------------
        if with_bench:
            self.bench = WishboneBench()
            self.bus.add_master(name="bench", master=self.bench.bus)

        # GTP QPLL (shared by the SFP channels, same GTP Quad) -------------------------------------
        platform.add_platform_command("set_property SEVERITY {{Warning}} [get_drc_checks REQP-49]")
        self.qpll = qpll = GTPQuadPLL(self.crg.cd_refclk.clk, refclk_freq, linerate,
            refclk_from_fabric = True)
        print(qpll)

        # SFP Links --------------------------------------------------------------------------------
        self.links = {}
        for n, role in sfp_roles.items():
            if role == "none":
                continue
            tx_polarity, rx_polarity = sfp_polarities[n]
            link = GTPSoCLink(f"sfp{n}", qpll,
                pads         = platform.request("sfp", n),
                sys_clk_freq = sys_clk_freq,
                role         = role,
                qpll_reset   = (len(self.links) == 0), # QPLL reset driven by first channel only.
                tx_polarity  = tx_polarity,
                rx_polarity  = rx_polarity,
                with_crc     = with_crc,
                burst_depth  = burst_depth,
                with_stream        = with_stream,
                with_stream_tester = with_stream,
            )
            self.add_module(name=f"sfp{n}", module=link)
            link.add_timing_constraints(platform, self.crg.cd_sys.clk)
            self.links[n] = link

            if role == "initiator":
                self.bus.add_slave(f"sfp{n}_remote", link.window.bus, SoCRegion(
                    origin = self.mem_map[f"sfp{n}_remote"],
                    size   = 0x1000_0000,
                    cached = False,
                ))
            if role == "target":
                self.bus.add_master(name=f"sfp{n}_remote", master=link.core.bus)

        # Clocks of different links are asynchronous.
        clks = [clk for l in self.links.values() for clk in [l.serdes.cd_tx.clk, l.serdes.cd_rx.clk]]
        if len(clks):
            platform.add_false_path_constraints(*clks)

        # Leds -------------------------------------------------------------------------------------
        # Led0: Sys heartbeat, Led1: SFP0 link ready, Led2: SFP1 link ready, Led3: QPLL lock.
        if with_led_chaser:
            from litex.soc.cores.led import LedChaser
            self.leds = LedChaser(pads=platform.request_all("user_led"), sys_clk_freq=sys_clk_freq)
        else:
            heartbeat = Signal(log2_int(int(sys_clk_freq), need_pow2=False))
            self.sync += heartbeat.eq(heartbeat + 1)
            self.comb += platform.request("user_led", 0).eq(heartbeat[-1])
            for n in [0, 1]:
                led = platform.request("user_led", 1 + n)
                if n in self.links:
                    self.comb += led.eq(self.links[n].phy.init.ready)
            self.comb += platform.request("user_led", 3).eq(qpll.lock)

# Build --------------------------------------------------------------------------------------------

def main():
    from litex.build.parser import LiteXArgumentParser
    parser = LiteXArgumentParser(platform=sqrl_acorn.Platform,
        description="LiteX SoC2SoC over SerDes on Acorn Baseboard Mini (CLE-215+).")
    parser.add_target_argument("--variant",      default="cle-215+",          help="Acorn variant (cle-215+, cle-215 or cle-101).")
    parser.add_target_argument("--sys-clk-freq", default=100e6, type=float,   help="System clock frequency.")
    parser.add_target_argument("--sfp0",         default="initiator",         choices=["none", "initiator", "target"], help="SFP0 role.")
    parser.add_target_argument("--sfp1",         default="target",            choices=["none", "initiator", "target"], help="SFP1 role.")
    parser.add_target_argument("--linerate",     default=2.5e9,  type=float,  help="SerDes linerate (1.25e9, 2.5e9 or 5e9 with 125MHz RefClk, 3.125e9 with 156.25MHz).")
    parser.add_target_argument("--refclk-freq",  default=125e6,  type=float,  help="GTP QPLL reference clock frequency (from fabric PLL).")
    parser.add_target_argument("--with-crc",     action="store_true",         help="Enable SerWB CRC (must match on both sides).")
    parser.add_target_argument("--burst-depth",  default=64, type=int,   help="SerWB burst depth: consecutive writes coalesced per packet (1-256, must match on both sides).")
    parser.add_target_argument("--with-stream",  action="store_true",         help="Add a stream port with flow control (+ stream tester) on each link, next to register access (must match on both sides).")
    parser.add_target_argument("--no-bench",     action="store_true",         help="Disable the bandwidth/latency bench (Wishbone traffic generator).")
    for n in [0, 1]:
        tx, rx = SFP_POLARITIES[n]
        parser.add_target_argument(f"--sfp{n}-tx-polarity", default=tx, type=int, choices=[0, 1], help=f"SFP{n} TX polarity swap (default: {tx}).")
        parser.add_target_argument(f"--sfp{n}-rx-polarity", default=rx, type=int, choices=[0, 1], help=f"SFP{n} RX polarity swap (default: {rx}).")
    parser.add_target_argument("--flash",        action="store_true",         help="Flash bitstream.")
    parser.add_target_argument("--programmer",   default="openfpgaloader",    choices=["openocd", "openfpgaloader"], help="Programmer.")
    parser.add_target_argument("--usb-port",     default=None,                help="Board to load/flash, by host USB port (e.g. 1-3, see /sys/bus/usb/devices), when several boards are connected (openFPGALoader only).")
    parser.set_defaults(uart_name="crossover+uartbone", bus_interconnect="crossbar")
    args = parser.parse_args()

    if (args.load or args.flash) and args.usb_port is not None:
        # Refuse to reprogram a board locked by another session (see board_lock.py and AGENTS.md).
        try:
            board_lock.check(args.usb_port, owner=os.environ.get("SOC2SOC_LOCK_OWNER"))
        except board_lock.BoardLockError as e:
            raise SystemExit(f"Error: {e}")

    soc = SoC2SoC(
        variant        = args.variant,
        sys_clk_freq   = args.sys_clk_freq,
        sfp_roles      = {0: args.sfp0, 1: args.sfp1},
        sfp_polarities = {
            0: (args.sfp0_tx_polarity, args.sfp0_rx_polarity),
            1: (args.sfp1_tx_polarity, args.sfp1_rx_polarity),
        },
        linerate       = args.linerate,
        refclk_freq    = args.refclk_freq,
        with_crc       = args.with_crc,
        burst_depth    = args.burst_depth,
        with_stream    = args.with_stream,
        with_bench     = not args.no_bench,
        **parser.soc_argdict
    )

    builder = Builder(soc, **parser.builder_argdict)
    builder.build(**parser.toolchain_argdict, run=args.build)

    if args.load:
        prog = create_programmer(soc.platform, args.programmer, args.usb_port)
        prog.load_bitstream(builder.get_bitstream_filename(mode="sram"))

    if args.flash:
        prog = create_programmer(soc.platform, args.programmer, args.usb_port)
        prog.flash(0, builder.get_bitstream_filename(mode="flash"))

# Baseboard FTDI chips (USB product ID, vendor 0x0403) and their openFPGALoader cables: the chip
# depends on the baseboard release.
FTDI_CABLES = {
    0x6010 : "ft2232",
    0x6011 : "ft4232",
    0x6014 : "digilent_hs2", # FT232H.
}

def usb_port_ftdi(usb_port, sysfs="/sys/bus/usb/devices"):
    """Return (busnum, devnum, cable) of the FTDI chip plugged into a host USB port (e.g. 1-3)."""
    path = os.path.join(sysfs, usb_port)
    if not os.path.exists(os.path.join(path, "busnum")):
        raise RuntimeError(f"No USB device on port {usb_port} ({path}).")
    def read(name):
        with open(os.path.join(path, name)) as f:
            return f.read().strip()
    vid = int(read("idVendor"),  16)
    pid = int(read("idProduct"), 16)
    if (vid != 0x0403) or (pid not in FTDI_CABLES):
        raise RuntimeError(f"No supported FTDI chip on port {usb_port} ({vid:04x}:{pid:04x}).")
    return int(read("busnum")), int(read("devnum")), FTDI_CABLES[pid]

def create_programmer(platform, name, usb_port=None):
    if usb_port is None:
        # Platform detection: first FTDI chip found by lsusb.
        return platform.create_programmer(name)
    # The FTDI chip of the board has no serial number: select it by USB bus/device number, which
    # changes on each replug, so resolve it from the (stable) host USB port, and detect the chip
    # (and so the cable) of that board, not of the first board found.
    assert name == "openfpgaloader", "--usb-port requires --programmer=openfpgaloader."
    busnum, devnum, cable = usb_port_ftdi(usb_port)
    fpga_part = platform.device.rsplit("-", 1)[0].replace("-", "") # xc7a200t-fbg484-3 -> xc7a200tfbg484.
    prog = OpenFPGALoader(cable=cable, fpga_part=fpga_part, freq=10e6)
    prog.cmd += ["--busdev-num", f"{busnum}:{devnum}"]
    return prog

if __name__ == "__main__":
    main()
