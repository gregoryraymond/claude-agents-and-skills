---
name: networking
description: Guide for this project's multiplayer architecture — WebTransport, WebSocket relay, lobby server, message protocol, state sync. Apply when modifying networking, lobby, multiplayer, or host/client code.
user-invocable: true
allowed-tools: Read, Grep, Bash, Edit, Write, Agent, Glob
---

# Multiplayer Networking Reference

**Load this skill when modifying networking, lobby, multiplayer, or host/client code.**

---

## Architecture Overview

```
┌─────────┐     WebSocket      ┌──────────────┐     WebSocket      ┌─────────┐
│  Client  │ ◄──── relay ─────► │ Lobby Server │ ◄──── relay ─────► │  Host   │
│ (Native) │                    │   (Axum)     │                    │(Native) │
└─────────┘                    └──────────────┘                    └─────────┘
```

**Primary production path:** All game traffic flows through the lobby server's WebSocket relay. Direct WebTransport connections are reserved for future use.

---

## Network Roles

```rust
pub enum NetworkRole {
    Offline,                          // Local-only play
    Host { port: u16, room_code: String },  // Authoritative host
    Relay { room_code: String },      // Client via WebSocket relay
    Client { host_url: String },      // Direct WebTransport (reserved)
}
```

---

## Message Protocol

All messages are JSON-serialized over WebSocket/WebTransport.

### Client → Host (9 variants)
| Message | Purpose |
|---|---|
| `PickNation(nation_id)` | Draft phase selection |
| `SubmitDecision(decision)` | Single player action |
| `SubmitDecisions(Vec<decision>)` | Batch actions |
| `LeaveGame` | Player disconnect |
| `Rejoin(name)` | Mid-game reconnection |
| `TakeOverSlot(slot)` | Claim AI slot |
| `AiVote(vote)` | Vote on AI model |
| `DraftPreview(nation)` | Preview draft pick |

### Host → Client (21 variants)
| Message | Purpose |
|---|---|
| `Welcome` | Connection accepted |
| `DraftTurn` | It's your pick |
| `NationPicked` | Someone drafted a nation |
| `GameStart` | Game begins |
| `TurnStart` | New turn data |
| `DecisionReceived` | Ack player action |
| `AllDecisionsIn` | All players submitted |
| `StateSync` | Full game state snapshot |
| `GameOver` | Game ended |
| `PlayerDisconnected/Reconnected` | Connection events |
| `RejoinWelcome` | Full state for rejoining player |
| `LobbySlotUpdate` | Lobby roster change |
| `AiSlotOffer` | Available AI slots for takeover |
| `AiVoteStart/Progress/Received` | AI voting flow |
| `DraftPreview` | Draft pick preview broadcast |
| `Error` | Error message |

### Relay Wrapper
```rust
struct IdentifiedClientMessage {
    sender: String,     // player name
    message: ClientMessage,
}
```
The lobby server wraps client messages with sender identity for host-side player mapping.

---

## Lobby Server (`crates/lobby-server/`)

Axum-based HTTP + WebSocket server with SQLite.

### REST Endpoints
| Endpoint | Purpose |
|---|---|
| `GET /health` | Health check |
| `GET /whoami` | Current session info |
| `POST /lobby/create` | Create game room |
| `POST /lobby/join` | Join game room |
| `POST /lobby/leave` | Leave game room |
| `GET /lobby/list` | List active rooms |

### WebSocket Relay
- Bidirectional message forwarding between host and clients
- Room-based routing via `room_code`
- Handles reconnection and timeout

### Auth
- Registration/login with SHA-256 + bcrypt password hashing
- Session tokens for persistent identity

---

## Transport Layers

### WebTransport (Host)
```rust
// host.rs — wtransport on background tokio runtime
// mpsc bridge to Bevy (channel sender/receiver)
let (tx, rx) = mpsc::channel::<Message>(256);
// Host spawns tokio task, Bevy reads from rx in Update system
```

### WebSocket Relay (Client)
```rust
// client.rs — tokio-tungstenite WebSocket connection
// Connects to lobby server relay, messages forwarded to host
```

### Key Architecture Decisions
- **Background runtime:** Native networking runs on a separate tokio runtime, bridged to Bevy via `mpsc` channels
- **No async in Bevy systems:** Systems poll channels each frame — `while let Ok(msg) = rx.try_recv()`
- **Serialization:** JSON via serde — not binary (simplicity over performance for a strategy game)

---

## State Sync

### Known Limitation (Critical)
After `GameStart`, the host does **NOT** broadcast per-turn state. Clients compute turns locally. This works for 2 players but **will desync with 3+ players**.

Relevant messages exist (`TurnStart`, `AllDecisionsIn`, `StateSync`) but are not sent after game start.

### Mid-Game Rejoin Flow
1. Late client sends `Rejoin(name)`
2. Host sends `AiSlotOffer` (available AI slots)
3. Client picks slot via `TakeOverSlot(slot_id)`
4. Host sends `RejoinWelcome` with full state snapshot
5. Client hydrates `GameState` and enters `PlayerTurn`

---

## Key Files

| File | Purpose |
|---|---|
| `net/mod.rs` | `NetworkPlugin`, `NetworkState` resource, `NetworkRole` enum, async name/lobby/register operations |
| `net/messages.rs` | All message types, serialization, round-trip tests |
| `net/host.rs` | Native WebTransport host server, tokio runtime bridge |
| `net/client.rs` | Client networking, WebSocket relay |
| `game/network.rs` | Bevy system processing incoming messages, state transitions |
| `game/lobby.rs` | Lobby phase UI and networking flow |

---

## Community Networking Crates

If you need to extend the networking:

| Crate | Architecture | Bevy 0.15 | Best For |
|---|---|---|---|
| **bevy_renet** | Client-server, message channels | v1.0 compatible | Turn-based / strategy (closest to current architecture) |
| **lightyear** | Full replication, prediction, rollback | Not yet compatible | Fast-paced multiplayer |
| **matchbox** | P2P WebRTC | v0.11 compatible | Browser P2P, rollback fighters |

### bevy_renet Pattern (if adopting)
```rust
// Channel types
ReliableOrdered    // chat, game events, state sync
ReliableUnordered  // asset requests
Unreliable         // position updates, inputs

// Transport
renet_netcode      // UDP with encryption + auth
// Custom WebSocket transport possible for lobby-server integration
```

---

## Adding New Message Types

1. Add variant to `ClientMessage` or `HostMessage` in `net/messages.rs`
2. Add serialization round-trip test in the `#[cfg(test)]` module
3. Handle the message in `game/network.rs` (incoming processing system)
4. Send the message from the appropriate system (host.rs or client.rs)

**Convention:** Messages are named from the perspective of the sender. `ClientMessage::SubmitDecision` = client sends to host.

---

## Performance Considerations

- JSON serialization is fine for a turn-based strategy game (small messages, low frequency)
- If moving to real-time, consider bincode or MessagePack
- WebSocket relay adds ~1 hop of latency vs direct WebTransport
- The mpsc channel bridge means messages are processed at most once per frame (Bevy Update tick)
