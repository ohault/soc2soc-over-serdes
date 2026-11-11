# SPDX-License-Identifier: BSD-2-Clause

import unittest

from soc2soc.bonding.control import (
    BondedControlPlane, ControlConfig, ControlPlaneError,
    ControlSessionDown,
)
from soc2soc.bonding.wire import ControlOpcode, Frame, FrameType


def make_pair():
    a = BondedControlPlane(ControlConfig(
        peer_id=0xA, session_id=0x1234, lane_count=2, profile_id=7,
        expected_peer_id=0xB, control_queue_depth=4,
    ))
    b = BondedControlPlane(ControlConfig(
        peer_id=0xB, session_id=0x1234, lane_count=2, profile_id=7,
        expected_peer_id=0xA, control_queue_depth=4,
    ))
    for endpoint in (a, b):
        endpoint.set_lane_up(0, True)
        endpoint.set_lane_up(1, True)
        endpoint.start()
    return a, b


def exchange_hello_and_ready(a, b, crossed=False):
    # First exchange HELLO on both physical connections.
    for a_lane in range(2):
        b_lane = 1 - a_lane if crossed else a_lane
        hello_a = a.next_frame(a_lane)
        hello_b = b.next_frame(b_lane)
        a.receive(a_lane, hello_b)
        b.receive(b_lane, hello_a)
    # Each endpoint has queued READY on the ingress physical lane.
    for a_lane in range(2):
        b_lane = 1 - a_lane if crossed else a_lane
        ready_a = a.next_frame(a_lane)
        ready_b = b.next_frame(b_lane)
        a.receive(a_lane, ready_b)
        b.receive(b_lane, ready_a)


def finish_recovery_after_lane0_proposal(a, b, crossed=False):
    # Initiator lane 0's HELLO has already reached the adopter.
    adopter_lane = 1 if crossed else 0
    adopter_hello = b.next_frame(adopter_lane)
    a.receive(0, adopter_hello)
    # Negotiate the remaining physical connection.
    a_lane = 1
    b_lane = 1 - a_lane if crossed else a_lane
    hello_a = a.next_frame(a_lane)
    hello_b = b.next_frame(b_lane)
    a.receive(a_lane, hello_b)
    b.receive(b_lane, hello_a)
    # Complete READY on both mapped physical connections.
    for a_lane in range(2):
        b_lane = 1 - a_lane if crossed else a_lane
        ready_a = a.next_frame(a_lane)
        ready_b = b.next_frame(b_lane)
        a.receive(a_lane, ready_b)
        b.receive(b_lane, ready_a)

class ControlPlaneTests(unittest.TestCase):
    def test_two_lane_hello_ready_negotiation(self):
        a, b = make_pair()
        exchange_hello_and_ready(a, b)
        self.assertTrue(a.session_ready)
        self.assertTrue(b.session_ready)
        self.assertEqual(a.peer_lane_by_local, [0, 1])
        self.assertEqual(b.peer_lane_by_local, [0, 1])

    def test_crossed_physical_connections_are_mapped(self):
        a, b = make_pair()
        exchange_hello_and_ready(a, b, crossed=True)
        self.assertTrue(a.session_ready)
        self.assertTrue(b.session_ready)
        self.assertEqual(a.peer_lane_by_local, [1, 0])
        self.assertEqual(b.peer_lane_by_local, [1, 0])

    def test_ready_requires_all_lanes(self):
        a, b = make_pair()
        # Exchange HELLO only on lane zero; lane one remains incomplete.
        a0, b0 = a.next_frame(0), b.next_frame(0)
        a.receive(0, b0)
        b.receive(0, a0)
        ar, br = a.next_frame(0), b.next_frame(0)
        a.receive(0, br)
        b.receive(0, ar)
        self.assertFalse(a.session_ready)
        self.assertFalse(b.session_ready)

    def test_control_has_priority_over_data(self):
        a, b = make_pair()
        exchange_hello_and_ready(a, b)
        a.enqueue_data(0, 0, b"payload")
        a.enqueue_credit(100, 4, lane=0)
        first = a.next_frame(0)
        second = a.next_frame(0)
        self.assertEqual(first.frame_type, FrameType.CONTROL)
        self.assertEqual(first.body[0], ControlOpcode.CREDIT)
        self.assertEqual(second.frame_type, FrameType.DATA)

    def test_credit_updates_coalesce_to_latest_cumulative_grant(self):
        a, b = make_pair()
        exchange_hello_and_ready(a, b)
        a.enqueue_credit(100, 4, lane=0)
        a.enqueue_credit(120, 5, lane=0)
        self.assertEqual(a.control_queue_depths[0], 1)  # one coalesced CREDIT slot
        frame = a.next_frame(0)
        self.assertEqual(frame.body[0], ControlOpcode.CREDIT)
        self.assertEqual(int.from_bytes(frame.body[1:9], "big"), 120)
        self.assertEqual(int.from_bytes(frame.body[9:13], "big"), 5)

    def test_remote_credit_limits_merge_monotonically(self):
        a, b = make_pair()
        exchange_hello_and_ready(a, b)
        a.receive(0, Frame(
            FrameType.CONTROL, 0, 0x1234, 0,
            bytes([ControlOpcode.CREDIT]) + (20000).to_bytes(8, "big") + (70).to_bytes(4, "big"),
        ))
        a.receive(1, Frame(
            FrameType.CONTROL, 1, 0x1234, 0,
            bytes([ControlOpcode.CREDIT]) + (18000).to_bytes(8, "big") + (72).to_bytes(4, "big"),
        ))
        self.assertEqual(a.remote_credit_bytes, 20000)
        self.assertEqual(a.remote_credit_packets, 72)

    def test_ping_is_answered_with_pong(self):
        a, b = make_pair()
        exchange_hello_and_ready(a, b)
        ping = Frame(FrameType.CONTROL, 0, 0x1234, 2,
                     bytes([ControlOpcode.PING]) + (0x12345678).to_bytes(4, "big"))
        a.receive(0, ping)
        pong = a.next_frame(0)
        self.assertEqual(pong.body[0], ControlOpcode.PONG)
        self.assertEqual(pong.body[1:], ping.body[1:])

    def test_negotiation_timeout_faults_incomplete_session(self):
        a, b = make_pair()
        a.tick(a.config.negotiation_timeout_cycles - 1)
        self.assertIsNone(a.fault_reason)
        a.tick(a.config.negotiation_timeout_cycles)
        self.assertIn("negotiation timeout", a.fault_reason)
        self.assertFalse(a.session_ready)

    def test_ping_pong_clears_pending_probe(self):
        a, b = make_pair()
        exchange_hello_and_ready(a, b)
        a.tick(a.config.ping_interval_cycles)
        ping = a.next_frame(0)
        self.assertEqual(ping.body[0], ControlOpcode.PING)
        b.receive(0, ping)
        pong = b.next_frame(0)
        self.assertEqual(pong.body[0], ControlOpcode.PONG)
        a.receive(0, pong)
        self.assertIsNone(a._pending_ping)
        a.tick(a.config.ping_interval_cycles + 1)
        self.assertIsNone(a.fault_reason)

    def test_missing_pong_faults_session(self):
        a, b = make_pair()
        exchange_hello_and_ready(a, b)
        a.tick(a.config.ping_interval_cycles)
        self.assertIsNotNone(a._pending_ping)
        a.tick(a.config.ping_interval_cycles + a.config.pong_timeout_cycles)
        self.assertIn("timed out", a.fault_reason)
        self.assertFalse(a.session_ready)

    def test_wrong_pong_nonce_does_not_clear_pending_probe(self):
        a, b = make_pair()
        exchange_hello_and_ready(a, b)
        a.tick(a.config.ping_interval_cycles)
        pending = a._pending_ping
        wrong = Frame(FrameType.CONTROL, 0, 0x1234, 2,
                      bytes([ControlOpcode.PONG]) + (pending[0] + 1).to_bytes(4, "big"))
        a.receive(0, wrong)
        self.assertEqual(a._pending_ping, pending)
    def test_restart_uses_fresh_session_and_discards_old_frames(self):
        a, b = make_pair()
        exchange_hello_and_ready(a, b, crossed=True)
        stale = Frame(FrameType.CONTROL, 0, 0x1234, 99,
                      bytes([ControlOpcode.PING]) + (0xCAFE).to_bytes(4, "big"))
        for endpoint in (a, b):
            endpoint.set_lane_up(0, False)
            endpoint.set_lane_up(0, True)
        a.restart(0x5678)
        proposed = a.next_frame(0)
        b.receive(1, proposed)  # crossed cable: A lane 0 reaches B lane 1
        finish_recovery_after_lane0_proposal(a, b, crossed=True)
        self.assertTrue(a.session_ready)
        self.assertTrue(b.session_ready)
        self.assertEqual(a.session_id, 0x5678)
        self.assertEqual(b.session_id, 0x5678)
        a.receive(0, stale)
        self.assertTrue(a.session_ready)
        self.assertEqual(a.control_queue_depths, (0, 0))

    def test_higher_peer_cannot_initiate_restart(self):
        a, b = make_pair()
        exchange_hello_and_ready(a, b)
        b.set_lane_up(0, False)
        b.set_lane_up(0, True)
        with self.assertRaises(ControlPlaneError):
            b.restart(0x5678)

    def test_simultaneous_restart_resolves_to_lower_peer_epoch(self):
        a, b = make_pair()
        exchange_hello_and_ready(a, b)
        for endpoint in (a, b):
            endpoint.set_lane_up(0, False)
            endpoint.set_lane_up(0, True)
        a.restart(0x5678)
        a_proposal = a.next_frame(0)
        b.receive(0, a_proposal)  # adopts the lower peer's authoritative epoch
        self.assertEqual(a.session_id, 0x5678)
        self.assertEqual(b.session_id, 0x5678)
        finish_recovery_after_lane0_proposal(a, b)
        self.assertTrue(a.session_ready)
        self.assertTrue(b.session_ready)

    def test_delayed_older_hello_cannot_roll_back_session_epoch(self):
        a, b = make_pair()
        exchange_hello_and_ready(a, b)
        a.set_lane_up(0, False)
        a.set_lane_up(0, True)
        a.restart(0x5678)
        proposal = a.next_frame(0)
        b.receive(0, proposal)
        self.assertEqual(b.session_id, 0x5678)
        old_fields = (
            (0xA).to_bytes(8, "big") + bytes([2])
            + (7).to_bytes(2, "big") + (4096).to_bytes(2, "big")
            + (16384).to_bytes(8, "big") + (64).to_bytes(4, "big")
        )
        delayed = Frame(FrameType.CONTROL, 0, 0x2345, 77,
                        bytes([ControlOpcode.HELLO]) + old_fields)
        b.receive(0, delayed)
        self.assertEqual(b.session_id, 0x5678)
    def test_active_peer_adopts_lower_peer_recovery_proposal(self):
        a, b = make_pair()
        exchange_hello_and_ready(a, b)
        a.set_lane_up(0, False)
        a.set_lane_up(0, True)
        a.restart(0x5678)
        b_proposal = a.next_frame(0)
        b.receive(0, b_proposal)
        self.assertEqual(b.session_id, 0x5678)
        self.assertFalse(b.session_ready)
        finish_recovery_after_lane0_proposal(a, b)
        self.assertTrue(a.session_ready)
        self.assertTrue(b.session_ready)
    def test_restart_rejects_reuse_of_previous_session_identifier(self):
        a, b = make_pair()
        exchange_hello_and_ready(a, b)
        a.set_lane_up(0, False)
        a.set_lane_up(0, True)
        with self.assertRaises(ControlPlaneError):
            a.restart(0x1234)

    def test_restart_requires_faulted_session_and_all_lanes_up(self):
        a, b = make_pair()
        with self.assertRaises(ControlPlaneError):
            a.restart(0x5678)
        a.set_lane_up(0, False)
        with self.assertRaises(ControlSessionDown):
            a.restart(0x5678)
        a.set_lane_up(0, True)
        a.restart(0x5678)
        self.assertFalse(a.session_ready)
        self.assertEqual(a.session_id, 0x5678)
    def test_wrong_profile_faults_negotiation(self):
        a, b = make_pair()
        bad_fields = (
            (0xB).to_bytes(8, "big") + bytes([2])
            + (99).to_bytes(2, "big") + (4096).to_bytes(2, "big")
            + (16384).to_bytes(8, "big") + (64).to_bytes(4, "big")
        )
        frame = Frame(FrameType.CONTROL, 0, 0x1234, 0,
                      bytes([ControlOpcode.HELLO]) + bad_fields)
        with self.assertRaises(ControlPlaneError):
            a.receive(0, frame)
        self.assertFalse(a.session_ready)
        self.assertIsNotNone(a.fault_reason)

    def test_duplicate_peer_lane_mapping_faults(self):
        a, b = make_pair()
        fields = (
            (0xB).to_bytes(8, "big") + bytes([2])
            + (7).to_bytes(2, "big") + (4096).to_bytes(2, "big")
            + (16384).to_bytes(8, "big") + (64).to_bytes(4, "big")
        )
        a.receive(0, Frame(FrameType.CONTROL, 0, 0x1234, 0,
                           bytes([ControlOpcode.HELLO]) + fields))
        with self.assertRaises(ControlPlaneError):
            a.receive(1, Frame(FrameType.CONTROL, 0, 0x1234, 0,
                               bytes([ControlOpcode.HELLO]) + fields))
        self.assertFalse(a.session_ready)

    def test_lane_loss_invalidates_session_and_queues(self):
        a, b = make_pair()
        exchange_hello_and_ready(a, b)
        a.enqueue_data(0, 0, b"queued")
        a.set_lane_up(1, False)
        self.assertFalse(a.session_ready)
        self.assertEqual(a.data_queue_depths, (0, 0))
        with self.assertRaises(ControlSessionDown):
            a.enqueue_data(0, 1, b"not-ready")


if __name__ == "__main__":
    unittest.main()
