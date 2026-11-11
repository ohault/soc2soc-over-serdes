# SPDX-License-Identifier: BSD-2-Clause
"""Byte/word boundary for bonded wire frames.

The first hardware profile uses 32-bit lane words. Byte 0 occupies bits
[7:0], byte 1 bits [15:8], etc. The final beat uses a contiguous low-order
KEEP mask. This module is a pure-Python executable reference, not RTL.
"""
from __future__ import annotations

from dataclasses import dataclass
from typing import Iterable


@dataclass(frozen=True)
class LaneBeat:
    data: int
    keep: int
    sop: bool
    eop: bool


def _validate_width(word_bytes: int) -> None:
    if not isinstance(word_bytes, int) or isinstance(word_bytes, bool):
        raise TypeError("word_bytes must be an integer")
    if not 1 <= word_bytes <= 16:
        raise ValueError("word_bytes must be between 1 and 16")


def _low_mask(count: int) -> int:
    return (1 << count) - 1


def frame_to_beats(frame: bytes, word_bytes: int = 4) -> tuple[LaneBeat, ...]:
    """Pack a non-empty wire frame into little-endian lane words."""
    _validate_width(word_bytes)
    if not isinstance(frame, bytes):
        raise TypeError("frame must be bytes")
    if not frame:
        raise ValueError("empty frames are not supported")
    beats = []
    for offset in range(0, len(frame), word_bytes):
        chunk = frame[offset:offset + word_bytes]
        data = int.from_bytes(chunk, "little")
        beats.append(LaneBeat(
            data=data,
            keep=_low_mask(len(chunk)),
            sop=(offset == 0),
            eop=(offset + len(chunk) == len(frame)),
        ))
    return tuple(beats)


def beats_to_frame(beats: Iterable[LaneBeat], word_bytes: int = 4) -> bytes:
    """Unpack one complete lane frame, validating SOP/EOP and KEEP."""
    _validate_width(word_bytes)
    result = bytearray()
    seen_sop = False
    seen_eop = False
    count = 0
    for beat in beats:
        if not isinstance(beat, LaneBeat):
            raise TypeError("all entries must be LaneBeat instances")
        if seen_eop:
            raise ValueError("data follows EOP")
        if not isinstance(beat.data, int) or isinstance(beat.data, bool):
            raise TypeError("beat data must be an integer")
        if not 0 <= beat.data < (1 << (8 * word_bytes)):
            raise ValueError("beat data exceeds configured word width")
        if not isinstance(beat.keep, int) or isinstance(beat.keep, bool):
            raise TypeError("beat keep must be an integer")
        if not 1 <= beat.keep <= _low_mask(word_bytes):
            raise ValueError("KEEP must select at least one byte")
        # Valid byte lanes must be contiguous from byte lane zero.
        valid_bytes = beat.keep.bit_count()
        if beat.keep != _low_mask(valid_bytes):
            raise ValueError("KEEP must be a contiguous low-order mask")
        if not seen_sop:
            if not beat.sop:
                raise ValueError("first beat must assert SOP")
            seen_sop = True
        elif beat.sop:
            raise ValueError("SOP may only occur on the first beat")
        if beat.eop and valid_bytes > word_bytes:
            raise ValueError("invalid final KEEP")
        if not beat.eop and valid_bytes != word_bytes:
            raise ValueError("non-final beat must have all KEEP bits set")
        result.extend(beat.data.to_bytes(word_bytes, "little")[:valid_bytes])
        count += 1
        seen_eop = bool(beat.eop)
    if count == 0:
        raise ValueError("empty beat sequence")
    if not seen_sop or not seen_eop:
        raise ValueError("frame must contain SOP and EOP")
    return bytes(result)
