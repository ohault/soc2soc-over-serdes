# SPDX-License-Identifier: BSD-2-Clause

import unittest

from soc2soc.bonding import (
    BondConfig,
    BondPacket,
    BondedReceiver,
    BondedSender,
    NegotiationError,
    PacketRejected,
    SessionDown,
    SessionFault,
)


def bring_up(endpoint, lane_count, session_id=0x1234):
    for lane in range(lane_count):
        endpoint.set_lane_up(lane, True)
    endpoint.establish_session(
        peer_lane_count=lane_count,
        peer_version=endpoint.config.protocol_version,
        session_id=session_id,
    )


class BondedSenderTests(unittest.TestCase):
    def test_round_robin_for_configurable_lane_counts(self):
        for lane_count in (1, 2, 3, 5):
            with self.subTest(lane_count=lane_count):
                sender = BondedSender(BondConfig(lane_count=lane_count))
                bring_up(sender, lane_count)
                sent = [sender.send(bytes([n])) for n in range(2 * lane_count + 1)]
                self.assertEqual(
                    [lane for lane, _ in sent],
                    [n % lane_count for n in range(2 * lane_count + 1)],
                )
                self.assertEqual(
                    [packet.sequence for _, packet in sent],
                    list(range(2 * lane_count + 1)),
                )

    def test_requires_all_lanes_and_compatible_peer(self):
        sender = BondedSender(BondConfig(lane_count=2))
        sender.set_lane_up(0, True)
        with self.assertRaises(SessionDown):
            sender.establish_session(
                peer_lane_count=2, peer_version=1, session_id=7
            )
        sender.set_lane_up(1, True)
        with self.assertRaises(NegotiationError):
            sender.establish_session(
                peer_lane_count=1, peer_version=1, session_id=7
            )
        with self.assertRaises(NegotiationError):
            sender.establish_session(
                peer_lane_count=2, peer_version=2, session_id=7
            )
        sender.establish_session(
            peer_lane_count=2, peer_version=1, session_id=7
        )
        self.assertTrue(sender.session_ready)

    def test_packet_size_is_enforced(self):
        sender = BondedSender(BondConfig(lane_count=1, max_packet_bytes=3))
        bring_up(sender, 1)
        with self.assertRaises(ValueError):
            sender.send(b"four")


class BondedReceiverTests(unittest.TestCase):
    def setUp(self):
        self.config = BondConfig(
            lane_count=2,
            max_packet_bytes=32,
            reorder_window=4,
            gap_timeout_cycles=10,
        )
        self.receiver = BondedReceiver(self.config)
        bring_up(self.receiver, 2)

    def packet(self, sequence, payload=None, session_id=0x1234):
        if payload is None:
            payload = f"p{sequence}".encode()
        return BondPacket(session_id, sequence, payload)

    def test_reorders_packets_arriving_on_different_lanes(self):
        self.assertEqual(self.receiver.receive(1, self.packet(1)), [])
        self.assertEqual(self.receiver.receive(0, self.packet(2)), [])
        self.assertEqual(
            self.receiver.receive(0, self.packet(0)),
            [b"p0", b"p1", b"p2"],
        )
        self.assertEqual(self.receiver.next_sequence, 3)
        self.assertEqual(self.receiver.pending_sequences, ())

    def test_rejects_duplicate_stale_and_wrong_session_packets(self):
        self.assertEqual(self.receiver.receive(0, self.packet(0)), [b"p0"])
        with self.assertRaises(PacketRejected):
            self.receiver.receive(1, self.packet(0))
        with self.assertRaises(PacketRejected):
            self.receiver.receive(1, self.packet(1, session_id=0x9999))

    def test_rejects_packet_outside_reorder_window(self):
        with self.assertRaises(PacketRejected):
            self.receiver.receive(0, self.packet(4))
        self.assertTrue(self.receiver.session_ready)

    def test_gap_timeout_faults_session_instead_of_skipping(self):
        self.receiver.receive(1, self.packet(1))
        self.receiver.tick(9)
        self.assertTrue(self.receiver.session_ready)
        with self.assertRaises(SessionFault):
            self.receiver.tick(1)
        self.assertFalse(self.receiver.session_ready)
        with self.assertRaises(SessionDown):
            self.receiver.receive(0, self.packet(0))

    def test_lane_loss_drops_session_and_clears_pending_packets(self):
        self.receiver.receive(1, self.packet(1))
        self.receiver.set_lane_up(0, False)
        self.assertFalse(self.receiver.session_ready)
        self.assertEqual(self.receiver.pending_sequences, ())
        with self.assertRaises(SessionDown):
            self.receiver.receive(0, self.packet(0))

    def test_reestablishment_starts_a_fresh_sequence_space(self):
        self.receiver.receive(1, self.packet(1))
        self.receiver.set_lane_up(0, False)
        self.receiver.set_lane_up(0, True)
        self.receiver.establish_session(
            peer_lane_count=2, peer_version=1, session_id=0x5678
        )
        self.assertEqual(self.receiver.next_sequence, 0)
        self.assertEqual(
            self.receiver.receive(0, self.packet(0, session_id=0x5678)),
            [b"p0"],
        )

    def test_rejects_oversized_packet(self):
        with self.assertRaises(PacketRejected):
            self.receiver.receive(0, self.packet(0, payload=b"x" * 33))


if ( __name__ == "__main__" ):
    unittest.main()
