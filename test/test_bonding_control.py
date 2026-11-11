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
