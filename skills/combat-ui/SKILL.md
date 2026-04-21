---
name: combat-ui
description: Guide for the combat engine, combat UI screens (pre-battle + battle report), unit roster, counter mechanics, kill attribution, and upgrade bonus tracking. Apply when modifying combat resolution, combat UI, unit types, counter relationships, or army composition display.
user-invocable: true
allowed-tools: Read, Grep, Bash, Edit, Write, Agent, Glob
---

# Combat System & UI Reference

**Load this skill when modifying combat resolution, combat UI screens, unit types, counter relationships, kill attribution, army composition display, or recruitment.**

---

## Architecture Overview

The combat system has three layers:

1. **Combat Engine** (`combat.rs` ~1242 lines) — Pure data: unit types, counter matrix, damage resolution, kill attribution
2. **Combat UI** (`combat_ui.rs` ~1682 lines) — Two overlay screens: Pre-Battle and Battle Report, built with pure Bevy flexbox
3. **System Wiring** (`mod.rs`) — Phase-gated systems running during `GamePhase::CombatResolution`

---

## Key Files

| File | Role |
|---|---|
| `src/game/combat.rs` | Combat engine: 13 unit types, 7 combat roles, counter matrix, damage resolution, kill attribution, `CombatReport` |
| `src/game/combat_ui.rs` | Pre-battle screen + Battle report screen spawn systems, button handlers, combat flow glue (fight/retreat/dismiss) |
| `src/game/components.rs` | All marker components for combat UI entities (`PreBattleScreen`, `BattleReportScreen`, `CombatPanel`, buttons, bars, etc.) |
| `src/game/ui_style.rs` | Color tokens: `COMBAT_PANEL_BG`, `COMBAT_GOLD_TRIM`, `COMBAT_YOUR_FORCES`, `COMBAT_ENEMY_FORCES`, 13 kill attribution colors, etc. |
| `src/game/node_interaction.rs` | Triggers combat: `auto_siege_system`, `auto_field_battle_system` create `PendingCombatEngagement` |
| `src/game/army.rs` | `Army` struct with `units: BTreeMap<CombatUnitType, u32>`, `apply_casualties()` |
| `src/game/types.rs` | `PlayerUpgrades` (melee/ranged attack/defense tracks), `PlayerInfo::unlocked_units()`, `PlayerInfo::is_unit_unlocked()` |
| `src/game/tech_tree.rs` | `TechEffect::UnlockUnit(CombatUnitType)`, `unlocked_units()`, `is_unit_unlocked()` |
| `src/game/tech_data.rs` | 14 nation tech trees with `UnlockUnit` effects at T2, T3, T5, T6 tiers |
| `src/game/mod.rs` | Combat UI system registration with phase gating |
| `src/game/border_defense.rs` | Border auto-combat (uses `resolve_combat` directly, no UI) |

---

## Unit Roster (13 Core Units)

### Tier Structure

```
Tier 1 (always available): Scavenger, Scrapper, Scout
Tier 2 (mid-tree unlock):  Raider, Shieldbearer, Marksman, ChemThrower, MutantBrute
Tier 3 (late-tree unlock): WarRig, MortarCrew, GasBomber, MutantHoundPack, StimSoldier
```

### CombatUnitType Enum

All 13 variants in `combat.rs`. Key methods:

| Method | Returns | Purpose |
|---|---|---|
| `display_name()` | `&'static str` | Full name for UI (e.g., "Chem-Thrower") |
| `short_label()` | `&'static str` | 2-char label for compact display (e.g., "CT") |
| `combat_role()` | `CombatRole` | Role for counter matrix lookup |
| `tier()` | `u8` | 1, 2, or 3 |
| `base_attack()` | `f32` | Base attack power per soldier |
| `base_defense()` | `f32` | Base defense per soldier |
| `build_turns()` | `u32` | Turns to recruit (1/2/3 by tier) |
| `batch_size()` | `u32` | Soldiers per recruitment order |
| `recruit_cost()` | `u32` | Gold cost per order |
| `bar_color()` | `Color` | UI bar color (grouped by combat role) |

Constants: `CombatUnitType::ALL` (13), `TIER_1` (3), `TIER_2` (5), `TIER_3` (5)

### Unit Stats Reference

| Unit | Tier | Role | Atk | Def | Batch | Cost | Label |
|---|---|---|---|---|---|---|---|
| Scavenger | 1 | LightMelee | 2.0 | 1.5 | 2000 | 100 | SC |
| Scrapper | 1 | Ranged | 2.5 | 1.0 | 1000 | 120 | SP |
| Scout | 1 | FastRecon | 1.5 | 1.0 | 500 | 80 | ST |
| Raider | 2 | LightMelee | 4.0 | 1.5 | 800 | 180 | RD |
| Shieldbearer | 2 | HeavyArmor | 2.0 | 5.0 | 600 | 200 | SB |
| Marksman | 2 | Ranged | 4.5 | 1.0 | 400 | 220 | MK |
| ChemThrower | 2 | Chemical | 3.5 | 1.5 | 400 | 250 | CT |
| MutantBrute | 2 | MutantMelee | 5.0 | 3.5 | 300 | 280 | MB |
| WarRig | 3 | HeavyArmor | 5.5 | 6.0 | 100 | 500 | WR |
| MortarCrew | 3 | Siege | 5.0 | 1.0 | 200 | 350 | MC |
| GasBomber | 3 | Chemical | 4.0 | 1.0 | 200 | 300 | GB |
| MutantHoundPack | 3 | FastRecon | 3.5 | 1.5 | 400 | 250 | HP |
| StimSoldier | 3 | LightMelee | 5.0 | 2.0 | 300 | 300 | SS |

---

## Combat Roles & Counter Matrix

### 7 Combat Roles

| Role | Units | Strong vs | Weak vs |
|---|---|---|---|
| LightMelee | Scavenger, Raider, StimSoldier | Ranged, Siege | HeavyArmor, MutantMelee |
| Ranged | Scrapper, Marksman | HeavyArmor, Siege | LightMelee, FastRecon |
| FastRecon | Scout, MutantHoundPack | Ranged, Chemical, Siege | LightMelee, HeavyArmor |
| HeavyArmor | Shieldbearer, WarRig | LightMelee, MutantMelee, FastRecon | Chemical, Ranged |
| Chemical | ChemThrower, GasBomber | HeavyArmor, LightMelee | FastRecon, Siege |
| MutantMelee | MutantBrute | LightMelee, Ranged, FastRecon | Chemical, Siege |
| Siege | MortarCrew | HeavyArmor, MutantMelee, Chemical | FastRecon, LightMelee |

### Counter Multipliers (role_counter_multiplier)

Values > 1.0 = advantage, < 1.0 = disadvantage. Key matchups:

- Chemical vs HeavyArmor: **1.6** (strongest counter)
- FastRecon vs Ranged/Siege: **1.5**
- HeavyArmor vs LightMelee: **1.5**
- Siege vs HeavyArmor: **1.5**

### Per-Unit Adjustments

On top of role counters, 5 specific unit-pair adjustments exist:

| Attacker → Defender | Adjustment | Reason |
|---|---|---|
| Marksman → MutantBrute | +0.15 | Long range keeps brutes at bay |
| WarRig → StimSoldier | +0.10 | War Rig immune to shock |
| Scout → MortarCrew | +0.15 | Scouts overrun mortar positions |
| ChemThrower → MutantBrute | -0.10 | Brute regeneration offsets acid |
| MutantHoundPack → MortarCrew | +0.10 | Hounds reach mortars before firing |

### Floor

All counter multipliers are floored at **0.3** — no zero-damage matchups.

---

## Combat Resolution Algorithm

Located in `resolve_combat()` in `combat.rs`. Constants:

- **`COMBAT_LETHALITY = 0.30`** — Global scaling factor. ~30% of theoretical damage converts to kills.

### Algorithm Steps

1. **Compute raw damage**: Each attacker unit type vs each defender unit type. Factors: count × attack × counter_multiplier × defense_weight_fraction × conditions × lethality
2. **Defense weighting**: Incoming damage distributed across enemy types proportional to their defense share (tougher units absorb more)
3. **Upgrade bonuses**: Attack split into `(base_attack, upgraded_attack)` to track upgrade bonus kills separately
4. **Casualties**: Damage / defense_per_unit = kills. Capped at unit count with proportional scaling
5. **Winner determination**: Side inflicting more casualties wins (tiebreak: more survivors)
6. **Rout penalty**: Loser takes additional 20% casualties on surviving troops

### Upgrade Mapping

Upgrade tracks map to combat roles:
- **Melee upgrade track** → LightMelee, HeavyArmor, MutantMelee roles
- **Ranged upgrade track** → Ranged, Chemical, Siege roles
- **FastRecon** → Half melee bonus (hybrid)

---

## Kill Attribution

Each `UnitCasualties` struct tracks:

```rust
pub struct UnitCasualties {
    pub initial: u32,           // Starting count
    pub survived: u32,          // After combat
    pub killed_by: BTreeMap<CombatUnitType, u32>,           // Who killed them
    pub killed_by_upgrade_bonus: BTreeMap<CombatUnitType, u32>, // Subset from upgrades
}
```

- `killed_by` maps enemy unit type → number of kills it inflicted
- `killed_by_upgrade_bonus` is a **subset** of `killed_by` showing how many came from tech/upgrade bonuses
- Used in battle report to color-code bar segments by killer

---

## Combat UI Screens

### Design Language

- **Panel BG**: `COMBAT_PANEL_BG` (#12121E)
- **Gold trim/borders**: `COMBAT_GOLD_TRIM` (#BF9940)
- **Gold text**: `COMBAT_GOLD_TEXT` (#FFD94D)
- **Your forces**: `COMBAT_YOUR_FORCES` (#4DB3E6, blue)
- **Enemy forces**: `COMBAT_ENEMY_FORCES` (#E64D4D, red)
- **Survived**: `COMBAT_SURVIVED` (#99E666, green)
- **Threat HIGH**: `COMBAT_THREAT_HIGH` (red badge)
- **Threat MED**: `COMBAT_THREAT_MED` (amber badge)
- **All corners sharp** (no border-radius)
- **Fonts**: Cinzel for headings, Source Sans Pro for body (via `GameFonts` resource)
- **Warm cream text** (`CREAM`), not pure white

### Screen 1: Pre-Battle ("BATTLE AHEAD")

Spawned by `spawn_pre_battle_screen` when `PendingCombatEngagement` resource exists.

**Layout (top to bottom):**
1. Header bar: "BATTLE AHEAD" (gold text on dark bg)
2. Matchup header: "ATTACKER_NATION vs DEFENDER_NATION" with troop counts
3. Tug-of-war strength bar: single bar split at force ratio, subdivided by unit type colors
4. Unit legends: two columns (attacker left, defender right) with color swatches + "Unit Name (count)"
5. Gold divider
6. Key threats section: severity badges (HIGH/MED) + descriptive text (up to 5 threats)
7. Battlefield conditions: modifier chips with +/-% values
8. Gold divider
9. RETREAT (red border) / FIGHT (gold border) buttons

**Container**: 680px wide, max 90% height, scrollable, 1px gold border.

### Screen 2: Battle Report ("BATTLE REPORT")

Spawned by `spawn_battle_report_screen` when `ActiveCombatReport` resource exists.

**Layout (top to bottom):**
1. Header: "BATTLE REPORT"
2. Result banner: "VICTORY" (green) or "DEFEAT" (red), underlined
3. Two-column force breakdown:
   - Left: "YOUR FORCES" — per-unit-type bars with kill attribution
   - Right: "ENEMY FORCES" — same format
4. Kill legend per column: color swatches showing which enemy units did the killing
5. Gold divider
6. Combined strength bar: survivors comparison (attacker blue vs defender red)
7. Upgrade impact callout: orange-bordered text if upgrades caused bonus kills
8. CONTINUE button (gold, dismisses report)

**Container**: 720px wide, max 92% height, scrollable.

### Per-Unit Bar Anatomy (Battle Report)

```
[Unit Name (1,200 → 800)]
[████████░░░░░░░░░░░░░░░░]
 survived  kill_1  kill_2
```

- **Survived segment**: Unit's own `bar_color()`
- **Kill segments**: Colored by `kill_attribution_color(killer_type)` (13 distinct colors in `ui_style.rs`)
- **Upgrade bonus segments**: Same kill color but with gold border (`COMBAT_UPGRADE_BORDER`)
- **Ghost border**: `COMBAT_GHOST_BORDER` on the track showing original width

### Kill Attribution Colors (ui_style.rs)

| Unit | Color Token | Hex | Visual |
|---|---|---|---|
| Scavenger | `COMBAT_KILL_SCAVENGER` | rust orange | Warm melee |
| Scrapper | `COMBAT_KILL_SCRAPPER` | steel blue | Cool ranged |
| Scout | `COMBAT_KILL_SCOUT` | forest green | Fast recon |
| Raider | `COMBAT_KILL_RAIDER` | fiery orange | Aggressive |
| Shieldbearer | `COMBAT_KILL_SHIELDBEARER` | gunmetal | Armored |
| Marksman | `COMBAT_KILL_MARKSMAN` | deep blue | Precision |
| ChemThrower | `COMBAT_KILL_CHEMTHROWER` | toxic yellow-green | Chemical |
| MutantBrute | `COMBAT_KILL_MUTANTBRUTE` | mutant purple | Mutant |
| WarRig | `COMBAT_KILL_WARRIG` | iron gray | Heavy |
| MortarCrew | `COMBAT_KILL_MORTARCREW` | muddy brown | Siege |
| GasBomber | `COMBAT_KILL_GASBOMBER` | acid green | Chemical |
| MutantHoundPack | `COMBAT_KILL_MUTANTHOUNDPACK` | olive green | Fast |
| StimSoldier | `COMBAT_KILL_STIMSOLDIER` | amber glow | Stim |

---

## Marker Components (components.rs)

### Pre-Battle Screen
- `PreBattleScreen` — root dialog
- `PreBattleFightBtn` / `PreBattleRetreatBtn` — action buttons
- `TugOfWarBar` / `TugOfWarAttacker` / `TugOfWarDefender` — strength bar
- `PreBattleAttackerLegend` / `PreBattleDefenderLegend` — unit legends
- `PreBattleAttackerName` / `PreBattleDefenderName` — nation name text
- `PreBattleAttackerTotal` / `PreBattleDefenderTotal` — troop count text

### Battle Report Screen
- `BattleReportScreen` — root dialog
- `BattleReportDismissBtn` — CONTINUE button
- `BattleReportResultBanner` — VICTORY/DEFEAT banner
- `BattleReportAttackerColumn` / `BattleReportDefenderColumn` — force columns
- `BattleReportAttackerBar` / `BattleReportDefenderBar` — per-unit bars (with `.unit_type`)
- `BattleReportStrengthBar` / `BattleReportStrengthAttacker` / `BattleReportStrengthDefender`
- `BattleReportAttackerKillLegend` / `BattleReportDefenderKillLegend`
- `BattleReportUpgradeCallout` — upgrade impact text

### Shared
- `CombatPanel` — parent overlay (always exists, toggled via `display`)
- `ActiveCombatReport(CombatReport)` — resource holding current report

---

## Combat Flow (System Ordering)

All combat systems run during `GamePhase::CombatResolution`:

```
1. node_interaction triggers combat:
   - auto_siege_system / auto_field_battle_system
   - Creates PendingCombatEngagement resource
   - Sets GamePhase::CombatResolution

2. spawn_pre_battle_screen (runs when PendingCombatEngagement exists)
   - Populates CombatPanel with pre-battle UI

3. Player clicks FIGHT or RETREAT:
   - handle_fight_btn → inserts FightDecision resource
   - handle_retreat_btn → inserts RetreatDecision resource

4a. resolve_fight_decision (after handle_fight_btn):
   - Calls resolve_combat() from combat engine
   - Builds CombatReport
   - Inserts ActiveCombatReport + PendingCombatResult
   - Removes PendingCombatEngagement + FightDecision

4b. resolve_retreat_decision (after handle_retreat_btn):
   - Clears army target
   - Hides CombatPanel
   - Returns to GamePhase::PlayerTurn

5. spawn_battle_report_screen (runs when ActiveCombatReport exists)
   - Replaces pre-battle UI with battle report

6. Player clicks CONTINUE:
   - handle_dismiss_btn → inserts CombatDismissed, hides panel

7. apply_combat_results (after handle_dismiss_btn):
   - Applies casualties to Army/CityNode entities
   - Handles city capture on siege victory
   - Returns to GamePhase::PlayerTurn
   - Marks ScoreboardDirty
```

### AI-vs-AI Auto-Resolution

When combat is between two AI players (no local human involved), `node_interaction.rs` calls `resolve_combat()` directly and applies results without showing any UI. Only combats involving the local player show the pre-battle / battle report screens.

---

## Resources (combat_ui.rs)

| Resource | Purpose | Lifecycle |
|---|---|---|
| `PendingCombatEngagement` | Pre-battle data (entities, preview, conditions) | Inserted by node_interaction → removed after fight/retreat |
| `FightDecision` | Player chose FIGHT | Inserted by button → consumed by resolve_fight_decision |
| `RetreatDecision` | Player chose RETREAT | Inserted by button → consumed by resolve_retreat_decision |
| `ActiveCombatReport(CombatReport)` | Battle report data | Inserted after combat → removed on dismiss |
| `PendingCombatResult` | Deferred casualties to apply | Inserted with report → consumed by apply_combat_results |
| `CombatDismissed` | Player dismissed report | Inserted by button → consumed by apply_combat_results |
| `PendingCombatReports` | Queue of reports for auto-combat (border defense) | In combat.rs, used by border_defense.rs |

---

## Unit Unlock System

### Tech Tree Integration

- `TechEffect::UnlockUnit(CombatUnitType)` variant in `tech_tree.rs`
- All 14 nations have unlock effects in `tech_data.rs` at tiers T2, T3, T5, T6
- `PlayerInfo::unlocked_units()` returns `Vec<CombatUnitType>` (always includes Tier 1)
- `PlayerInfo::is_unit_unlocked()` checks if a specific unit is available

### Unlock Distribution (per nation)

| Tier | Position | Typical Units |
|---|---|---|
| T2 | Foundation node | Shieldbearer, Raider, or Marksman |
| T3 | Fork 1 (left/right) | Two of: Shieldbearer, Raider, Marksman, ChemThrower, MutantBrute |
| T5 | Shared mid-game | ChemThrower, MutantBrute, or Marksman |
| T6 | Fork 2 (left/right) | Two of: WarRig, MortarCrew, GasBomber, MutantHoundPack, StimSoldier |

Not all nations get every unit — creates strategic diversity.

### Recruitment Guards

- **Human recruitment** (node_interaction.rs): Checks `is_unit_unlocked()` before allowing recruit
- **AI recruitment** (node_interaction.rs + ai/mod.rs): Same unlock check applied

---

## Upgrade Tracks (renamed)

Legacy names → Current names:
- `FootmenAttack` → `MeleeAttack`
- `FootmenDefense` → `MeleeDefense`
- `ArchersAttack` → `RangedAttack`
- `ArchersDefense` → `RangedDefense`

These appear in `PlayerUpgrades`, `TechEffect`, `ButtonAction`, AI strategy files.

---

## Army Struct (army.rs)

```rust
pub struct Army {
    pub owner: PlayerId,
    pub units: BTreeMap<CombatUnitType, u32>,  // Per-unit-type composition
    pub target: Option<usize>,
    pub waypoints: Vec<usize>,
    // ... movement fields
}
```

Key methods:
- `total_troops()` → u32
- `apply_casualties(&BTreeMap<CombatUnitType, UnitCasualties>)` — applies combat results
- Starting garrisons use `CombatUnitType::Scavenger`

---

## Design Decisions & Constraints

1. **No graphing library** — All bar charts use pure Bevy flexbox (`Val::Percent` widths)
2. **Despawn-and-rebuild pattern** — Combat screens are idempotent (check `existing_q.is_empty()`)
3. **Phase gating** — All combat UI systems require `GamePhase::CombatResolution`
4. **Role-based counters** — 7 roles with ~30 multiplier entries, not 13×13 matrix
5. **0.3 floor** on counter multiplier — No zero-damage matchups
6. **Rout penalty** — Loser takes extra 20% casualties
7. **Upgrade bonus tracking** — `killed_by_upgrade_bonus` is subset of `killed_by`, shown as gold-bordered segments
8. **AI auto-resolve** — Only local player combats show UI
9. **BTreeMap everywhere** — Ordered iteration for deterministic rendering

---

## Current Recruitment (Keyboard)

- **R key** → Recruit `CombatUnitType::Scrapper` (ranged, Tier 1)
- **Shift+R** → Recruit `CombatUnitType::Scavenger` (melee, Tier 1)

### Known Tech Debt

- `UnitType` enum still exists in `PlayerDecision::Recruit` and `ButtonAction::RecruitFootmen`/`RecruitArchers` — needs cleanup to use `CombatUnitType` directly
- Expanded recruitment UI needed to let players choose from all unlocked units (currently only T1 via keyboard)
- AI recruitment of higher-tier unlocked units not yet implemented

---

## Adding a New Unit Type

1. Add variant to `CombatUnitType` enum in `combat.rs`
2. Add to appropriate `TIER_X` and `ALL` const arrays
3. Implement all methods: `display_name()`, `short_label()`, `combat_role()`, `tier()`, `base_attack()`, `base_defense()`, `build_turns()`, `batch_size()`, `recruit_cost()`, `bar_color()`
4. Add per-unit adjustments in `counter_multiplier()` if needed
5. Add kill attribution color in `ui_style.rs` (`COMBAT_KILL_NEWUNIT`)
6. Add color mapping in `kill_attribution_color()` in `combat_ui.rs`
7. Add `UnlockUnit` effects in relevant nation tech trees in `tech_data.rs`
8. Update `bar_color()` color grouping by role

---

## Modifying Counter Balance

1. Role-level changes: Edit `role_counter_multiplier()` in `combat.rs`
2. Unit-specific overrides: Edit the `match` in `counter_multiplier()` (per-unit adjustments)
3. Test with `cargo test -p europe-zone-control --lib` (combat tests validate counter floor, casualty capping)
4. Check that no multiplier goes below the 0.3 floor
