# SPDX-License-Identifier: BSD-2-Clause
import random
import unittest
from soc2soc.bonding.lane_words import LaneBeat, frame_to_beats
from soc2soc.bonding.stream_boundary import FrameRx, FrameTx

class StreamBoundaryTest(unittest.TestCase):
    def test_tx_holds_beat_stable_during_stall(self):
        tx = FrameTx()
        self.assertTrue(tx.submit(b"abcdefgh"))
        first = tx.signals()
        for _ in range(5):
            tx.step(False)
            self.assertEqual(tx.signals(), first)
        tx.step(True)
        self.assertNotEqual(tx.signals(), first)

    def test_tx_queue_is_bounded(self):
        tx = FrameTx()
        self.assertTrue(tx.submit(b"one"))
        self.assertTrue(tx.submit(b"two"))
        self.assertFalse(tx.submit(b"three"))

    def test_rx_reassembles_complete_frames(self):
        rx = FrameRx()
        for frame in (b"a", b"12345", bytes(range(33))):
            for beat in frame_to_beats(frame):
                rx.step(True, beat)
            self.assertEqual(rx.pop(), frame)
        self.assertEqual(rx.errors, 0)

    def test_rx_rejects_malformed_beats(self):
        rx = FrameRx()
        rx.step(True, LaneBeat(0x11, 1, False, True))
        rx.step(True, LaneBeat(0x11223344, 0b0101, True, True))
        self.assertEqual(rx.errors, 2)

    def test_rx_output_backpressure(self):
        rx = FrameRx(output_depth=1)
        beat = frame_to_beats(b"one")[0]
        rx.step(True, beat)
        self.assertFalse(rx.ready)
        rx.step(True, beat)
        self.assertEqual(rx.pop(), b"one")
        self.assertEqual(rx.pop(), None)

    def test_randomized_ready_valid_round_trip(self):
        rng = random.Random(0xB04DED)
        frames = [bytes(rng.randrange(256) for _ in range(n))
                  for n in (1, 2, 3, 4, 5, 17, 63, 127, 257)]
        tx, rx = FrameTx(), FrameRx(output_depth=2)
        pending, delivered, cycles = list(frames), [], 0
        while pending or tx._queue or tx._active:
            cycles += 1
            self.assertLess(cycles, 10000)
            if pending and tx.ready:
                tx.submit(pending.pop(0))
            sig = tx.signals()
            transfer = sig.valid and rx.ready and rng.random() < 0.65
            if transfer:
                rx.step(True, sig.beat)
            tx.step(bool(transfer))
            if rng.random() < 0.8:
                item = rx.pop()
                if item is not None:
                    delivered.append(item)
        while (item := rx.pop()) is not None:
            delivered.append(item)
        self.assertEqual(delivered, frames)
        self.assertEqual(rx.errors, 0)

    def test_rx_rejects_oversize_frame(self):
        rx = FrameRx(max_frame_bytes=4)
        for beat in frame_to_beats(b"12345678"):
            rx.step(True, beat)
        self.assertEqual(rx.errors, 1)
        self.assertIsNone(rx.pop())

if __name__ == "__main__":
    unittest.main()
