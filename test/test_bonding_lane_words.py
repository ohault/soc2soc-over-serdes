# SPDX-License-Identifier: BSD-2-Clause
import unittest

from soc2soc.bonding.lane_words import (
    LaneBeat, beats_to_frame, frame_to_beats,
)


class LaneWordCodecTest(unittest.TestCase):
    def test_byte_order_and_partial_final_word(self):
        frame = bytes.fromhex("01 23 45 67 89")
        beats = frame_to_beats(frame, word_bytes=4)
        self.assertEqual(beats, (
            LaneBeat(data=0x67452301, keep=0xF, sop=True, eop=False),
            LaneBeat(data=0x00000089, keep=0x1, sop=False, eop=True),
        ))
        self.assertEqual(beats_to_frame(beats, word_bytes=4), frame)

    def test_round_trip_word_boundaries(self):
        for length in (1, 2, 3, 4, 5, 7, 8, 9, 31, 32, 33, 255):
            with self.subTest(length=length):
                frame = bytes((i * 37) & 0xFF for i in range(length))
                self.assertEqual(beats_to_frame(frame_to_beats(frame)), frame)

    def test_multiple_word_widths(self):
        frame = bytes(range(29))
        for width in (1, 2, 4, 8, 16):
            with self.subTest(width=width):
                self.assertEqual(
                    beats_to_frame(frame_to_beats(frame, width), width), frame
                )

    def test_empty_frame_rejected(self):
        with self.assertRaises(ValueError):
            frame_to_beats(b"")

    def test_missing_sop_rejected(self):
        with self.assertRaises(ValueError):
            beats_to_frame([LaneBeat(0x11, 1, False, True)])

    def test_missing_eop_rejected(self):
        with self.assertRaises(ValueError):
            beats_to_frame([LaneBeat(0x11, 1, True, False)])

    def test_sparse_keep_rejected(self):
        with self.assertRaises(ValueError):
            beats_to_frame([LaneBeat(0x11223344, 0b0101, True, True)])

    def test_partial_non_final_word_rejected(self):
        beats = [
            LaneBeat(0x00000011, 0b0001, True, False),
            LaneBeat(0x00000022, 0b0001, False, True),
        ]
        with self.assertRaises(ValueError):
            beats_to_frame(beats)

    def test_second_sop_rejected(self):
        beats = [
            LaneBeat(0x11223344, 0xF, True, False),
            LaneBeat(0x55667788, 0xF, True, True),
        ]
        with self.assertRaises(ValueError):
            beats_to_frame(beats)

    def test_data_after_eop_rejected(self):
        beats = [
            LaneBeat(0x11, 1, True, True),
            LaneBeat(0x22, 1, False, True),
        ]
        with self.assertRaises(ValueError):
            beats_to_frame(beats)

    def test_word_overflow_rejected(self):
        with self.assertRaises(ValueError):
            beats_to_frame([LaneBeat(1 << 32, 0xF, True, True)])

    def test_invalid_word_width_rejected(self):
        for width in (0, 17, True):
            with self.subTest(width=width):
                with self.assertRaises((TypeError, ValueError)):
                    frame_to_beats(b"x", width)


if __name__ == "__main__":
    unittest.main()
