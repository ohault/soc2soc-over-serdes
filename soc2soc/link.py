#
# This file is part of soc2soc-over-serdes.
#
# SPDX-License-Identifier: BSD-2-Clause

# SerDes Link Layer: 32-bit stream over a 2-byte (20-bit) 8b/10b transceiver.
#
# Line format (one 2-byte transceiver word per TX/RX clock cycle):
#
#   IDLE : byte0 = K28.5 (comma, K), byte1 = status (D): [7:4] = 0x5 (magic), [0] = local RX OK.
#   DATA : two consecutive D-words, low 16-bit half first, then high 16-bit half.
#
# - IDLEs are sent when there is nothing to send and at least every ``idle_period`` 32-bit words so
#   the receiver keeps its comma/byte alignment and the remote status is refreshed.
# - A 32-bit word is never split by an IDLE: the receiver resets its half-word phase on each IDLE.
# - RX is declared OK after ``rx_qualify`` consecutive valid IDLEs without 8b/10b error and stays OK
#   while IDLEs are received at least every ``rx_timeout`` cycles and no error is seen.
# - The link is ready when both sides report RX OK (each side echoes its RX state in the IDLEs).
#
# Data is only forwarded while the link is ready; nothing is retransmitted at this level (SerWB
# packets can optionally be CRC-protected, see SERWBCore's with_crc).
#
# The interface to the transceiver is generic (16-bit data + 2-bit K flags in the TX/RX clock
# domains + 2-bit 8b/10b invalid flags) so the link layer can be simulated without the GTP.

from migen import *
from migen.genlib.cdc import MultiReg, BusSynchronizer, PulseSynchronizer

from litex.gen import *

from litex.soc.interconnect     import stream
from litex.soc.interconnect.csr import *
from litex.soc.cores.code_8b10b import K

# Constants ----------------------------------------------------------------------------------------

K28_5      = K(28, 5) # 0xbc.
IDLE_MAGIC = 0x5

# Link Init (SerWB PHY compatible status) ----------------------------------------------------------

class _LinkInit(LiteXModule):
    def __init__(self):
        self.ready = Signal()
        self.error = Signal()

# SerDes Link PHY ----------------------------------------------------------------------------------

class SerDesLinkPHY(LiteXModule):
    """32-bit stream link (sys clock domain) over a 2-byte 8b/10b transceiver.

    Can be used directly as a LiteICLink SERWBCore PHY (sink/source with 32-bit data, init.ready).

    Parameters
    ----------
    trx_sink   : stream.Endpoint with data (16) / ctrl (2), transceiver TX (``cd_tx`` domain).
    trx_source : stream.Endpoint with data (16) / ctrl (2), transceiver RX (``cd_rx`` domain).
    rx_invalid : Signal(2), 8b/10b decoding error per byte (``cd_rx`` domain).
    trx_ready  : Signal, transceiver TX & RX initialized (sys domain).
    cdc_common_rst : Reset the CDC FIFOs from both clock domains (required in hardware since the TX/RX
                     domains are reset independently on transceiver re-initialization; can only be
                     disabled for simulation, where the derived clock domains are not supported).
    """
    def __init__(self, trx_sink, trx_source, rx_invalid, trx_ready, cd_tx="tx", cd_rx="rx",
        idle_period = 64,
        rx_qualify  = 16,
        rx_timeout  = 1024,
        fifo_depth  = 16,
        cdc_common_rst = True):
        assert len(trx_sink.data)   == 16
        assert len(trx_source.data) == 16
        self.sink   = sink   = stream.Endpoint([("data", 32)])
        self.source = source = stream.Endpoint([("data", 32)])
        self.init   = init   = _LinkInit()

        # Status.
        self.rx_ok       = rx_ok       = Signal() # Local RX receives valid IDLEs (cd_rx).
        self.remote_ok   = remote_ok   = Signal() # Remote reports it receives our IDLEs (cd_rx).
        self.rx_errors   = rx_errors   = Signal(32) # 8b/10b/framing errors (cd_rx).
        self.rx_overflow = rx_overflow = Signal()   # Sticky, RX CDC overflow (cd_rx).
        self.rx_errors_clear = rx_errors_clear = Signal() # Clear rx_errors (cd_rx).

        # # #

        self.cd_rx = cd_rx
        tx_sync = getattr(self.sync, cd_tx)
        rx_sync = getattr(self.sync, cd_rx)

        # Status CDC.
        # -----------
        rx_link_ok = Signal()
        tx_rx_ok   = Signal()
        tx_link_ok = Signal()
        sys_rx_ok  = Signal()
        sys_link_ok = Signal()
        self.comb += rx_link_ok.eq(rx_ok & remote_ok)
        self.specials += [
            MultiReg(rx_ok,      tx_rx_ok,    cd_tx),
            MultiReg(rx_link_ok, tx_link_ok,  cd_tx),
            MultiReg(rx_ok,      sys_rx_ok,   "sys"),
            MultiReg(rx_link_ok, sys_link_ok, "sys"),
        ]
        self.comb += init.ready.eq(sys_link_ok & trx_ready)
        self.sys_rx_ok = sys_rx_ok

        # TX ---------------------------------------------------------------------------------------

        # CDC (sys -> tx).
        # ----------------
        self.tx_cdc = tx_cdc = stream.ClockDomainCrossing([("data", 32)],
            cd_from         = "sys",
            cd_to           = cd_tx,
            depth           = fifo_depth,
            with_common_rst = cdc_common_rst,
        )
        self.comb += sink.connect(tx_cdc.sink)

        # Framing.
        # --------
        tx_half  = Signal()
        tx_count = Signal(max=idle_period + 1)
        status   = Signal(8)
        self.comb += status.eq(Cat(tx_rx_ok, Constant(0, 3), Constant(IDLE_MAGIC, 4)))
        tx_idle = [
            trx_sink.ctrl.eq(0b01),
            trx_sink.data.eq(Cat(Constant(K28_5, 8), status)),
        ]
        tx_start = Signal()
        self.comb += tx_start.eq(~tx_half & tx_cdc.source.valid & (tx_count != 0))
        self.comb += [
            trx_sink.valid.eq(1),
            If(~tx_link_ok,
                # Link down: flush and send IDLEs.
                tx_cdc.source.ready.eq(1),
                *tx_idle,
            ).Elif(tx_half,
                # High half (word accepted).
                trx_sink.ctrl.eq(0b00),
                trx_sink.data.eq(tx_cdc.source.data[16:]),
                tx_cdc.source.ready.eq(1),
            ).Elif(tx_start,
                # Low half.
                trx_sink.ctrl.eq(0b00),
                trx_sink.data.eq(tx_cdc.source.data[:16]),
            ).Else(
                *tx_idle
            )
        ]
        tx_sync += [
            If(~tx_link_ok,
                tx_half.eq(0),
                tx_count.eq(idle_period),
            ).Elif(tx_half,
                tx_half.eq(0),
            ).Elif(tx_start,
                tx_half.eq(1),
                tx_count.eq(tx_count - 1),
            ).Else(
                tx_count.eq(idle_period),
            )
        ]

        # RX ---------------------------------------------------------------------------------------

        # Byte Alignment.
        # ---------------
        # The transceiver aligns commas on byte 0 (ALIGN_COMMA_WORD=2), re-align here if a comma is
        # seen on byte 1 (robustness, transceiver configurations aligning on any byte).
        prev_data    = Signal(16)
        prev_ctrl    = Signal(2)
        prev_invalid = Signal(2)
        shift        = Signal()
        data         = Signal(16)
        ctrl         = Signal(2)
        invalid      = Signal(2)
        rx_sync += [
            prev_data.eq(trx_source.data),
            prev_ctrl.eq(trx_source.ctrl),
            prev_invalid.eq(rx_invalid),
            If(trx_source.ctrl[0] & (trx_source.data[:8] == K28_5),
                shift.eq(0)
            ).Elif(trx_source.ctrl[1] & (trx_source.data[8:] == K28_5),
                shift.eq(1)
            )
        ]
        self.comb += [
            trx_source.ready.eq(1),
            If(shift,
                data.eq(   Cat(prev_data[8:], trx_source.data[:8])),
                ctrl.eq(   Cat(prev_ctrl[1],  trx_source.ctrl[0])),
                invalid.eq(Cat(prev_invalid[1], rx_invalid[0])),
            ).Else(
                data.eq(trx_source.data),
                ctrl.eq(trx_source.ctrl),
                invalid.eq(rx_invalid),
            )
        ]

        # Deframing.
        # ----------
        is_idle  = Signal()
        is_data  = Signal()
        is_error = Signal()
        self.comb += [
            is_idle.eq((ctrl == 0b01) & (data[:8] == K28_5) & (data[12:16] == IDLE_MAGIC)),
            is_data.eq(ctrl == 0b00),
            is_error.eq((invalid != 0) | ~(is_idle | is_data)),
        ]

        # CDC (rx -> sys).
        # ----------------
        self.rx_cdc = rx_cdc = stream.ClockDomainCrossing([("data", 32)],
            cd_from         = cd_rx,
            cd_to           = "sys",
            depth           = fifo_depth,
            with_common_rst = cdc_common_rst,
        )

        rx_half  = Signal()
        rx_low   = Signal(16)
        rx_good  = Signal(max=rx_qualify + 1)
        rx_timer = Signal(max=rx_timeout + 1)
        rx_sync += [
            rx_cdc.sink.valid.eq(0),
            If(rx_cdc.sink.valid & ~rx_cdc.sink.ready,
                rx_overflow.eq(1)
            ),
            If(rx_timer != 0,
                rx_timer.eq(rx_timer - 1)
            ),
            If(is_error,
                rx_half.eq(0),
                rx_good.eq(0),
                rx_ok.eq(0),
                remote_ok.eq(0),
                If(rx_errors != (2**32 - 1),
                    rx_errors.eq(rx_errors + 1)
                )
            ).Elif(is_idle,
                rx_half.eq(0),
                rx_timer.eq(rx_timeout),
                remote_ok.eq(data[8]),
                If(rx_good == rx_qualify,
                    rx_ok.eq(1)
                ).Else(
                    rx_good.eq(rx_good + 1)
                )
            ).Elif(rx_half,
                rx_half.eq(0),
                rx_cdc.sink.valid.eq(rx_link_ok),
                rx_cdc.sink.data.eq(Cat(rx_low, data)),
            ).Else(
                rx_half.eq(1),
                rx_low.eq(data),
            ),
            # Watchdog: no IDLE received for rx_timeout cycles.
            If(rx_timer == 0,
                rx_good.eq(0),
                rx_ok.eq(0),
                remote_ok.eq(0),
            ),
            If(rx_errors_clear,
                rx_errors.eq(0)
            )
        ]

        # Output (only forward data while link is ready, flush otherwise).
        self.comb += [
            source.valid.eq(rx_cdc.source.valid & init.ready),
            source.data.eq(rx_cdc.source.data),
            rx_cdc.source.ready.eq(source.ready | ~init.ready),
        ]

    def add_csr(self):
        self._status = CSRStatus(fields=[
            CSRField("ready",     size=1, description="Link ready (both sides receive each other)."),
            CSRField("rx_ok",     size=1, description="Local RX receives valid IDLEs from remote."),
            CSRField("remote_ok", size=1, description="Remote reports it receives our IDLEs."),
        ])
        self._rx_errors   = CSRStatus(32, description="RX 8b/10b/framing errors (saturating).")
        self._rx_overflow = CSRStatus(description="RX CDC overflow (sticky, cleared on RX reset).")
        self._link_drops  = CSRStatus(32, description="Number of link losses (ready to not ready).")
        self._reset_counters = CSR() # Write to clear the RX errors and link drops counters.

        # # #

        self.rx_errors_clear_ps = PulseSynchronizer("sys", self.cd_rx)
        self.comb += [
            self.rx_errors_clear_ps.i.eq(self._reset_counters.re),
            self.rx_errors_clear.eq(self.rx_errors_clear_ps.o),
        ]

        sys_remote_ok   = Signal()
        sys_rx_overflow = Signal()
        self.specials += [
            MultiReg(self.remote_ok,   sys_remote_ok),
            MultiReg(self.rx_overflow, sys_rx_overflow),
        ]
        self.rx_errors_sync = BusSynchronizer(32, idomain=self.cd_rx, odomain="sys")
        self.comb += [
            self.rx_errors_sync.i.eq(self.rx_errors),
            self._status.fields.ready.eq(self.init.ready),
            self._status.fields.rx_ok.eq(self.sys_rx_ok),
            self._status.fields.remote_ok.eq(sys_remote_ok),
            self._rx_errors.status.eq(self.rx_errors_sync.o),
            self._rx_overflow.status.eq(sys_rx_overflow),
        ]

        ready_d = Signal()
        self.sync += [
            ready_d.eq(self.init.ready),
            If(ready_d & ~self.init.ready & (self._link_drops.status != (2**32 - 1)),
                self._link_drops.status.eq(self._link_drops.status + 1)
            ),
            If(self._reset_counters.re,
                self._link_drops.status.eq(0)
            )
        ]
