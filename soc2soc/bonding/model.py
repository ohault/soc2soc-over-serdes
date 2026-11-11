# SPDX-License-Identifier: BSD-2-Clause
"""Framework-neutral behavioural model for the bonded SerDes transport.

This is a protocol reference model, not synthesizable RTL and not a wire codec.
It intentionally uses only the Python standard library.
"""

from dataclasses import dataclass
from typing import Optional


PROTOCOL_VERSION = 1


class BondingError(Exception):
    """Base class for bonded-transport model errors."""


class NegotiationError(BondingError):
    """Peer configuration is incompatible with the local configuration."""


class SessionDown(BondingError):
    """An operation requires an established, healthy bonded session."""


class SessionFault(BondingError):
    """The current session can no longer preserve ordered delivery."""


class PacketRejected(BondingError):
    """A packet is malformed, stale, duplicated, or outside the receive window."""


@dataclass(frozen=True)
class BondConfig:
    lane_count: int
    max_packet_bytes: int = 4096
    reorder_window: int = 32
    gap_timeout_cycles: int = 1024
    protocol_version: int = PROTOCOL_VERSION

    def __post_init__(self):
        if self.lane_count < 1:
            raise ValueError("lane_count must be at least 1")
        if self.max_packet_bytes < 1:
            raise ValueError("max_packet_bytes must be at least 1")
        if self.reorder_window < 1:
            raise ValueError("reorder_window must be at least 1")
        if self.gap_timeout_cycles < 1:
            raise ValueError("gap_timeout_cycles must be at least 1")
        if self.protocol_version < 1:
            raise ValueError("protocol_version must be at least 1")


@dataclass(frozen=True)
class BondPacket:
    """A decoded logical packet as seen by the reference model.

    The lane transport header and its binary encoding are deliberately not
    represented here. session_id and sequence model their semantics.
    """

    session_id: int
    sequence: int
    payload: bytes

    def __post_init__(self):
        if not isinstance(self.payload, bytes):
            raise TypeError("payload must be bytes")
        if self.session_id < 0:
            raise ValueError("session_id must be non-negative")
        if self.sequence < 0:
            raise ValueError("sequence must be non-negative")


class _Session:
    def __init__(self, config: BondConfig):
        self.config = config
        self.lanes_up = [False] * config.lane_count
        self.session_id: Optional[int] = None
        self._negotiated = False
        self.fault_reason: Optional[str] = None

    @property
    def session_ready(self) -> bool:
        return (
            self._negotiated
            and self.session_id is not None
            and all(self.lanes_up)
            and self.fault_reason is None
        )

    def set_lane_up(self, lane: int, up: bool) -> None:
        self._check_lane(lane)
        was_up = self.lanes_up[lane]
        self.lanes_up[lane] = bool(up)
        if was_up and not up:
            self._drop_session(f"lane {lane} went down")

    def _check_lane(self, lane: int) -> None:
        if not isinstance(lane, int) or not 0 <= lane < self.config.lane_count:
            raise ValueError(f"lane index {lane!r} outside configured lane range")

    def establish_session(
        self,
        *,
        peer_lane_count: int,
        peer_version: int,
        session_id: int,
    ) -> None:
        if peer_lane_count != self.config.lane_count:
            raise NegotiationError(
                f"lane-count mismatch: local={self.config.lane_count}, "
                f"peer={peer_lane_count}"
            )
        if peer_version != self.config.protocol_version:
            raise NegotiationError(
                f"protocol-version mismatch: local={self.config.protocol_version}, "
                f"peer={peer_version}"
            )
        if not all(self.lanes_up):
            raise SessionDown("cannot establish session until every configured lane is up")
        if session_id < 0:
            raise ValueError("session_id must be non-negative")
        self.session_id = session_id
        self._negotiated = True
        self.fault_reason = None
        self._on_session_established()

    def _drop_session(self, reason: str) -> None:
        self._negotiated = False
        self.fault_reason = reason
        self._on_session_dropped()

    def _on_session_established(self) -> None:
        pass

    def _on_session_dropped(self) -> None:
        pass

    def _require_ready(self) -> None:
        if not self.session_ready:
            detail = f": {self.fault_reason}" if self.fault_reason else ""
            raise SessionDown("bonded session is not ready" + detail)


class BondedSender(_Session):
    """Round-robin packet scheduler for a single bonded session."""

    def __init__(self, config: BondConfig):
        super().__init__(config)
        self.next_sequence = 0
        self._next_lane = 0

    def send(self, payload: bytes) -> tuple[int, BondPacket]:
        self._require_ready()
        if not isinstance(payload, bytes):
            raise TypeError("payload must be bytes")
        if len(payload) > self.config.max_packet_bytes:
            raise ValueError(
                f"packet length {len(payload)} exceeds "
                f"maximum {self.config.max_packet_bytes}"
            )

        lane = self._next_lane
        self._next_lane = (self._next_lane + 1) % self.config.lane_count
        packet = BondPacket(
            session_id=self.session_id,
            sequence=self.next_sequence,
            payload=payload,
        )
        self.next_sequence += 1
        return lane, packet

    def _on_session_established(self) -> None:
        self.next_sequence = 0
        self._next_lane = 0


class BondedReceiver(_Session):
    """Ordered packet receiver with bounded reordering and fail-stop gap timeout.

    lane is the logical lane index after physical-lane discovery/mapping.
    Mapping physical connector numbers to logical lane indices belongs to the
    lane-discovery/adapter layer and is not modelled here.
    """

    def __init__(self, config: BondConfig):
        super().__init__(config)
        self.next_sequence = 0
        self._pending: dict[int, BondPacket] = {}
        self._gap_age = 0

    @property
    def pending_sequences(self) -> tuple[int, ...]:
        return tuple(sorted(self._pending))

    def receive(self, lane: int, packet: BondPacket) -> list[bytes]:
        self._require_ready()
        self._check_lane(lane)
        if not self.lanes_up[lane]:
            raise PacketRejected(f"packet received on down lane {lane}")
        if packet.session_id != self.session_id:
            raise PacketRejected("packet belongs to a different or stale session")
        if len(packet.payload) > self.config.max_packet_bytes:
            raise PacketRejected("packet exceeds configured maximum length")
        if packet.sequence < self.next_sequence:
            raise PacketRejected(f"duplicate or stale sequence {packet.sequence}")
        if packet.sequence >= self.next_sequence + self.config.reorder_window:
            raise PacketRejected(
                f"sequence {packet.sequence} is outside reorder window "
                f"[{self.next_sequence}, "
                f"{self.next_sequence + self.config.reorder_window - 1}]"
            )
        if packet.sequence in self._pending:
            raise PacketRejected(f"duplicate pending sequence {packet.sequence}")

        if packet.sequence == self.next_sequence:
            delivered = [packet.payload]
            self.next_sequence += 1
            while self.next_sequence in self._pending:
                queued = self._pending.pop(self.next_sequence)
                delivered.append(queued.payload)
                self.next_sequence += 1
            self._gap_age = 0
            return delivered

        # Start the timer when the gap is first observed. Later out-of-order
        # arrivals must not keep extending the deadline indefinitely.
        if not self._pending:
            self._gap_age = 0
        self._pending[packet.sequence] = packet
        return []

    def tick(self, cycles: int = 1) -> None:
        """Advance receive time while the next sequence is missing."""
        self._require_ready()
        if not isinstance(cycles, int) or cycles < 0:
            raise ValueError("cycles must be a non-negative integer")
        if not self._pending or cycles == 0:
            return
        self._gap_age += cycles
        if self._gap_age >= self.config.gap_timeout_cycles:
            missing = self.next_sequence
            self._fail(
                f"sequence gap timed out: expected {missing}, "
                f"pending={self.pending_sequences}"
            )

    def _fail(self, reason: str) -> None:
        self._pending.clear()
        self._drop_session(reason)
        raise SessionFault(reason)

    def _on_session_established(self) -> None:
        self.next_sequence = 0
        self._pending.clear()
        self._gap_age = 0

    def _on_session_dropped(self) -> None:
        self._pending.clear()
        self._gap_age = 0
