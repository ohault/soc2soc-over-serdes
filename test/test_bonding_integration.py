# SPDX-License-Identifier: BSD-2-Clause

"""Integrated two-endpoint simulation across two independently scheduled lanes."""

import unittest

from soc2soc.bonding.control import BondedControlPlane, ControlConfig
from soc2soc.bonding.model import BondConfig, BondPacket, BondedReceiver, BondedSender
from soc2soc.bonding.wire import (
    ControlOpcode, FrameType, decode_data_body, decode_frame, encode_frame,
)


SESSION = 0x123456789ABCDEF0


def make_control_pair():
    a = BondedControlPlane(ControlConfig(
        peer_id=0xA, session_id=SESSION, lane_count=2, profile_id=3,
        expected_peer_id=0xB, initial_rx_bytes=16, initial_rx_packets=2,
    ))
    b = BondedControlPlane(ControlConfig(
        peer_id=0xB, session_id=SESSION, lane_count=2, profile_id=3,
        expected_peer_id=0xA, initial_rx_bytes=16, initial_rx_packets=2,
    ))
    for endpoint in (a, b):
        endpoint.set_lane_up(0, True)
        endpoint.set_lane_up(1, True)
        endpoint.start()

    # Deliver HELLO over both physical connections. This helper intentionally
    # allows the peer's lane identifiers to be crossed.
    for a_lane in range(2):
        b_lane = 1 - a_lane
        hello_a = a.next_frame(a_lane)
        hello_b = b.next_frame(b_lane)
        a.receive(a_lane, decode_frame(encode_frame(hello_b)))
        b.receive(b_lane, decode_frame(encode_frame(hello_a)))

    for a_lane in range(2):
        b_lane = 1 - a_lane
        ready_a = a.next_frame(a_lane)
        ready_b = b.next_frame(b_lane)
        a.receive(a_lane, decode_frame(encode_frame(ready_b)))
        b.receive(b_lane, decode_frame(encode_frame(ready_a)))
    return a, b


class BondedEndToEndTests(unittest.TestCase):
    def test_two_lane_crossed_link_preserves_order_and_returns_credits(self):
        control_a, control_b = make_control_pair()
        self.assertTrue(control_a.session_ready)
        self.assertTrue(control_b.session_ready)
        self.assertEqual(control_a.peer_lane_by_local, [1, 0])
        self.assertEqual(control_b.peer_lane_by_local, [1, 0])

        cfg = BondConfig(
            lane_count=2,
            max_packet_bytes=8,
            tx_queue_depth=4,
            rx_buffer_bytes=16,
            rx_buffer_packets=2,
        )
        sender = BondedSender(cfg)
        receiver = BondedReceiver(cfg)
        for endpoint in (sender, receiver):
            endpoint.set_lane_up(0, True)
            endpoint.set_lane_up(1, True)
            endpoint.establish_session(
                peer_lane_count=2, peer_version=1, session_id=SESSION,
            )

        # Initial receive grant is conveyed by HELLO in the control plane.
        sender.update_remote_credits(
            control_a.remote_credit_bytes, control_a.remote_credit_packets,
        )

        tx = []
        for payload in (b"packet-zero", b"packet-one"):
            # Use short payloads within the configured maximum.
            payload = payload[:8]
            lane, packet = sender.send(payload)
            adapter_packet = sender.take_tx(lane)
            self.assertEqual(adapter_packet, packet)
            control_a.enqueue_data(lane, adapter_packet.sequence, adapter_packet.payload)
            frame = control_a.next_frame(lane)
            self.assertEqual(frame.frame_type, FrameType.DATA)
            # Exercise the actual byte codec on the data path.
            decoded = decode_frame(encode_frame(frame))
            sequence, decoded_payload = decode_data_body(decoded.body)
            tx.append((lane, BondPacket(decoded.session_id, sequence, decoded_payload)))

        # Deliberately deliver the second packet first, modelling skew between
        # the two independent physical lanes.
        lane1, packet1 = tx[1]
        lane0, packet0 = tx[0]
        self.assertEqual(receiver.receive(1 - lane1, packet1), 0)
        self.assertEqual(receiver.receive(1 - lane0, packet0), 2)
        self.assertEqual(receiver.take_rx(), b"packet-z")
        self.assertEqual(receiver.take_rx(), b"packet-o")

        # The receiver returns cumulative credits only after application
        # consumption. The control frame crosses back through the codec.
        byte_limit, packet_limit = receiver.credit_update()
        control_b.enqueue_credit(byte_limit, packet_limit, lane=0)
        credit_frame = control_b.next_frame(0)
        decoded_credit = decode_frame(encode_frame(credit_frame))
        self.assertEqual(decoded_credit.frame_type, FrameType.CONTROL)
        self.assertEqual(decoded_credit.body[0], ControlOpcode.CREDIT)
        control_a.receive(1, decoded_credit)
        sender.update_remote_credits(
            control_a.remote_credit_bytes, control_a.remote_credit_packets,
        )

        lane, next_packet = sender.send(b"refill")
        self.assertEqual(next_packet.sequence, 2)
        adapter_packet = sender.take_tx(lane)
        self.assertEqual(adapter_packet, next_packet)
        control_a.enqueue_data(lane, adapter_packet.sequence, adapter_packet.payload)
        data_frame = decode_frame(encode_frame(control_a.next_frame(lane)))
        sequence, payload = decode_data_body(data_frame.body)
        self.assertEqual(receiver.receive(1 - lane, BondPacket(SESSION, sequence, payload)), 1)
        self.assertEqual(receiver.take_rx(), b"refill")

    def test_lane_failure_invalidates_control_session_and_data_session(self):
        control_a, control_b = make_control_pair()
        cfg = BondConfig(lane_count=2, max_packet_bytes=8)
        sender = BondedSender(cfg)
        for lane in range(2):
            sender.set_lane_up(lane, True)
        sender.establish_session(peer_lane_count=2, peer_version=1, session_id=SESSION)
        sender.set_lane_up(1, False)
        control_a.set_lane_up(1, False)
        self.assertFalse(sender.session_ready)
        self.assertFalse(control_a.session_ready)


if __name__ == "__main__":
    unittest.main()
