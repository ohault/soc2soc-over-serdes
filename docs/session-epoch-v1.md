# RTL session epoch v1 — implementation status

## Implementation status

The RTL control manager now implements deterministic epoch election. The lower peer-ID endpoint increments its active 64-bit session ID after lane recovery; the higher peer-ID endpoint adopts a strictly newer HELLO from that configured authority. The active ID is passed into the endpoint's DATA TX/RX paths, and a session-change pulse resets per-session endpoint state. The initial `SESSION_ID` parameter remains the common seed for first power-up. The epoch register is volatile and is not persistent across independent cold boots.

Dynamic remote lane-ID discovery is enabled by the autonomous node wrapper. Crossed lane wiring is exercised by the two-node PHY-word test; duplicate remote lane IDs are rejected. The PHY bridge discards stale continuation words after a session drop, while the wire/session layer rejects DATA frames carrying an old epoch.

## Epoch rules

1. The configured lower peer_id is the only epoch initiator.
2. The initial non-zero SESSION_ID remains a common provisioning seed for first power-up.
3. After a runtime session fault and restoration of both local lanes, the lower-ID endpoint increments its 64-bit session ID and sends HELLO on both lanes using that new ID.
4. The higher-ID endpoint accepts a new session only when all of these hold:
   - the HELLO body identifies the configured lower-ID peer;
   - the proposed session ID is strictly greater than the highest accepted ID;
   - both local physical lanes are up;
   - lane count, profile and maximum payload are compatible.
5. On adoption, the higher-ID endpoint clears the old HELLO/READY state, credits, PING/PONG state, lane mappings and per-lane frame sequence state, then sends HELLO/READY using the adopted ID.
6. The lower-ID endpoint ignores attempts by the higher-ID peer to propose an epoch. Delayed HELLOs from older epochs are ignored.
7. DATA frames whose session ID differs from the active epoch are discarded without poisoning the new session. CONTROL frames are decoded in an epoch-neutral mode, then filtered by the control manager: current-epoch messages are processed, newer authoritative HELLOs may be adopted, and older/non-authoritative messages are ignored.
8. The session ID must never wrap. If the lower peer reaches 2^64-1, it fails closed and requires reprovisioning.

## Reset boundaries

- SESSION_ID is an initial seed, not a runtime constant after this feature.
- A session-ID change must pulse the control-path reset so both lane sequence spaces and dynamic lane maps are relearned, while the control manager itself retains the adopted epoch.
- The DATA path remains reset until HELLO/READY completes for the new epoch.
- The PHY byte/word bridge continues clocking idles and discards stale continuation words until a new SOP. A stale complete DATA frame may pass the PHY bridge but is rejected by its old session ID.
- A full power-cycle still requires a common provisioned seed or a board-level persistent boot nonce/counter. RTL registers alone cannot guarantee monotonicity across independent power loss.

## Implemented RTL elements

1. The CONTROL RX CDC path carries the received session ID to the control manager.
2. CONTROL decoding is epoch-neutral; the manager validates current, newer-authoritative and stale epochs. DATA decoding remains bound to the active session ID.
3. The manager exposes `active_session_id`, `session_changed` and `session_initiated`.
4. Only the lower peer ID initiates an increment after lane recovery; the higher peer adopts a strictly newer authoritative HELLO.
5. Per-session endpoint state and lane mappings are reset/relearned on epoch changes while the manager retains its active epoch.
6. RTL regressions cover lane loss, heartbeat timeout, session re-arm, crossed lane mapping, duplicate lane IDs and post-recovery traffic.

## Remaining hardening

- Add explicit stale complete-DATA and delayed old CONTROL-frame injection tests across an epoch transition.
- Test asymmetric cold reboot where one peer loses volatile epoch state. A persistent boot counter/nonce or explicit reprovisioning policy is required to prevent epoch rollback across independent power cycles.
- Test simultaneous lane recovery and session proposal collisions, plus the 64-bit epoch exhaustion fail-closed path.