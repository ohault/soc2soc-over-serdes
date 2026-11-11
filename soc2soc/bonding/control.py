# SPDX-License-Identifier: BSD-2-Clause
"""Framework-neutral bonded-link control plane reference model.

Models HELLO/READY discovery, per-lane control queues, control priority,
CREDIT coalescing, and per-lane frame sequence numbers. It is a software
reference model, not synthesizable RTL.
"""
from __future__ import annotations

from collections import deque
from dataclasses import dataclass
import struct
from typing import Optional

from .wire import (
    ControlOpcode, Frame, FrameType, encode_control_body, encode_data_body,
)


class ControlPlaneError(Exception):
    """Base exception for control-plane state errors."""


class ControlNegotiationError(ControlPlaneError):
    """Peer identity or lane/profile configuration is incompatible."""


class ControlSessionDown(ControlPlaneError):
    """The aggregate control session is not ready."""


@dataclass(frozen=True)
class ControlConfig:
    peer_id: int
    session_id: int
    lane_count: int
    profile_id: int
    max_payload: int = 4096
    initial_rx_bytes: int = 16384
    initial_rx_packets: int = 64
    control_queue_depth: int = 4
    expected_peer_id: Optional[int] = None

    def __post_init__(self):
        limits = (
            ("peer_id", self.peer_id, 64, False),
            ("session_id", self.session_id, 64, True),
            ("lane_count", self.lane_count, 8, True),
            ("profile_id", self.profile_id, 16, False),
            ("max_payload", self.max_payload, 16, True),
            ("initial_rx_bytes", self.initial_rx_bytes, 64, False),
            ("initial_rx_packets", self.initial_rx_packets, 32, False),
            ("control_queue_depth", self.control_queue_depth, 16, True),
        )
        for name, value, bits, positive in limits:
            if not isinstance(value, int) or isinstance(value, bool):
                raise TypeError(f"{name} must be an integer")
            if value < (1 if positive else 0) or value >= (1 << bits):
                raise ValueError(f"{name} is outside its {bits}-bit range")
        if self.expected_peer_id is not None:
            if not isinstance(self.expected_peer_id, int) or not 0 <= self.expected_peer_id < (1 << 64):
                raise ValueError("expected_peer_id must fit in 64 bits")


class BondedControlPlane:
    """Control queues and HELLO/READY state for a bonded set of lanes.

    ingress_lane is the local physical adapter index on which a frame arrived.
    The lane_id in the peer's frame is its own logical lane index. The mapping
    is discovered and checked as a one-to-one mapping; cable crossover is
    therefore supported without assuming matching connector numbers.
    """

    def __init__(self, config: ControlConfig):
        self.config = config
        self.lanes_up = [False] * config.lane_count
        self.peer_lane_by_local: list[Optional[int]] = [None] * config.lane_count
        self._hello_seen = [False] * config.lane_count
        self._ready_seen = [False] * config.lane_count
        self._control: list[deque[tuple[ControlOpcode, bytes]]] = [
            deque() for _ in range(config.lane_count)
        ]
        self._data: list[deque[tuple[int, bytes]]] = [
            deque() for _ in range(config.lane_count)
        ]
        self._frame_sequence = [0] * config.lane_count
        self.fault_reason: Optional[str] = None
        self.remote_credit_bytes = 0
        self.remote_credit_packets = 0
        self.remote_max_payload: Optional[int] = None

    @property
    def session_ready(self) -> bool:
        return (
            self.fault_reason is None
            and all(self.lanes_up)
            and all(self._hello_seen)
            and all(self._ready_seen)
        )

    @property
    def control_queue_depths(self) -> tuple[int, ...]:
        return tuple(len(q) for q in self._control)

    @property
    def data_queue_depths(self) -> tuple[int, ...]:
        return tuple(len(q) for q in self._data)

    def set_lane_up(self, lane: int, up: bool) -> None:
        self._check_lane(lane)
        was_up = self.lanes_up[lane]
        self.lanes_up[lane] = bool(up)
        if was_up and not up:
            self._fault(f"lane {lane} went down")
        elif up and not was_up and any(self._hello_seen):
            # A lane joining after establishment requires a new all-lane epoch.
            self._fault(f"lane {lane} came up after control session start")

    def start(self) -> None:
        """Queue HELLO on every currently-up lane."""
        if not all(self.lanes_up):
            raise ControlSessionDown("all configured lanes must be up before start")
        if any(self._hello_seen) or any(self._ready_seen):
            raise ControlPlaneError("control session has already been started")
        body = struct.pack(
            ">QBH H Q I".replace(" ", ""),
            self.config.peer_id,
            self.config.lane_count,
            self.config.profile_id,
            self.config.max_payload,
            self.config.initial_rx_bytes,
            self.config.initial_rx_packets,
        )
        for lane in range(self.config.lane_count):
            self._queue_control(lane, ControlOpcode.HELLO, body)

    def receive(self, ingress_lane: int, frame: Frame) -> None:
        """Consume a decoded CONTROL frame received on a local physical lane."""
        self._check_lane(ingress_lane)
        if not self.lanes_up[ingress_lane]:
            raise ControlSessionDown(f"control frame arrived on down lane {ingress_lane}")
        if frame.frame_type != FrameType.CONTROL:
            raise ControlPlaneError("control plane received a non-CONTROL frame")
        if frame.session_id != self.config.session_id:
            return  # stale frame from a previous session; never changes state
        if frame.lane_id >= self.config.lane_count:
            self._fault("peer advertised an out-of-range lane identity")
            raise ControlNegotiationError(self.fault_reason)
        opcode = ControlOpcode(frame.body[0])
        fields = frame.body[1:]

        # Once a physical connection has been mapped during HELLO, every
        # subsequent control frame on it must retain that peer lane identity.
        if opcode not in (ControlOpcode.HELLO, ControlOpcode.READY):
            mapped_peer_lane = self.peer_lane_by_local[ingress_lane]
            if mapped_peer_lane is None:
                raise ControlPlaneError("control frame received before lane mapping")
            if frame.lane_id != mapped_peer_lane:
                self._fault("control frame arrived with unexpected peer lane identity")
                raise ControlNegotiationError(self.fault_reason)

        if opcode == ControlOpcode.HELLO:
            self._receive_hello(ingress_lane, frame.lane_id, fields)
        elif opcode == ControlOpcode.READY:
            self._receive_ready(ingress_lane, frame.lane_id, fields)
        elif opcode == ControlOpcode.CREDIT:
            byte_limit, packet_limit = struct.unpack(">QI", fields)
            self.remote_credit_bytes = max(self.remote_credit_bytes, byte_limit)
            self.remote_credit_packets = max(self.remote_credit_packets, packet_limit)
        elif opcode == ControlOpcode.PING:
            self._queue_control(ingress_lane, ControlOpcode.PONG, fields)
        elif opcode == ControlOpcode.PONG:
            pass  # Liveness accounting is owned by the timer/supervision layer.
        elif opcode in (ControlOpcode.RESET, ControlOpcode.ERROR):
            self._fault(f"peer sent {opcode.name}: {fields.hex()}")
        else:  # Defensive; wire decoder already rejects unknown values.
            self._fault(f"unsupported control opcode {opcode!r}")

    def _receive_hello(self, local_lane: int, peer_lane: int, fields: bytes) -> None:
        peer_id, lane_count, profile_id, max_payload, rx_bytes, rx_packets = struct.unpack(">QBH H Q I".replace(" ", ""), fields)
        if peer_id == self.config.peer_id:
            self._fault("peer identity equals local identity")
            raise ControlNegotiationError(self.fault_reason)
        if self.config.expected_peer_id is not None and peer_id != self.config.expected_peer_id:
            self._fault("unexpected peer identity")
            raise ControlNegotiationError(self.fault_reason)
        if lane_count != self.config.lane_count or profile_id != self.config.profile_id:
            self._fault("peer lane-count/profile mismatch")
            raise ControlNegotiationError(self.fault_reason)
        if max_payload < 1 or max_payload > self.config.max_payload:
            self._fault("peer maximum payload is incompatible")
            raise ControlNegotiationError(self.fault_reason)
        existing = self.peer_lane_by_local[local_lane]
        if existing is not None and existing != peer_lane:
            self._fault("peer changed lane identity on a physical lane")
            raise ControlNegotiationError(self.fault_reason)
        if peer_lane in [
            value for index, value in enumerate(self.peer_lane_by_local)
            if index != local_lane and value is not None
        ]:
            self._fault("duplicate peer lane mapping")
            raise ControlNegotiationError(self.fault_reason)
        already_seen = self._hello_seen[local_lane]
        self.peer_lane_by_local[local_lane] = peer_lane
        self._hello_seen[local_lane] = True
        self.remote_max_payload = max_payload if self.remote_max_payload is None else min(self.remote_max_payload, max_payload)
        self.remote_credit_bytes = max(self.remote_credit_bytes, rx_bytes)
        self.remote_credit_packets = max(self.remote_credit_packets, rx_packets)
        if already_seen:
            # Duplicate HELLO is idempotent: refresh monotonic grants but do
            # not enqueue an unbounded stream of duplicate READY responses.
            return
        ready_fields = struct.pack(">QBH", self.config.peer_id, self.config.lane_count, self.config.profile_id)
        self._queue_control(local_lane, ControlOpcode.READY, ready_fields)

    def _receive_ready(self, local_lane: int, peer_lane: int, fields: bytes) -> None:
        peer_id, lane_count, profile_id = struct.unpack(">QBH", fields)
        if peer_id == self.config.peer_id:
            self._fault("READY peer identity equals local identity")
            raise ControlNegotiationError(self.fault_reason)
        if self.config.expected_peer_id is not None and peer_id != self.config.expected_peer_id:
            self._fault("READY contains unexpected peer identity")
            raise ControlNegotiationError(self.fault_reason)
        if not self._hello_seen[local_lane]:
            raise ControlPlaneError("READY received before HELLO on this lane")
        if lane_count != self.config.lane_count or profile_id != self.config.profile_id:
            self._fault("READY lane-count/profile mismatch")
            raise ControlNegotiationError(self.fault_reason)
        mapped = self.peer_lane_by_local[local_lane]
        if mapped is not None and mapped != peer_lane:
            self._fault("READY lane identity differs from HELLO")
            raise ControlNegotiationError(self.fault_reason)
        if peer_lane in [
            value for index, value in enumerate(self.peer_lane_by_local)
            if index != local_lane and value is not None
        ]:
            self._fault("duplicate peer lane mapping in READY")
            raise ControlNegotiationError(self.fault_reason)
        self.peer_lane_by_local[local_lane] = peer_lane
        self._ready_seen[local_lane] = True

    def enqueue_credit(self, byte_limit: int, packet_limit: int, lane: Optional[int] = None) -> None:
        if not isinstance(byte_limit, int) or not isinstance(packet_limit, int) or byte_limit < 0 or packet_limit < 0:
            raise ValueError("credit limits must be non-negative integers")
        fields = struct.pack(">QI", byte_limit, packet_limit)
        lanes = range(self.config.lane_count) if lane is None else (lane,)
        for index in lanes:
            self._check_lane(index)
            self._queue_control(index, ControlOpcode.CREDIT, fields, coalesce=True)

    def enqueue_data(self, lane: int, packet_sequence: int, payload: bytes) -> None:
        self._check_lane(lane)
        if not self.session_ready:
            raise ControlSessionDown("cannot enqueue DATA before all lanes are ready")
        if not isinstance(payload, bytes) or len(payload) > self.config.max_payload:
            raise ValueError("invalid DATA payload")
        self._data[lane].append((packet_sequence, payload))

    def next_frame(self, lane: int) -> Optional[Frame]:
        """Return next frame for a lane; CONTROL always precedes queued DATA."""
        self._check_lane(lane)
        if not self.lanes_up[lane]:
            return None
        if self._control[lane]:
            opcode, fields = self._control[lane].popleft()
            body = encode_control_body(opcode, fields)
            frame = Frame(FrameType.CONTROL, lane, self.config.session_id,
                          self._frame_sequence[lane], body)
        elif self.session_ready and self._data[lane]:
            sequence, payload = self._data[lane].popleft()
            body = encode_data_body(sequence, payload)
            frame = Frame(FrameType.DATA, lane, self.config.session_id,
                          self._frame_sequence[lane], body)
        else:
            return None
        if self._frame_sequence[lane] == 0xFFFFFFFF:
            self._fault(f"frame sequence exhausted on lane {lane}; restart session")
            raise ControlSessionDown(self.fault_reason)
        self._frame_sequence[lane] += 1
        return frame

    def _queue_control(self, lane: int, opcode: ControlOpcode, fields: bytes, *, coalesce: bool = False) -> None:
        queue = self._control[lane]
        if coalesce and opcode == ControlOpcode.CREDIT:
            for index, (queued_opcode, _) in enumerate(queue):
                if queued_opcode == ControlOpcode.CREDIT:
                    queue[index] = (opcode, fields)
                    return
        if len(queue) >= self.config.control_queue_depth:
            if opcode == ControlOpcode.CREDIT:
                # CREDIT is replaceable state. If full, replace an older CREDIT;
                # otherwise leave the queue unchanged and report backpressure.
                for index, (queued_opcode, _) in enumerate(queue):
                    if queued_opcode == ControlOpcode.CREDIT:
                        queue[index] = (opcode, fields)
                        return
            raise ControlPlaneError(f"reserved CONTROL queue full on lane {lane}")
        queue.append((opcode, fields))

    def _check_lane(self, lane: int) -> None:
        if not isinstance(lane, int) or isinstance(lane, bool) or not 0 <= lane < self.config.lane_count:
            raise ValueError(f"invalid lane index {lane!r}")

    def _fault(self, reason: str) -> None:
        self.fault_reason = reason
        for queue in self._data:
            queue.clear()
        for queue in self._control:
            queue.clear()
        self._hello_seen = [False] * self.config.lane_count
        self._ready_seen = [False] * self.config.lane_count
        self.peer_lane_by_local = [None] * self.config.lane_count

