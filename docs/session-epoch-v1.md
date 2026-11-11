# RTL session epoch v1 proposal

## Current limitation

The Python reference control plane already supports deterministic epoch election: the endpoint with the lower peer_id proposes a strictly newer 64-bit session ID and the higher-ID endpoint adopts it. The RTL control manager still uses a fixed SESSION_ID provisioned identically at both peers. A coordinated reset currently resets the physical lane FIFOs as well as the bonding domains because a stale complete frame can carry a valid SOP and pass the bridge's continuation flush.

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

## Implementation sequence

1. Add the received wire-header session ID to the CONTROL RX CDC path.
2. Make CONTROL decoders accept any non-zero session ID for the manager to validate; keep DATA decoders bound to the active session ID.
3. Add active_session_id and session_changed to the RTL control manager.
4. Implement lower-peer epoch increment after lane recovery and higher-peer adoption of a strictly newer authoritative HELLO.
5. Reset per-session lane/control state on epoch changes without resetting the manager's epoch register.
6. Add RTL tests for stale complete DATA frames, delayed old HELLO/READY, non-authoritative epoch proposals, simultaneous restarts and overflow.