# SPDX-License-Identifier: BSD-2-Clause
"""Cycle-stepped ready/valid frame boundary reference model.

Executable protocol model for RTL verification, not synthesizable RTL.
One call to step represents one rising edge of the local lane clock.
"""
from __future__ import annotations
from collections import deque
from dataclasses import dataclass
from typing import Deque
from .lane_words import LaneBeat, frame_to_beats

@dataclass(frozen=True)
class TxSignals:
    valid: bool
    beat: LaneBeat | None

class FrameTx:
    """One-frame-at-a-time serializer with stable ready/valid semantics."""
    def __init__(self, word_bytes: int = 4, max_frame_bytes: int = 8192):
        if not 1 <= word_bytes <= 16:
            raise ValueError("word_bytes must be between 1 and 16")
        if max_frame_bytes < 1:
            raise ValueError("max_frame_bytes must be positive")
        self.word_bytes, self.max_frame_bytes = word_bytes, max_frame_bytes
        self._queue: Deque[tuple[LaneBeat, ...]] = deque()
        self._active = None
        self._index = 0

    @property
    def ready(self) -> bool:
        return len(self._queue) < 2

    def submit(self, frame: bytes) -> bool:
        if not isinstance(frame, bytes):
            raise TypeError("frame must be bytes")
        if not frame or len(frame) > self.max_frame_bytes or not self.ready:
            return False
        self._queue.append(frame_to_beats(frame, self.word_bytes))
        return True

    def signals(self) -> TxSignals:
        if self._active is None and self._queue:
            self._active = self._queue[0]
        if self._active is None:
            return TxSignals(False, None)
        return TxSignals(True, self._active[self._index])

    def step(self, ready: bool) -> None:
        if not isinstance(ready, bool):
            raise TypeError("ready must be bool")
        sig = self.signals()
        if sig.valid and ready:
            self._index += 1
            if self._index == len(self._active):
                self._queue.popleft()
                self._active, self._index = None, 0

class FrameRx:
    """Bounded frame assembler; emits only complete, structurally valid frames."""
    def __init__(self, word_bytes: int = 4, max_frame_bytes: int = 8192,
                 output_depth: int = 2):
        if not 1 <= word_bytes <= 16:
            raise ValueError("word_bytes must be between 1 and 16")
        if max_frame_bytes < 1 or output_depth < 1:
            raise ValueError("buffer limits must be positive")
        self.word_bytes, self.max_frame_bytes = word_bytes, max_frame_bytes
        self.output_depth = output_depth
        self._partial = None
        self._output: Deque[bytes] = deque()
        self.errors = 0

    @property
    def ready(self) -> bool:
        return len(self._output) < self.output_depth

    def step(self, valid: bool, beat: LaneBeat | None) -> None:
        if not isinstance(valid, bool):
            raise TypeError("valid must be bool")
        if not valid:
            return
        if beat is None:
            raise ValueError("valid beat cannot be None")
        if not self.ready:
            return
        if beat.sop:
            if self._partial is not None:
                self.errors += 1
            self._partial = []
        elif self._partial is None:
            self.errors += 1
            return
        self._partial.append(beat)
        if len(self._partial) * self.word_bytes > self.max_frame_bytes + self.word_bytes - 1:
            self._partial = None
            self.errors += 1
            return
        if beat.eop:
            from .lane_words import beats_to_frame
            try:
                frame = beats_to_frame(self._partial, self.word_bytes)
                if len(frame) > self.max_frame_bytes:
                    raise ValueError("frame exceeds configured maximum")
            except (TypeError, ValueError):
                self.errors += 1
            else:
                self._output.append(frame)
            self._partial = None

    def pop(self) -> bytes | None:
        return self._output.popleft() if self._output else None
