---
name: ai-strategy
description: Guide for the game's AI system — 7 strategy models, decision functions, genome-driven evolution, arena testing. Apply when modifying AI behavior, adding AI strategies, or tuning AI parameters.
user-invocable: true
allowed-tools: Read, Grep, Bash, Edit, Write, Agent, Glob
---

# AI Strategy System Reference

**Load this skill when modifying AI behavior, adding strategies, tuning parameters, or working with the AI arena.**

---

## Architecture

AI strategies are **pure functions** — completely decoupled from Bevy ECS. They operate on plain data (`&[ProvinceState]`, `&[PlayerInfo]`, etc.) and return `PlayerDecision` actions.

```rust
pub fn decide_ai_turn(
    player_id: PlayerId,
    state: &GameState,  // read-only game state
    model: AiModel,     // which strategy to use
) -> Vec<PlayerDecision>
```

### Multi-Action Loop
Each AI turn runs up to **20 iterations**, simulating resource spending:
1. Call strategy function → get one decision
2. Simulate the decision (deduct resources, update state copy)
3. Repeat until resources exhausted or max iterations reached
4. Return all decisions as a batch

---

## Seven Strategy Models

### 1. Default (`ai/default.rs`)
**Balanced priority chain:** TH → attack weakest neighbor → economy → recruit

- Builds Town Hall first if affordable
- Attacks weakest neighbor if power ratio >= 2x
- Builds economy (Market, Bank)
- Recruits footmen with remaining resources
- Also has `decide_default_nodes` for city-node system

### 2. Aggressive (`ai/aggressive.rs`)
**Rush strategy:** Attack at 1x strength ratio, footmen only

- Skips buildings entirely
- Attacks immediately when power is equal or greater (1x ratio)
- Recruits only footmen (cheapest unit)
- Good for early pressure, poor late-game

### 3. Economic (`ai/economic.rs`)
**Build-first:** Full build order before any military action

- Priority: TH → Market → Bank → Barracks
- Only attacks at 3x power advantage
- Strong late-game economy, vulnerable early

### 4. Turtle (`ai/turtle.rs`)
**Defensive fortress:** Max defenses + archers

- Builds all defense upgrades first
- Recruits archers (defensive ranged units)
- Does NOT attack before turn 15
- Requires 4x power advantage to attack
- Very hard to kill, slow to win

### 5. Veteran (`ai/veteran.rs`)
**Phase-dependent:** Changes strategy based on game stage

- Early game: defense upgrades
- Mid game: economy buildings
- Late game: smart targeted attacks
- Grabs undefended territory (free land)
- Most sophisticated non-evolved strategy

### 6. Random (`ai/random.rs`)
**Uniformly random:** Picks any valid action each iteration

- Uses `pseudo_rand` for deterministic randomness
- Good baseline for measuring other AI effectiveness
- Occasionally makes brilliant accidental plays

### 7. Evolved (`ai/evolved.rs`)
**Genome-driven parametric:** 20 float parameters optimized by genetic algorithm

```rust
pub struct EvolvedGenome {
    attack_ratio_threshold: f32,    // min power ratio to attack
    economy_weight: f32,            // priority of economic buildings
    military_weight: f32,           // priority of recruitment
    defense_weight: f32,            // priority of defenses
    expansion_weight: f32,          // priority of territory grab
    // ... 15 more parameters
}
```

- `find_best_attack_ratio` helper evaluates all possible attacks
- Parameters tuned via evolutionary optimization in `ai-arena`
- Profiles stored in `EvolvedProfiles` resource

---

## Key Helper Functions (`ai/mod.rs`)

| Function | Purpose |
|---|---|
| `pseudo_rand(player_id, turn)` | Deterministic randomness from player + turn |
| `find_weakest_neighbour(state, player)` | Find adjacent player with lowest power |
| `compute_attack_power(state, player)` | Calculate total military strength |
| `decide_ai_turn(player, state, model)` | Main dispatcher |
| `decide_ai_turn_nodes(player, state, model)` | City-node variant |

---

## AI Arena (`crates/ai-arena/`)

Headless tournament runner — no Bevy dependency:

```bash
cargo run -p ai-arena                    # run tournament
cargo run -p ai-arena -- --help          # CLI options
cargo run -p ai-arena -- --games 100     # more games
cargo run -p ai-arena -- --evolve        # run evolution
```

### Tournament Mode
- Round-robin: every AI model plays every other
- Configurable game count per matchup
- Parallel via `rayon`
- Results exported as JSON

### Evolution Mode
- Genetic algorithm optimizes `EvolvedGenome` parameters
- Population of genomes, fitness = tournament win rate
- Crossover + mutation each generation
- Best genomes saved for use in main game

---

## National Abilities

AI cost calculations account for national abilities:

| Ability | Effect on AI |
|---|---|
| `Blitzkrieg` | Reduced attack cost |
| `Industrial` | Cheaper buildings |
| `CheapRecruits` | Cheaper unit recruitment |
| `Fortification` | Cheaper defenses |
| `Naval` | Cheaper sea transport |
| `Diplomatic` | Better alliance benefits |

The AI strategy functions check the player's national ability and adjust cost thresholds accordingly.

---

## Adding a New AI Strategy

1. Create `ai/my_strategy.rs` with function:
   ```rust
   pub fn decide_my_strategy(
       player_id: PlayerId,
       provinces: &[ProvinceState],
       players: &[PlayerInfo],
       turn: u32,
   ) -> Option<PlayerDecision>
   ```

2. Add variant to `AiModel` enum in `game/types.rs`:
   ```rust
   pub enum AiModel {
       Default, Aggressive, Economic, Turtle, Veteran, Random, Evolved,
       MyStrategy,  // add here
   }
   ```

3. Add dispatch branch in `ai/mod.rs` `decide_ai_turn`:
   ```rust
   AiModel::MyStrategy => my_strategy::decide_my_strategy(player_id, ...),
   ```

4. Add to `ai/mod.rs` module declaration: `pub mod my_strategy;`

5. Update AI arena matchups in `crates/ai-arena/src/main.rs`

6. Test with arena: `cargo run -p ai-arena -- --games 50`

---

## Key Files

| File | Purpose |
|---|---|
| `ai/mod.rs` | Dispatcher, shared helpers, multi-action loop |
| `ai/default.rs` | Default balanced strategy |
| `ai/aggressive.rs` | Rush strategy |
| `ai/economic.rs` | Build-first strategy |
| `ai/turtle.rs` | Defensive fortress strategy |
| `ai/veteran.rs` | Phase-dependent smart strategy |
| `ai/random.rs` | Random baseline |
| `ai/evolved.rs` | Genome-driven parametric strategy |
| `game/types.rs` | `AiModel` enum, `PlayerDecision` enum |
| `crates/ai-arena/` | Headless tournament/evolution runner |

---

## Design Principles

1. **Pure functions:** AI never touches Bevy ECS — operates on plain data only
2. **Deterministic:** Given same state + `pseudo_rand`, produces same decisions
3. **Batch output:** Returns Vec of decisions, not one-at-a-time
4. **Testable:** Can test any strategy with synthetic game state
5. **Composable:** New strategies can call helper functions from `ai/mod.rs`
6. **Evolvable:** The `Evolved` strategy proves the architecture supports genetic optimization
