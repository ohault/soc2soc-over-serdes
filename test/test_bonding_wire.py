# SPDX-License-Identifier: BSD-2-Clause

import unittest

from soc2soc.bonding.wire import (
    ControlOpcode, Frame, FrameType, WireError,
    crc16_ccitt_false, crc32c, decode_control_body, decode_data_body,
    decode_frame, encode_control_body, encode_data_body, encode_frame,
)


class WireCodecTests(unittest.TestCase):
    def test_standard_crc_check_vectors(self):
        self.assertEqual(crc16_ccitt_false(b"123456789"), 0x29B1)
        self.assertEqual(crc32c(b"123456789"), 0xE3069283)

    def test_data_frame_round_trip(self):
        body = encode_data_body(0x10203040, b"hello")
        encoded = encode_frame(Frame(
            FrameType.DATA, lane_id=1, session_id=0x0102030405060708,
            frame_sequence=9, body=body,
        ))
        decoded = decode_frame(encoded)
        self.assertEqual(decoded.frame_type, FrameType.DATA)
        self.assertEqual(decoded.lane_id, 1)
        self.assertEqual(decoded.session_id, 0x0102030405060708)
        self.assertEqual(decoded.frame_sequence, 9)
        self.assertEqual(decode_data_body(decoded.body), (0x10203040, b"hello"))

    def test_control_frame_round_trip(self):
        fields = bytes(range(25))
        body = encode_control_body(ControlOpcode.HELLO, fields)
        encoded = encode_frame(Frame(
            FrameType.CONTROL, lane_id=0, session_id=7,
            frame_sequence=0, body=body,
        ))
        decoded = decode_frame(encoded)
        self.assertEqual(decode_control_body(decoded.body), (ControlOpcode.HELLO, fields))

    def test_all_control_opcodes_validate_exact_lengths(self):
        lengths = {
            ControlOpcode.HELLO: 25, ControlOpcode.READY: 11,
            ControlOpcode.CREDIT: 12, ControlOpcode.PING: 4,
            ControlOpcode.PONG: 4, ControlOpcode.RESET: 2,
            ControlOpcode.ERROR: 4,
        }
        for opcode, length in lengths.items():
            with self.subTest(opcode=opcode):
                body = encode_control_body(opcode, bytes(length))
                self.assertEqual(decode_control_body(body)[0], opcode)
                with self.assertRaises(WireError):
                    decode_control_body(body[:-1])

    def test_reject_truncated_and_trailing_data(self):
        frame = encode_frame(Frame(FrameType.DATA, 0, 1, 0, encode_data_body(0, b"x")))
        with self.assertRaises(WireError):
            decode_frame(frame[:-1])
        with self.assertRaises(WireError):
            decode_frame(frame + b"\x00")

    def test_reject_header_and_payload_corruption(self):
        frame = bytearray(encode_frame(Frame(FrameType.DATA, 0, 1, 0, encode_data_body(0, b"x"))))
        frame[5] ^= 1
        with self.assertRaises(WireError):
            decode_frame(bytes(frame))
        frame = bytearray(encode_frame(Frame(FrameType.DATA, 0, 1, 0, encode_data_body(0, b"x"))))
        frame[28] ^= 1
        with self.assertRaises(WireError):
            decode_frame(bytes(frame))

    def test_reject_unknown_control_opcode_and_bad_length(self):
        with self.assertRaises(WireError):
            decode_control_body(b"\xff" + bytes(4))
        with self.assertRaises(WireError):
            decode_control_body(bytes([ControlOpcode.PING]) + bytes(3))

    def test_reject_zero_session_and_reserved_flags(self):
        with self.assertRaises(ValueError):
            encode_frame(Frame(FrameType.DATA, 0, 0, 0, encode_data_body(0, b"x")))
        with self.assertRaises(ValueError):
            encode_frame(Frame(FrameType.DATA, 0, 1, 0, encode_data_body(0, b"x"), flags=1))


if __name__ == "__main__":
    unittest.main()
