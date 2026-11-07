#
# This file is part of soc2soc-over-serdes.
#
# SPDX-License-Identifier: BSD-2-Clause

# SoC-to-SoC link over a 7-Series GTP transceiver: GTP + SerDes link layer + LiteICLink SerWB core.
#
#                 Initiator SoC                                      Target SoC
#   CPU/Host --> [RemoteWindow] --> SERWBCore("slave")              SERWBCore("master") --> SoC Bus
#                                       |                                 ^
#                                  SerDesLinkPHY                     SerDesLinkPHY
#                                       |                                 |
#                                      GTP ======== SFP / DAC cable ===== GTP
#
# - "initiator": local bus accesses to a window of the local memory map are forwarded to the remote
#   SoC (the window is mapped on a 256MB page of the remote address space, page selected by CSR).
# - "target"   : requests received from the remote SoC are executed on the local SoC bus (bus master).

from types import SimpleNamespace

from migen import *

from litex.gen import *

from litex.soc.interconnect     import wishbone
from litex.soc.interconnect.csr import *

from liteiclink.serdes.gtp_7series import GTP
from liteiclink.serwb.core         import SERWBCore

from soc2soc.link import SerDesLinkPHY

# Remote Window ------------------------------------------------------------------------------------

class RemoteWindow(LiteXModule):
    """Maps a local window of ``window_size`` bytes onto a page of the remote 32-bit address space.

    remote_address = (page << log2(window_size)) | (local_address & (window_size - 1))
    """
    def __init__(self, remote_bus, window_size=0x1000_0000, default_page=0xf):
        assert window_size & (window_size - 1) == 0
        offset_bits = log2_int(window_size) - 2 # Word address.
        page_bits   = 30 - offset_bits
        assert default_page < 2**page_bits
        self.bus  = bus = wishbone.Interface(data_width=32, adr_width=30)
        self.page = CSRStorage(page_bits, reset=default_page,
            description=f"Remote page: remote address = (page << {offset_bits + 2}) | window offset.")

        # # #

        self.comb += [
            bus.connect(remote_bus, omit={"adr"}),
            remote_bus.adr.eq(Cat(bus.adr[:offset_bits], self.page.storage)),
        ]

# SerDes Link --------------------------------------------------------------------------------------

class GTPSoCLink(LiteXModule):
    """SoC-to-SoC link over one GTP channel.

    Exposes:
    - ``serdes``: LiteICLink GTP (with PRBS/loopback/polarity/electrical CSR controls).
    - ``phy``   : SerDes link layer (status CSRs).
    - ``core``  : SerWB core, ``core.bus`` is a Wishbone Slave (initiator) or Master (target).
    - ``window``: RemoteWindow (initiator only), ``window.bus`` to add as a local SoC Bus Slave.
    """
    def __init__(self, name, qpll, pads, sys_clk_freq, role,
        qpll_reset    = True,
        tx_polarity   = 0,
        rx_polarity   = 0,
        with_crc      = False,
        burst_depth   = 64,
        default_page  = 0xf,
        window_size   = 0x1000_0000):
        assert role in ["initiator", "target"]
        self.role  = role
        self.cd_tx = cd_tx = f"{name}_tx"
        self.cd_rx = cd_rx = f"{name}_rx"

        # # #

        # GTP.
        # ----
        # 20-bit (2 x 8b/10b) datapath, TX/RX buffers enabled, comma alignment done by the GTP.
        # SFP pads (txp/txn/rxp/rxn) to GTP pads (p/n).
        tx_pads = SimpleNamespace(p=pads.txp, n=pads.txn)
        rx_pads = SimpleNamespace(p=pads.rxp, n=pads.rxn)
        serdes = GTP(qpll,
            tx_pads          = tx_pads,
            rx_pads          = rx_pads,
            sys_clk_freq     = sys_clk_freq,
            qpll_reset       = qpll_reset,
            data_width       = 20,
            tx_buffer_enable = True,
            rx_buffer_enable = True,
            clock_aligner    = False,
        )
        self.serdes = serdes = ClockDomainsRenamer({"tx": cd_tx, "rx": cd_rx})(serdes)
        serdes.add_stream_endpoints()
        serdes.add_base_control()
        serdes.add_prbs_control()
        serdes.add_loopback_control()
        serdes.add_electrical_control()
        serdes.add_clock_cycles()
        self.add_polarity_control(tx_polarity, rx_polarity)

        # Link Layer.
        # -----------
        rx_invalid = Signal(2)
        self.comb += rx_invalid.eq(Cat(*[d.invalid for d in serdes.decoders]))
        trx_ready = Signal()
        self.comb += trx_ready.eq(serdes.tx_ready & serdes.rx_ready)
        self.phy = phy = SerDesLinkPHY(
            trx_sink   = serdes.sink,
            trx_source = serdes.source,
            rx_invalid = rx_invalid,
            trx_ready  = trx_ready,
            cd_tx      = cd_tx,
            cd_rx      = cd_rx,
        )
        phy.add_csr()

        # SerWB Core.
        # -----------
        # SerWB naming: "slave" core = Wishbone Slave on the initiator side, "master" core = Wishbone
        # Master on the target side.
        self.core = core = SERWBCore(phy, sys_clk_freq,
            mode        = {"initiator": "slave", "target": "master"}[role],
            with_crc    = with_crc,
            burst_depth = burst_depth, # SerWB write coalescing / read response size (both sides).
        )

        # Remote Window (Initiator).
        # --------------------------
        if role == "initiator":
            self.window = RemoteWindow(core.bus, window_size=window_size, default_page=default_page)

    def add_polarity_control(self, tx_polarity, rx_polarity):
        # Same CSRs as LiteICLink's GTP.add_polarity_control but with board-specific reset values.
        self.tx_polarity = CSRStorage(fields=[
            CSRField("swap", size=1, reset=tx_polarity, values=[
                ("``0b0``", "Normal operation."),
                ("``0b1``", "TX polarity swap (equivalent to P/N swap)."),
            ])
        ])
        self.rx_polarity = CSRStorage(fields=[
            CSRField("swap", size=1, reset=rx_polarity, values=[
                ("``0b0``", "Normal operation."),
                ("``0b1``", "RX polarity swap (equivalent to P/N swap)."),
            ])
        ])
        self.serdes.gtp_params.update(
            i_TXPOLARITY = self.tx_polarity.fields.swap,
            i_RXPOLARITY = self.rx_polarity.fields.swap,
        )

    def add_timing_constraints(self, platform, *clks):
        serdes = self.serdes
        platform.add_period_constraint(serdes.cd_tx.clk, 1e9/serdes.tx_clk_freq)
        platform.add_period_constraint(serdes.cd_rx.clk, 1e9/serdes.rx_clk_freq)
        platform.add_false_path_constraints(serdes.cd_tx.clk, serdes.cd_rx.clk, *clks)
