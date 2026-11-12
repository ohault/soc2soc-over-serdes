# SPDX-License-Identifier: BSD-2-Clause
"""Separate Acorn target for the experimental bonded two-lane packet link.

The existing acorn_soc2soc.py SerWB target remains unchanged and continues to
own its GTP channels whenever that target is selected.
"""
import os

from litex.build.parser import LiteXArgumentParser
from litex.soc.integration.builder import Builder
from litex.soc.interconnect.csr import CSRStatus

from litex_boards.platforms import sqrl_acorn

import board_lock
from acorn_soc2soc import SoC2SoC, SFP_POLARITIES, create_programmer
from soc2soc.bonded_acorn import AcornBondedSerdes


class BondedAcornSoC(SoC2SoC):
    def __init__(
        self,
        variant="cle-215+",
        sys_clk_freq=100e6,
        linerate=2.5e9,
        refclk_freq=125e6,
        peer_id=1,
        expected_peer_id=2,
        session_id=1,
        max_payload=4096,
        sfp_polarities=SFP_POLARITIES,
        rx_fifo_depth=16,
        **kwargs,
    ):
        # Reuse the established Acorn CRG and shared QPLL setup, but leave both
        # SFP cages unclaimed by the legacy SerWB/GTPSoCLink modules.
        SoC2SoC.__init__(
            self,
            variant=variant,
            sys_clk_freq=sys_clk_freq,
            sfp_roles={0: "none", 1: "none"},
            sfp_polarities=sfp_polarities,
            linerate=linerate,
            refclk_freq=refclk_freq,
            with_crc=False,
            with_stream=False,
            mailbox_size=0,
            with_bench=False,
            with_led_chaser=False,
            ident="Experimental bonded two-lane packet transport on Acorn CLE-215+",
            **kwargs,
        )

        self.bonded = AcornBondedSerdes(
            platform=self.platform,
            refclk=self.crg.cd_refclk.clk,
            refclk_freq=refclk_freq,
            linerate=linerate,
            sys_clk_freq=sys_clk_freq,
            peer_id=peer_id,
            expected_peer_id=expected_peer_id,
            session_id=session_id,
            max_payload=max_payload,
            tx_polarities=(sfp_polarities[0][0], sfp_polarities[1][0]),
            rx_polarities=(sfp_polarities[0][1], sfp_polarities[1][1]),
            rx_fifo_depth=rx_fifo_depth,
            qpll=self.qpll,
        )

        # This first target is a link/session bring-up image. Application
        # traffic is deliberately idle until a packet generator/checker is
        # connected in a later step.
        self.comb += [
            self.bonded.sink.valid.eq(0),
            self.bonded.sink.data.eq(0),
            self.bonded.sink.keep.eq(0),
            self.bonded.sink.sop.eq(0),
            self.bonded.sink.eop.eq(0),
            self.bonded.source.ready.eq(1),
            self.sfp_leds[0].eq(self.bonded.lane_up[0]),
            self.sfp_leds[1].eq(self.bonded.lane_up[1]),
        ]

        self._bond_status = CSRStatus(4, description="Bonded link status: session active, control fault, lane 0 up, lane 1 up.")
        self.comb += self._bond_status.status.eq(Cat(
            self.bonded.session_active,
            self.bonded.control_fault,
            self.bonded.lane_up[0],
            self.bonded.lane_up[1],
        ))


def main():
    parser = LiteXArgumentParser(
        platform=sqrl_acorn.Platform,
        description="Experimental two-lane bonded packet transport on Acorn CLE-215+.",
    )
    parser.add_target_argument("--variant", default="cle-215+", help="Acorn variant.")
    parser.add_target_argument("--sys-clk-freq", default=100e6, type=float, help="System clock frequency.")
    parser.add_target_argument("--linerate", default=2.5e9, type=float, help="GTP serial line rate.")
    parser.add_target_argument("--refclk-freq", default=125e6, type=float, help="Fabric-generated GTP QPLL reference frequency.")
    parser.add_target_argument("--peer-id", default=1, type=lambda x: int(x, 0), help="Stable local peer ID.")
    parser.add_target_argument("--expected-peer-id", default=2, type=lambda x: int(x, 0), help="Expected remote peer ID.")
    parser.add_target_argument("--session-id", default=1, type=lambda x: int(x, 0), help="Common non-zero cold-boot session seed.")
    parser.add_target_argument("--max-payload", default=4096, type=int, help="Maximum packet payload in bytes.")
    parser.add_target_argument("--rx-fifo-depth", default=16, type=int, help="Per-lane PHY RX word FIFO depth.")
    for lane in (0, 1):
        tx, rx = SFP_POLARITIES[lane]
        parser.add_target_argument(f"--sfp{lane}-tx-polarity", default=tx, type=int, choices=[0, 1])
        parser.add_target_argument(f"--sfp{lane}-rx-polarity", default=rx, type=int, choices=[0, 1])
    parser.add_target_argument("--flash", action="store_true", help="Flash bitstream.")
    parser.add_target_argument("--programmer", default="openfpgaloader", choices=["openocd", "openfpgaloader"])
    parser.add_target_argument("--usb-port", default=None, help="Board host USB port when several boards are connected.")
    parser.set_defaults(uart_name="crossover+uartbone", bus_interconnect="crossbar")
    args = parser.parse_args()

    if (args.load or args.flash) and args.usb_port is not None:
        try:
            board_lock.check(args.usb_port, owner=os.environ.get("SOC2SOC_LOCK_OWNER"))
        except board_lock.BoardLockError as exc:
            raise SystemExit(f"Error: {exc}")

    polarities = {
        0: (args.sfp0_tx_polarity, args.sfp0_rx_polarity),
        1: (args.sfp1_tx_polarity, args.sfp1_rx_polarity),
    }
    soc = BondedAcornSoC(
        variant=args.variant,
        sys_clk_freq=args.sys_clk_freq,
        linerate=args.linerate,
        refclk_freq=args.refclk_freq,
        peer_id=args.peer_id,
        expected_peer_id=args.expected_peer_id,
        session_id=args.session_id,
        max_payload=args.max_payload,
        sfp_polarities=polarities,
        rx_fifo_depth=args.rx_fifo_depth,
        **parser.soc_argdict,
    )

    builder = Builder(soc, **parser.builder_argdict)
    builder.build(**parser.toolchain_argdict, run=args.build)

    if args.load:
        programmer = create_programmer(soc.platform, args.programmer, args.usb_port)
        programmer.load_bitstream(builder.get_bitstream_filename(mode="sram"))

    if args.flash:
        programmer = create_programmer(soc.platform, args.programmer, args.usb_port)
        programmer.flash(0, builder.get_bitstream_filename(mode="flash"))


if __name__ == "__main__":
    main()
