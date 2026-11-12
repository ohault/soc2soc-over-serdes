# SPDX-License-Identifier: BSD-2-Clause
"""Bidirectional packet-pattern generator/checker for bonded-link bring-up."""

from migen import *
from litex.gen import *
from litex.soc.interconnect import stream


class BondedPatternTester(LiteXModule):
    """Send and verify fixed-size packets in both directions.

    Payload byte pattern:
        peer_id + packet_count * 13 + byte_offset  (modulo 256)

    Both peers use complementary local/remote peer IDs. Counters restart while
    the bonded session is down, so a newly negotiated session starts cleanly.
    """

    PACKET_BYTES = 64
    PACKET_BEATS = PACKET_BYTES // 4

    def __init__(self, session_active, local_peer_id, remote_peer_id):
        self.tx = stream.Endpoint([
            ("data", 32), ("keep", 4), ("sop", 1), ("eop", 1),
        ])
        self.rx = stream.Endpoint([
            ("data", 8), ("sop", 1), ("eop", 1), ("packet_sequence", 32),
        ])

        self.error = Signal(reset=0)
        self.tx_packets = Signal(32)
        self.rx_packets = Signal(32)

        startup_delay = Signal(max=1024)
        tx_word_index = Signal(max=self.PACKET_BEATS)
        tx_packet_count = Signal(32)
        rx_byte_index = Signal(max=self.PACKET_BYTES)
        rx_packet_count = Signal(32)

        tx_base = tx_packet_count * 13 + tx_word_index * 4 + local_peer_id
        tx_bytes = [((tx_base + i)[:8]) for i in range(4)]
        rx_index = Mux(self.rx.sop, 0, rx_byte_index)
        rx_expected = (rx_packet_count * 13 + remote_peer_id + rx_index)[:8]

        tx_enabled = session_active & (startup_delay == 1023)
        self.comb += [
            self.tx.valid.eq(tx_enabled),
            self.tx.data.eq(Cat(*tx_bytes)),
            self.tx.keep.eq(0xf),
            self.tx.sop.eq(tx_word_index == 0),
            self.tx.eop.eq(tx_word_index == (self.PACKET_BEATS - 1)),
            self.rx.ready.eq(1),
        ]

        self.sync += [
            If(~session_active,
                startup_delay.eq(0),
                tx_word_index.eq(0),
                tx_packet_count.eq(0),
                self.tx_packets.eq(0),
                rx_byte_index.eq(0),
                rx_packet_count.eq(0),
                self.rx_packets.eq(0),
            ).Else(
                If(startup_delay < 1023,
                    startup_delay.eq(startup_delay + 1)
                ),
                If(self.tx.valid & self.tx.ready,
                    If(tx_word_index == (self.PACKET_BEATS - 1),
                        tx_word_index.eq(0),
                        tx_packet_count.eq(tx_packet_count + 1),
                        self.tx_packets.eq(self.tx_packets + 1),
                    ).Else(
                        tx_word_index.eq(tx_word_index + 1)
                    )
                ),
                If(self.rx.valid & self.rx.ready,
                    If(self.rx.sop != (rx_byte_index == 0),
                        self.error.eq(1)
                    ),
                    If(self.rx.data != rx_expected,
                        self.error.eq(1)
                    ),
                    If(self.rx.eop != (rx_index == (self.PACKET_BYTES - 1)),
                        self.error.eq(1)
                    ),
                    If(self.rx.eop,
                        rx_byte_index.eq(0),
                        rx_packet_count.eq(rx_packet_count + 1),
                        self.rx_packets.eq(self.rx_packets + 1),
                    ).Else(
                        rx_byte_index.eq(rx_index + 1)
                    )
                )
            )
        ]
