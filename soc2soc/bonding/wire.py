# SPDX-License-Identifier: BSD-2-Clause
"""Pure-Python v0 bonded transport frame codec.

This module implements the byte-level envelope only. It has no Migen, LiteX,
board, transceiver, or operating-system dependencies.
"""
from __future__ import annotations

from dataclasses import dataclass
from enum import IntEnum
import struct


MAGIC = 0x5342
VERSION = 1
HEADER_LENGTH = 24
TRAILER_LENGTH = 4
MAX_DATA_PAYLOAD = 4096
MAX_BODY_LENGTH = 0xFFFF


class WireError(ValueError):
    """Malformed or unsupported wire frame."""


class FrameType(IntEnum):
    DATA = 1
    CONTROL = 2


class ControlOpcode(IntEnum):
    HELLO = 0x01
    READY = 0x02
    CREDIT = 0x03
    PING = 0x04
    PONG = 0x05
    RESET = 0x06
    ERROR = 0x07


@dataclass(frozen=True)
class Frame:
    frame_type: FrameType
    lane_id: int
    session_id: int
    frame_sequence: int
    body: bytes
    flags: int = 0


def crc16_ccitt_false(data: bytes) -> int:
    """CRC-16/CCITT-FALSE: poly=0x1021, init=0xffff, xorout=0."""
    crc = 0xFFFF
    for octet in data:
        crc ^= octet << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) & 0xFFFF if crc & 0x8000 else (crc << 1) & 0xFFFF
    return crc


def crc32c(data: bytes) -> int:
    """CRC-32C/Castagnoli, reflected polynomial 0x82f63b78."""
    crc = 0xFFFFFFFF
    for octet in data:
        crc ^= octet
        for _ in range(8):
            crc = (crc >> 1) ^ 0x82F63B78 if crc & 1 else crc >> 1
    return crc ^ 0xFFFFFFFF


def _uint(value: int, bits: int, field: str) -> None:
    if not isinstance(value, int) or isinstance(value, bool):
        raise TypeError(f"{field} must be an integer")
    if not 0 <= value < (1 << bits):
        raise ValueError(f"{field} must fit in {bits} bits")


def encode_frame(frame: Frame) -> bytes:
    """Encode one complete frame according to bonded-wire-protocol-v0.md."""
    if not isinstance(frame.body, bytes):
        raise TypeError("frame body must be bytes")
    try:
        frame_type = FrameType(frame.frame_type)
    except ValueError as exc:
        raise WireError("unsupported frame type") from exc
    _uint(frame.lane_id, 8, "lane_id")
    _uint(frame.session_id, 64, "session_id")
    _uint(frame.frame_sequence, 32, "frame_sequence")
    _uint(frame.flags, 8, "flags")
    if frame.session_id == 0:
        raise ValueError("session_id must be non-zero")
    if frame.flags != 0:
        raise ValueError("v0 requires flags to be zero")
    if len(frame.body) > MAX_BODY_LENGTH:
        raise ValueError("frame body exceeds 16-bit length")

    header = struct.pack(
        ">HBBBBHQIH",
        MAGIC, VERSION, int(frame_type), frame.flags, frame.lane_id,
        HEADER_LENGTH, frame.session_id, frame.frame_sequence, len(frame.body)
    )
    # The format above is 22 bytes; append CRC16 to make the fixed 24-byte header.
    header += struct.pack(">H", crc16_ccitt_false(header))
    protected = header + frame.body
    return protected + struct.pack(">I", crc32c(protected))


def decode_frame(data: bytes) -> Frame:
    """Validate and decode exactly one complete frame."""
    if not isinstance(data, bytes):
        raise TypeError("encoded frame must be bytes")
    if len(data) < HEADER_LENGTH + TRAILER_LENGTH:
        raise WireError("truncated frame")
    fields = struct.unpack(">HBBBBHQIHH", data[:HEADER_LENGTH])
    (magic, version, raw_type, flags, lane_id, header_length,
     session_id, frame_sequence, body_length, header_crc) = fields
    if magic != MAGIC:
        raise WireError("bad frame magic")
    if version != VERSION:
        raise WireError("unsupported protocol version")
    try:
        frame_type = FrameType(raw_type)
    except ValueError as exc:
        raise WireError("unknown frame type") from exc
    if flags != 0:
        raise WireError("reserved v0 flags are non-zero")
    if header_length != HEADER_LENGTH:
        raise WireError("invalid header length")
    if session_id == 0:
        raise WireError("zero session identifier")
    if crc16_ccitt_false(data[:22]) != header_crc:
        raise WireError("header CRC-16 mismatch")
    expected_length = HEADER_LENGTH + body_length + TRAILER_LENGTH
    if len(data) != expected_length:
        raise WireError("frame length does not match body_length")
    protected = data[:-TRAILER_LENGTH]
    received_crc, = struct.unpack(">I", data[-TRAILER_LENGTH:])
    if crc32c(protected) != received_crc:
        raise WireError("frame CRC-32C mismatch")
    body = data[HEADER_LENGTH:-TRAILER_LENGTH]
    if frame_type == FrameType.DATA:
        if len(body) < 4:
            raise WireError("DATA body lacks packet_sequence")
        if len(body) - 4 > MAX_DATA_PAYLOAD:
            raise WireError("DATA payload exceeds v0 maximum")
    else:
        validate_control_body(body)
    return Frame(frame_type, lane_id, session_id, frame_sequence, body, flags)


def encode_data_body(packet_sequence: int, payload: bytes) -> bytes:
    _uint(packet_sequence, 32, "packet_sequence")
    if not isinstance(payload, bytes):
        raise TypeError("payload must be bytes")
    if len(payload) > MAX_DATA_PAYLOAD:
        raise ValueError("DATA payload exceeds v0 maximum")
    return struct.pack(">I", packet_sequence) + payload


def decode_data_body(body: bytes) -> tuple[int, bytes]:
    if not isinstance(body, bytes) or len(body) < 4:
        raise WireError("invalid DATA body")
    if len(body) - 4 > MAX_DATA_PAYLOAD:
        raise WireError("DATA payload exceeds v0 maximum")
    sequence, = struct.unpack(">I", body[:4])
    return sequence, body[4:]


_CONTROL_LENGTHS = {
    ControlOpcode.HELLO: 25,  # peer_id, lanes, profile, max_payload, byte/packet grants
    ControlOpcode.READY: 11,  # peer_id, lanes, profile
    ControlOpcode.CREDIT: 12, # cumulative byte and packet limits
    ControlOpcode.PING: 4,
    ControlOpcode.PONG: 4,
    ControlOpcode.RESET: 2,
    ControlOpcode.ERROR: 4,
}


def validate_control_body(body: bytes) -> ControlOpcode:
    if not isinstance(body, bytes) or not body:
        raise WireError("empty CONTROL body")
    try:
        opcode = ControlOpcode(body[0])
    except ValueError as exc:
        raise WireError("unknown CONTROL opcode") from exc
    if len(body) != 1 + _CONTROL_LENGTHS[opcode]:
        raise WireError(f"invalid body length for {opcode.name}")
    return opcode


def encode_control_body(opcode: ControlOpcode, fields: bytes) -> bytes:
    try:
        opcode = ControlOpcode(opcode)
    except ValueError as exc:
        raise WireError("unknown CONTROL opcode") from exc
    if not isinstance(fields, bytes):
        raise TypeError("control fields must be bytes")
    body = bytes([int(opcode)]) + fields
    validate_control_body(body)
    return body


def decode_control_body(body: bytes) -> tuple[ControlOpcode, bytes]:
    opcode = validate_control_body(body)
    return opcode, body[1:]
