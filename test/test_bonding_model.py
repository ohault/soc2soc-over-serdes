# SPDX-License-Identifier: BSD-2-Clause

import unittest

from soc2soc.bonding import (
    BondConfig,
    BondPacket,
    BondedReceiver,
    BondedSender,
    CreditViolation,
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
    if isinstance(endpoint, BondedSender):
        # Simulate the peer's initial cumulative receive-credit grant.
        endpoint.update_remote_credits(
            endpoint.config.rx_buffer_bytes,
            endpoint.config.rx_buffer_packets,
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

    def test_skips_a_stalled_lane_and_uses_the_other_lane(self):
        sender = BondedSender(
            BondConfig(lane_count=2, tx_queue_depth=1)
        )
        bring_up(sender, 2)

        lane0 = sender.send(b"lane0")
        lane1 = sender.send(b"lane1")
        self.assertEqual(lane0[0], 0)
        self.assertEqual(lane1[0], 1)
        self.assertEqual(sender.queued_packets, (1, 1))

        # Lane 0 remains stalled/full. Draining lane 1 must allow further
        # traffic to progress on lane 1 instead of blocking the aggregate.
        self.assertIsNone(sender.send(b"blocked"))
        self.assertEqual(sender.next_sequence, 2)
        self.assertEqual(sender.take_tx(1), lane1[1])
        lane1_again = sender.send(b"lane1-again")
        self.assertEqual(lane1_again[0], 1)
        self.assertEqual(lane1_again[1].sequence, 2)
        self.assertEqual(sender.queued_packets, (1, 1))

        # Once lane 0 becomes available, round-robin selection can use it.
        self.assertEqual(sender.take_tx(0), lane0[1])
        lane0_again = sender.send(b"lane0-again")
        self.assertEqual(lane0_again[0], 0)
        self.assertEqual(lane0_again[1].sequence, 3)

    def test_aggregate_backpressure_does_not_consume_sequence(self):
        sender = BondedSender(
            BondConfig(lane_count=2, tx_queue_depth=1)
        )
        bring_up(sender, 2)
        sender.send(b"first")
        sender.send(b"second")
        self.assertIsNone(sender.send(b"not-accepted"))
        self.assertEqual(sender.next_sequence, 2)
        self.assertEqual(sender.queued_packets, (1, 1))

    def test_lane_loss_flushes_all_transmit_queues(self):
        sender = BondedSender(
            BondConfig(lane_count=2, tx_queue_depth=2)
        )
        bring_up(sender, 2)
        sender.send(b"first")
        sender.send(b"second")
        sender.set_lane_up(0, False)
        self.assertFalse(sender.session_ready)
        self.assertEqual(sender.queued_packets, (0, 0))

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
        self.assertEqual(self.receiver.receive(1, self.packet(1)), 0)
        self.assertEqual(self.receiver.receive(0, self.packet(2)), 0)
        self.assertEqual(self.receiver.receive(0, self.packet(0)), 3)
        self.assertEqual(self.receiver.next_sequence, 3)
        self.assertEqual(self.receiver.pending_sequences, ())
        self.assertEqual(
            [self.receiver.take_rx(), self.receiver.take_rx(), self.receiver.take_rx()],
            [b"p0", b"p1", b"p2"],
        )

    def test_rejects_duplicate_stale_and_wrong_session_packets(self):
        self.assertEqual(self.receiver.receive(0, self.packet(0)), 1)
        self.assertEqual(self.receiver.take_rx(), b"p0")
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

    def test_later_out_of_order_packet_does_not_extend_gap_timeout(self):
        self.receiver.receive(1, self.packet(1))
        self.receiver.tick(6)
        self.receiver.receive(0, self.packet(2))
        with self.assertRaises(SessionFault):
            self.receiver.tick(4)
        self.assertFalse(self.receiver.session_ready)

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
            self.receiver.receive(0, self.packet(0, session_id=0x5678)), 1
        )
        self.assertEqual(self.receiver.take_rx(), b"p0")

    def test_rejects_oversized_packet(self):
        with self.assertRaises(PacketRejected):
            self.receiver.receive(0, self.packet(0, payload=b"x" * 33))



class EndToEndCreditTests(unittest.TestCase):
    def test_sender_waits_for_initial_peer_credit_grant(self):
        sender = BondedSender(BondConfig(
            lane_count=2, rx_buffer_bytes=64, rx_buffer_packets=2
        ))
        for lane in range(2):
            sender.set_lane_up(lane, True)
        sender.establish_session(
            peer_lane_count=2, peer_version=1, session_id=0x1234
        )
        self.assertIsNone(sender.send(b"not-yet-granted"))
        self.assertEqual(sender.next_sequence, 0)
        sender.update_remote_credits(byte_limit=64, packet_limit=2)
        self.assertEqual(sender.send(b"one")[1].sequence, 0)

    def test_byte_and_packet_credits_both_apply_backpressure(self):
        sender = BondedSender(
            BondConfig(
                lane_count=1, tx_queue_depth=4,
                rx_buffer_bytes=5, rx_buffer_packets=2,
            )
        )
        bring_up(sender, 1)
        sender.update_remote_credits(byte_limit=5, packet_limit=2)
        self.assertEqual(sender.send(b"12345")[1].sequence, 0)
        self.assertIsNone(sender.send(b"x"))
        self.assertEqual(sender.next_sequence, 1)
        sender.update_remote_credits(byte_limit=6, packet_limit=2)
        self.assertEqual(sender.send(b"x")[1].sequence, 1)
        self.assertIsNone(sender.send(b""))
        self.assertEqual(sender.next_sequence, 2)

    def test_cumulative_credit_updates_are_idempotent_and_monotonic(self):
        sender = BondedSender(BondConfig(
            lane_count=1, rx_buffer_bytes=8, rx_buffer_packets=2
        ))
        bring_up(sender, 1)
        sender.update_remote_credits(100, 10)
        sender.update_remote_credits(100, 10)  # Duplicate update.
        sender.update_remote_credits(80, 9)    # Stale update.
        self.assertEqual(sender.remote_credit_bytes, 100)
        self.assertEqual(sender.remote_credit_packets, 10)
        with self.assertRaises(PacketRejected):
            sender.update_remote_credits(99, 10)

    def test_receiver_returns_credits_only_after_application_consumes(self):
        receiver = BondedReceiver(
            BondConfig(
                lane_count=1,
                max_packet_bytes=8,
                rx_buffer_bytes=8,
                rx_buffer_packets=2,
            )
        )
        bring_up(receiver, 1)
        self.assertEqual(receiver.credit_update(), (8, 2))
        self.assertEqual(receiver.receive(0, BondPacket(0x1234, 0, b"12345")), 1)
        self.assertEqual(receiver.credit_update(), (8, 2))
        self.assertEqual(receiver.queued_rx_bytes, 5)
        self.assertEqual(receiver.take_rx(), b"12345")
        self.assertEqual(receiver.credit_update(), (13, 3))
        self.assertEqual(receiver.queued_rx_bytes, 0)

    def test_sender_and_receiver_exchange_credits_end_to_end(self):
        config = BondConfig(
            lane_count=1,
            max_packet_bytes=4,
            rx_buffer_bytes=4,
            rx_buffer_packets=1,
            tx_queue_depth=2,
        )
        sender = BondedSender(config)
        receiver = BondedReceiver(config)
        bring_up(sender, 1)
        bring_up(receiver, 1)

        # Seed sender from the receiver's initial grant.
        sender.update_remote_credits(*receiver.credit_update())
        lane, packet = sender.send(b"full")
        self.assertEqual(receiver.receive(lane, sender.take_tx(lane)), 1)
        self.assertIsNone(sender.send(b"x"))

        # Capacity is not returned merely because the lane adapter accepted
        # or the receiver accepted the packet. It is returned on app consume.
        self.assertEqual(receiver.take_rx(), b"full")
        sender.update_remote_credits(*receiver.credit_update())
        lane, packet = sender.send(b"next")
        self.assertEqual(packet.sequence, 1)
        self.assertEqual(receiver.receive(lane, sender.take_tx(lane)), 1)

    def test_receiver_accounts_for_packets_in_flight_until_credit_is_returned(self):
        receiver = BondedReceiver(
            BondConfig(
                lane_count=1,
                max_packet_bytes=8,
                rx_buffer_bytes=8,
                rx_buffer_packets=2,
            )
        )
        bring_up(receiver, 1)
        self.assertEqual(receiver.receive(0, BondPacket(0x1234, 0, b"1234")), 1)
        self.assertEqual(receiver.receive(0, BondPacket(0x1234, 1, b"5678")), 1)
        with self.assertRaises(CreditViolation):
            receiver.receive(0, BondPacket(0x1234, 2, b"x"))
        self.assertFalse(receiver.session_ready)

if ( __name__ == "__main__" ):
    unittest.main()
