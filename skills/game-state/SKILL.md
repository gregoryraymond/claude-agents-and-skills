---
name: game-state
description: Guide for this project's game state management — GamePhase state machine, turn flow, resource processing, phase transitions, custom run conditions. Apply when modifying game phases, turn logic, or state transitions.
user-invocable: true
allowed-tools: Read, Grep, Bash, Edit, Write, Agent, Glob
---

# Game State Management Reference

**Load this skill when modifying game phases, turn flow, state transitions, or resource processing.**

---

## Why Not Bevy States?

This project uses a **custom `GamePhase` enum inside a `GameState` resource** instead of Bevy's built-in `States` trait. Reasons:
- `GameState` bundles phase with all game data (players, action queue, combat state)
- Phase transitions happen within game logic systems, not via `NextState<T>`
- Run conditions use custom closures checking the resource, not `in_state()`

---

## GamePhase State Machine

```
Lobby ──► WaitingRoom ──► NationDraft ──► NationSelect ──► AiVote ──► AiDraft
                                                                        │
                                                                        ▼
GameOver ◄── TurnSummary ◄── CombatResolution ◄── ActionAnimation ◄── PlayerTurn
    │                                                                    ▲
    └──────────────────────────────────────────────────────────────────────┘
                                (loop)
```

### All Phases

| Phase | Duration | Purpose |
|---|---|---|
| `Lobby` | Until player action | Main menu: Host/Join/Local |
| `WaitingRoom` | Until all players ready | Multiplayer lobby roster |
| `NationDraft` | 120s timer per pick | Sequential nation picking |
| `NationSelect` | Until confirmed | Single-player nation selection |
| `AiVote` | Until all votes in | Vote on AI difficulty |
| `AiTakeoverSelect` | Until selection | Mid-game rejoin: pick AI slot |
| `AiDraft` | Instant | AI auto-assigns remaining nations |
| `PlayerTurn` | 30s timer | Human submits decisions |
| `ActionAnimation` | 2-5s | March/attack/build animations play |
| `CombatResolution` | 3 rounds | Deterministic combat with random modifiers |
| `TurnSummary` | 3s auto-dismiss | Results display |
| `GameOver` | Until restart vote | Final standings |

### Shortcuts
- **Single-player:** Lobby → NationSelect → NationSelectConfirm → AiDraft → PlayerTurn
- **Mid-game join:** AiTakeoverSelect → PlayerTurn
- **Escape from pre-game:** Any pre-game phase → Lobby

---

## GameState Resource

```rust
#[derive(Resource)]
pub struct GameState {
    pub phase: GamePhase,
    pub players: Vec<PlayerInfo>,
    pub turn: u32,
    pub action_queue: Vec<PlayerDecision>,
    pub movement_orders: HashMap<Entity, MovementOrder>,
    pub context_menu: Option<ContextMenu>,
    pub combat_state: Option<CombatState>,
    pub active_event: Option<GameEvent>,
    pub elapsed: f32,
    // ... more fields
}
```

---

## Phase-Gated Systems Pattern

```rust
// Custom run condition factory
fn in_phase_fn(check: impl Fn(&GamePhase) -> bool + Send + Sync + 'static) -> impl Fn(Res<GameState>) -> bool {
    move |state: Res<GameState>| check(&state.phase)
}

// Usage in plugin registration
app.add_systems(Update, (
    handle_player_input
        .run_if(in_phase_fn(|p| matches!(p, GamePhase::PlayerTurn))),
    animate_actions
        .run_if(in_phase_fn(|p| matches!(p, GamePhase::ActionAnimation))),
    resolve_combat
        .run_if(in_phase_fn(|p| matches!(p, GamePhase::CombatResolution))),
));
```

### UI Visibility
`hide_phase_panels` runs on `resource_changed::<GameState>` and toggles UI panel visibility based on current phase.

---

## Turn Processing Flow

### 1. PlayerTurn Phase
- Human players submit decisions (action queue)
- 30-second timer
- AI decisions collected when timer expires or all humans submit

### 2. ActionAnimation Phase (2-5s)
- `collect_ai_and_animate` gathers AI decisions
- Armies with movement orders: Walk animation + position lerp
- Attacking armies: Attack animation
- Building actions: Pick_up animation

### 3. CombatResolution Phase
- 3-round combat with deterministic random modifiers
- Each round: attacker strength vs defender strength + terrain bonus
- Casualties calculated, survivors update

### 4. TurnSummary Phase (3s)
- Results displayed (territory changes, casualties)
- Auto-dismiss timer

### 5. Turn Cleanup
- `finish_turn_cleanup`: apply income, free troops, random events, increment turn
- `end_of_turn_resources`: multi-resource income calculation

### 6. Back to PlayerTurn

---

## Resource Processing (`turn_resources.rs`)

End-of-turn resource calculations:

| Resource | Income Source |
|---|---|
| **Gold** | Base + provinces + buildings (Market, Bank) + trade |
| **Population** | Base growth + food surplus |
| **Food** | Farms + province fertility |
| **Wood** | Lumber mills + forested provinces |
| **Metal** | Mines + mountain provinces |

**Maintenance costs:** Troop upkeep deducted from gold. Negative gold = attrition.

### Slider Drift (`relations.rs`)

Six diplomatic/internal sliders drift each turn:

| Slider | Drift Direction | Threshold Effects |
|---|---|---|
| Rebellion | Toward 50 (equilibrium) | High → income penalty, very high → revolt |
| Piety | Toward 0 (decay) | High → combat morale bonus |
| Authority | Toward 50 | High → faster recruitment |
| Pluralism | Toward 50 | High → tech discount |
| Corruption | Upward (grows) | High → income penalty |
| Coherence | Downward (decays) | Low → army penalty |

---

## Phase Transition Patterns

### Direct Transition
```rust
fn check_game_over(mut state: ResMut<GameState>) {
    if only_one_player_alive(&state) {
        state.phase = GamePhase::GameOver;
    }
}
```

### Timer-Based Transition
```rust
fn tick_animation(time: Res<Time>, mut state: ResMut<GameState>) {
    state.elapsed += time.delta_secs();
    if state.elapsed >= ANIMATION_DURATION {
        state.elapsed = 0.0;
        state.phase = GamePhase::CombatResolution;
    }
}
```

### Network-Triggered Transition
```rust
fn handle_network_messages(mut state: ResMut<GameState>, network: Res<NetworkState>) {
    // Process incoming messages, may change phase
    if let Some(msg) = network.try_recv() {
        match msg {
            HostMessage::GameStart { .. } => {
                state.phase = GamePhase::PlayerTurn;
            }
            // ...
        }
    }
}
```

---

## Key Resources

| Resource | Purpose |
|---|---|
| `GameState` | Primary state: phase, players, turn, actions, combat |
| `HoveredCountry` | Which country the cursor is over |
| `SelectedCityNode` | Currently selected city node entity |
| `SelectedArmyEntity` | Currently selected army entity |
| `MapColorModeRes` | Map visualization mode (political, terrain, etc.) |
| `TechPanelOpen` | Whether tech tree panel is shown |
| `ActiveProvinceTab` | Which tab is active in province info |
| `RestartVotes` | Post-game restart voting state |
| `ScoreboardHoveredPlayer` | Which player is hovered on scoreboard |

---

## Key Files

| File | Purpose |
|---|---|
| `game/types.rs` | `GamePhase`, `GameState`, `PlayerInfo`, `PlayerDecision`, all core types |
| `game/mod.rs` | System registration with phase gating |
| `game/player_turn.rs` | Player turn logic, decision submission |
| `game/network.rs` | Network message → phase transition |
| `game/turn_resources.rs` | End-of-turn resource processing |
| `game/relations.rs` | Slider drift, diplomatic relation updates |
| `game/army.rs` | Army entity management, combat engagement |
| `game/node_interaction.rs` | Click interaction, selection |
| `game/lobby.rs` | Lobby phase flow |
| `game/draft.rs` | Draft phases flow |

---

## Adding a New Phase

1. Add variant to `GamePhase` enum in `game/types.rs`
2. Add systems with `run_if(in_phase_fn(...))` in `game/mod.rs`
3. Handle UI visibility in `hide_phase_panels` system
4. Add transition logic (what triggers entry, what triggers exit)
5. If networked: add message types for sync
6. Test with the test harness (see `/testing` skill)
