# SPDX-License-Identifier: BSD-2-Clause
"""Acorn CLE-215+ / LiteICLink GTP wrapper for the generic bonded transport.

The generic SystemVerilog node remains board- and SoC-independent. This module
only binds its two PHY ports to the Acorn's two 7-Series GTP/SFP channels.
"""
import os
from types import SimpleNamespace

from migen import *
from migen.genlib.cdc import MultiReg
from litex.gen import *
from litex.soc.interconnect import stream

from liteiclink.serdes.gtp_7series import GTP, GTPQuadPLL


# Complete RTL dependency list for bonded_two_lane_phy_word_node.
_BONDED_RTL = (
    "bonded_control_manager.sv",
    "bonded_two_lane_node.sv",
    "bonded_two_lane_endpoint.sv",
    "bonded_two_lane_tx.sv",
    "bonded_two_lane_rx.sv",
    "bonded_packet_tx.sv",
    "bonded_credit_manager.sv",
    "bonded_async_fifo.sv",
    "bonded_wire_tx_lane.sv",
    "bonded_wire_rx_lane.sv",
    "bonded_control_frame_tx.sv",
    "bonded_control_frame_rx.sv",
    "bonded_control_queue.sv",
    "bonded_lane_frame_arbiter.sv",
    "bonded_lane_tx_mux.sv",
    "bonded_wire_rx_demux.sv",
    "bonded_wire_rx_framer.sv",
    "bonded_sync_byte_fifo.sv",
    "bonded_two_lane_cdc.sv",
    "bonded_packet_rx.sv",
    "bonded_session_gate.sv",
    "bonded_byte_to_phy_word.sv",
    "bonded_phy_8b10b_word_adapter.sv",
    "bonded_phy_word_to_byte.sv",
    "bonded_lane_phy_word_bridge.sv",
    "bonded_two_lane_phy_word_node.sv",
)


class _StickyRxDecoderError(LiteXModule):
    """Latch a decoder error in the recovered RX clock domain."""

    def __init__(self, invalid):
        self.error = Signal(reset=0)
        self.sync += If(invalid, self.error.eq(1))


class AcornBondedSerdes(LiteXModule):
    """Two-lane bonded transport PHY for the Acorn CLE-215+.

    The caller supplies the fabric-generated GTP reference clock. The module
    exposes a 32-bit packet TX endpoint and an 8-bit packet RX endpoint.
    """

    def __init__(
        self,
        platform,
        refclk,
        refclk_freq=125e6,
        linerate=2.5e9,
        sys_clk_freq=100e6,
        peer_id=1,
        expected_peer_id=2,
        session_id=1,
        profile_id=1,
        max_payload=4096,
        tx_polarities=(0, 0),
        rx_polarities=(1, 1),
        rx_fifo_depth=16,
    ):
        self.sink = stream.Endpoint([
            ("data", 32), ("keep", 4), ("sop", 1), ("eop", 1),
        ])
        self.source = stream.Endpoint([
            ("data", 8), ("sop", 1), ("eop", 1), ("packet_sequence", 32),
        ])

        self.session_active = Signal()
        self.control_fault = Signal()
        self.rx_credit_error = Signal()
        self.tx_packet_error = Signal()
        self.rx_packet_error = Signal()
        self.phy_tx_error = Signal(2)
        self.phy_rx_error = Signal(2)
        self.tx_frame_error = Signal(2)
        self.rx_frame_error = Signal(2)

        rtl_dir = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "rtl"))
        for filename in _BONDED_RTL:
            platform.add_source(os.path.join(rtl_dir, filename))

        self.qpll = qpll = GTPQuadPLL(
            refclk, refclk_freq, linerate, refclk_from_fabric=True
        )

        gtp_channels = []
        tx_clocks, rx_clocks = [], []
        tx_resets_n, rx_resets_n = [], []
        lane_up = []
        tx_phy_valid, tx_phy_data, tx_phy_ctrl, tx_phy_ready = [], [], [], []
        rx_phy_valid, rx_phy_data, rx_phy_ctrl, rx_phy_ready = [], [], [], []

        for lane in range(2):
            pads = platform.request("sfp", lane)
            tx_pads = SimpleNamespace(p=pads.txp, n=pads.txn)
            rx_pads = SimpleNamespace(p=pads.rxp, n=pads.rxn)

            gtp = GTP(
                qpll,
                tx_pads=tx_pads,
                rx_pads=rx_pads,
                sys_clk_freq=sys_clk_freq,
                qpll_reset=(lane == 0),
                data_width=20,             # Two 8b/10b symbols per user clock.
                tx_buffer_enable=True,
                rx_buffer_enable=True,
                clock_aligner=False,       # The GTP comma aligner remains enabled.
                tx_polarity=tx_polarities[lane],
                rx_polarity=rx_polarities[lane],
            )
            tx_cd = f"bond_sfp{lane}_tx"
            rx_cd = f"bond_sfp{lane}_rx"
            gtp = ClockDomainsRenamer({"tx": tx_cd, "rx": rx_cd})(gtp)
            gtp.add_stream_endpoints()
            gtp.add_base_control()
            gtp.add_prbs_control()
            gtp.add_loopback_control()
            gtp.add_electrical_control()
            gtp.add_clock_cycles()
            setattr(self.submodules, f"gtp{lane}", gtp)
            gtp_channels.append(gtp)

            tx_clocks.append(ClockSignal(tx_cd))
            rx_clocks.append(ClockSignal(rx_cd))
            tx_resets_n.append(~ResetSignal(tx_cd))
            rx_resets_n.append(~ResetSignal(rx_cd))

            tx_phy_valid.append(Signal())
            tx_phy_data.append(Signal(16))
            tx_phy_ctrl.append(Signal(2))
            rx_phy_ready.append(Signal())
            tx_phy_ready.append(gtp.sink.ready)
            rx_phy_valid.append(gtp.source.valid)
            rx_phy_data.append(gtp.source.data)
            rx_phy_ctrl.append(gtp.source.ctrl)

            # LiteICLink exposes continuous TX/RX streams: sink.ready=1 and
            # source.valid=1. Latch decoder-invalid in recovered RX clock
            # before crossing it to the system/bond clock for lane supervision.
            invalid = gtp.decoders[0].invalid | gtp.decoders[1].invalid
            error_latch = ClockDomainsRenamer(rx_cd)(_StickyRxDecoderError(invalid))
            setattr(self.submodules, f"gtp{lane}_rx_error_latch", error_latch)
            invalid_sys = Signal()
            self.specials += MultiReg(error_latch.error, invalid_sys, "sys")
            lane_up.append(gtp.tx_ready & gtp.rx_ready & qpll.lock & ~invalid_sys)

        tx_ready = Signal()
        rx_valid = Signal()
        rx_data = Signal(8)
        rx_sop = Signal()
        rx_eop = Signal()
        rx_sequence = Signal(32)

        node_params = dict(
            p_DATA_WIDTH=32,
            p_KEEP_WIDTH=4,
            p_SYMBOLS_PER_WORD=2,
            p_PHY_DATA_BYTES_PER_WORD=1,
            p_PHY_RX_FIFO_DEPTH=rx_fifo_depth,
            p_RX_PHY_STALLABLE=0,
            p_LOCAL_PEER_ID=peer_id,
            p_EXPECTED_PEER_ID=expected_peer_id,
            p_SESSION_ID=session_id,
            p_PROFILE_ID=profile_id,
            p_MAX_PACKET_BYTES=max_payload,
            p_MAX_PAYLOAD=max_payload,
        )
        node_ports = dict(
            i_bond_clk=ClockSignal("sys"),
            i_bond_rst_n=~ResetSignal("sys"),
            i_lane0_up=lane_up[0],
            i_lane1_up=lane_up[1],
            i_lane0_tx_clk=tx_clocks[0],
            i_lane0_tx_rst_n=tx_resets_n[0],
            o_lane0_phy_tx_valid=tx_phy_valid[0],
            i_lane0_phy_tx_ready=tx_phy_ready[0],
            o_lane0_phy_tx_data=tx_phy_data[0],
            o_lane0_phy_tx_ctrl=tx_phy_ctrl[0],
            i_lane0_rx_clk=rx_clocks[0],
            i_lane0_rx_rst_n=rx_resets_n[0],
            i_lane0_phy_rx_valid=rx_phy_valid[0],
            o_lane0_phy_rx_ready=rx_phy_ready[0],
            i_lane0_phy_rx_data=rx_phy_data[0],
            i_lane0_phy_rx_ctrl=rx_phy_ctrl[0],
            i_lane1_tx_clk=tx_clocks[1],
            i_lane1_tx_rst_n=tx_resets_n[1],
            o_lane1_phy_tx_valid=tx_phy_valid[1],
            i_lane1_phy_tx_ready=tx_phy_ready[1],
            o_lane1_phy_tx_data=tx_phy_data[1],
            o_lane1_phy_tx_ctrl=tx_phy_ctrl[1],
            i_lane1_rx_clk=rx_clocks[1],
            i_lane1_rx_rst_n=rx_resets_n[1],
            i_lane1_phy_rx_valid=rx_phy_valid[1],
            o_lane1_phy_rx_ready=rx_phy_ready[1],
            i_lane1_phy_rx_data=rx_phy_data[1],
            i_lane1_phy_rx_ctrl=rx_phy_ctrl[1],
            i_tx_valid=self.sink.valid,
            o_tx_ready=tx_ready,
            i_tx_data=self.sink.data,
            i_tx_keep=self.sink.keep,
            i_tx_sop=self.sink.sop,
            i_tx_eop=self.sink.eop,
            o_rx_valid=rx_valid,
            i_rx_ready=self.source.ready,
            o_rx_data=rx_data,
            o_rx_sop=rx_sop,
            o_rx_eop=rx_eop,
            o_rx_packet_sequence=rx_sequence,
            o_session_active=self.session_active,
            o_control_fault=self.control_fault,
            o_rx_credit_error=self.rx_credit_error,
            o_tx_packet_error=self.tx_packet_error,
            o_rx_packet_error=self.rx_packet_error,
            o_lane0_phy_tx_error=self.phy_tx_error[0],
            o_lane1_phy_tx_error=self.phy_tx_error[1],
            o_lane0_phy_rx_error=self.phy_rx_error[0],
            o_lane1_phy_rx_error=self.phy_rx_error[1],
            o_lane0_tx_frame_error=self.tx_frame_error[0],
            o_lane1_tx_frame_error=self.tx_frame_error[1],
            o_lane0_rx_frame_error=self.rx_frame_error[0],
            o_lane1_rx_frame_error=self.rx_frame_error[1],
        )
        self.specials += Instance("bonded_two_lane_phy_word_node", **node_params, **node_ports)

        self.comb += [
            self.sink.ready.eq(tx_ready),
            self.source.valid.eq(rx_valid),
            self.source.data.eq(rx_data),
            self.source.sop.eq(rx_sop),
            self.source.eop.eq(rx_eop),
            self.source.packet_sequence.eq(rx_sequence),
            gtp_channels[0].sink.data.eq(tx_phy_data[0]),
            gtp_channels[0].sink.ctrl.eq(tx_phy_ctrl[0]),
            gtp_channels[0].sink.valid.eq(tx_phy_valid[0]),
            gtp_channels[1].sink.data.eq(tx_phy_data[1]),
            gtp_channels[1].sink.ctrl.eq(tx_phy_ctrl[1]),
            gtp_channels[1].sink.valid.eq(tx_phy_valid[1]),
            gtp_channels[0].source.ready.eq(rx_phy_ready[0]),
            gtp_channels[1].source.ready.eq(rx_phy_ready[1]),
        ]
