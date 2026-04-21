---
name: ecs
description: Guide for Bevy 0.15 ECS patterns — systems, queries, resources, events, commands, change detection, observers, run conditions, system sets, and ordering. Apply when writing or modifying any Bevy system logic.
user-invocable: true
allowed-tools: Read, Grep, Bash, Edit, Write, Agent, Glob
---

# Bevy 0.15 ECS Patterns Reference

**Load this skill when writing any ECS logic** — systems, queries, resources, events, commands, state management, or system ordering.

---

## Required Components (0.15 Paradigm Shift)

Bundles are soft-deprecated. Components declare their requirements:

```rust
#[derive(Component)]
#[require(Transform, Visibility)]
struct Player;

// Spawning Player auto-inserts Transform + Visibility with defaults
commands.spawn(Player);
```

- Spawning `Camera3d::default()` auto-inserts Camera, Projection, Transform, etc.
- Spawning `Mesh3d(handle)` + `MeshMaterial3d(handle)` replaces `PbrBundle`
- Spawning `PointLight { .. }` auto-inserts Transform + Visibility

**Rule:** Never use `*Bundle` types. Spawn the primary component directly.

---

## Systems

Systems are plain Rust functions with special parameter types:

```rust
fn my_system(
    res: Res<MyResource>,            // read-only resource
    mut res2: ResMut<OtherResource>, // mutable resource
    query: Query<&Transform>,        // component query
    mut commands: Commands,          // deferred mutations
    mut events: EventWriter<MyEvent>,// send events
    reader: EventReader<MyEvent>,    // receive events
    time: Res<Time>,                 // built-in time resource
) { /* ... */ }
```

**Max 16 parameters.** Target **5 or fewer**. If you have **more than 5**, consider using `#[derive(SystemParam)]` bundles. If you have **10 or more**, you **MUST** use SystemParam bundles — see the SystemParam Bundling section below.

### Registration

```rust
app.add_systems(Startup, setup);              // runs once
app.add_systems(Update, (sys_a, sys_b));      // every frame
app.add_systems(FixedUpdate, physics_step);   // fixed timestep
app.add_systems(OnEnter(MyState::X), setup);  // state entry
app.add_systems(OnExit(MyState::X), cleanup); // state exit
```

### Ordering

```rust
app.add_systems(Update, (
    input_handling,
    player_movement.after(input_handling).before(collision),
    collision,
    // Chain = sequential ordering
    (spawn, animate, cleanup).chain(),
));
```

- Default order is **nondeterministic** — Bevy parallelizes freely
- Use `.before()` / `.after()` only when order matters
- `.chain()` is sugar for sequential before/after on a tuple
- Over-constraining reduces parallelism — leave ambiguous when safe

### Exclusive Systems

```rust
fn my_exclusive(world: &mut World) {
    // Full direct access — blocks ALL other systems
}
```

Use only when you need full World access. Prefer normal systems + Commands.

### One-Shot Systems

```rust
let id: SystemId = app.register_system(my_fn);
commands.run_system(id);  // deferred execution
```

Good for button callbacks, item activations, infrequent events. Requires exclusive World access.

---

## SystemParam Bundling (Reducing Parameter Counts)

**Target: 5 parameters per system, ideally fewer. Systems with 10+ parameters MUST be refactored.**

Use `#[derive(SystemParam)]` to group related queries and resources into reusable bundles. This improves readability, enforces domain boundaries, and makes systems easier to maintain.

### Basic Pattern

```rust
use bevy::ecs::system::SystemParam;

/// Queries for the waiting room UI panel.
#[derive(SystemParam)]
pub(crate) struct WaitingRoomQueries<'w, 's> {
    /// The waiting room panel entity.
    pub panel: Query<'w, 's, Entity, With<WaitingRoomPanel>>,

    /// The lobby panel entity (cleaned up on transition).
    pub lobby_panel: Query<'w, 's, Entity, With<LobbyPanel>>,

    /// Start button interaction.
    pub start_btn: Query<'w, 's, &'static Interaction, With<WaitingRoomStartBtn>>,
}

// Before: 10 params
// After: 7 params — 3 queries bundled into `ui`
fn waiting_room_system(
    mut commands: Commands,
    input: InputParams,
    mut game_state: ResMut<GameState>,
    net_state: Res<crate::net::NetworkState>,
    server_url: Option<Res<crate::net::LobbyServerUrl>>,
    ui: WaitingRoomQueries,
    mut last_slot_names: Local<Vec<String>>,
) {
    // Access via: ui.panel, ui.lobby_panel, ui.start_btn
    for entity in &ui.lobby_panel {
        commands.entity(entity).despawn_recursive();
    }
}
```

### Placement Rules

**Cross-cutting bundles** (reused across 2+ files) go in a shared module:
- Location: `game/ui/system_params.rs`
- Examples: `InputParams`, `CameraWindowParams`, `DraftParams`, `PanelCleanupParams`

**Panel-specific bundles** (used by a single system) are co-located in the same file as the system:
- Examples: `WaitingRoomQueries` in `waiting_room.rs`, `PauseMenuButtons` in `misc.rs`

### Visibility

All `SystemParam` structs and their fields must be `pub(crate)`. Bevy's derive macro generates code that crosses module boundaries, so `pub(super)` or private visibility will cause compilation errors.

```rust
#[derive(SystemParam)]
pub(crate) struct MyParams<'w, 's> {
    pub country_q: Query<'w, 's, &'static Country>,         // pub field
    pub game_state: Res<'w, GameState>,                      // pub field
}
```

### Lifetime Conventions

- Queries take `<'w, 's>` (world and system state lifetimes)
- `Res<T>` and `ResMut<T>` take only `<'w>`
- `Option<Res<T>>` takes only `<'w>`
- `Local<T>` takes only `<'s>`
- The struct itself must carry all lifetimes used by its fields

```rust
#[derive(SystemParam)]
pub(crate) struct TerrainResources<'w> {
    pub heightmap: Res<'w, HeightmapData>,
    pub terrain_map: Option<Res<'w, TerrainCountryMap>>,
    pub coastal_band: Option<Res<'w, CoastalBand>>,
}
```

### Component References in Queries

Use `&'static` for component references inside SystemParam queries:

```rust
#[derive(SystemParam)]
pub(crate) struct MyParams<'w, 's> {
    pub health: Query<'w, 's, &'static Health, With<Player>>,
    pub names: Query<'w, 's, (&'static Name, &'static mut Transform)>,
}
```

### When to Bundle vs. Leave Separate

**Bundle these** — queries targeting the same UI panel, related marker components, or domain-grouped resources:
```rust
// Good: 3 queries all targeting pause menu buttons
#[derive(SystemParam)]
pub(crate) struct PauseMenuButtons<'w, 's> {
    pub resume: Query<'w, 's, &'static Interaction, With<PauseResumeBtn>>,
    pub forfeit: Query<'w, 's, &'static Interaction, With<PauseForfeitBtn>>,
    pub quit: Query<'w, 's, &'static Interaction, With<PauseQuitBtn>>,
}
```

**Leave separate** — `Commands`, `EventWriter`, `EventReader`, `ResMut<GameState>`, and other params that are semantically independent and used individually:
```rust
// Don't bundle these — they're unrelated and independently used
fn my_system(
    mut commands: Commands,
    mut game_state: ResMut<GameState>,
    time: Res<Time>,
    ui: MyPanelQueries,  // <-- this is the bundle
) { }
```

### Existing Cross-Cutting Bundles

These live in `game/ui/system_params.rs` and are available for reuse:

| Bundle | Fields | Use case |
|---|---|---|
| `InputParams<'w>` | `mouse`, `keys`, `touches`, `tap` | Unified input (mouse/keyboard/touch) |
| `CameraWindowParams<'w, 's>` | `windows`, `camera`, `camera_tf` | Camera + window queries for raycasting |
| `DraftParams<'w, 's>` | `countries`, `city_nodes`, `info_panel_q`, `confirm_q`, `draft_selection`, `fonts`, `asset_server`, `turn_timer` | Nation draft phase |
| `PanelCleanupParams<'w, 's>` | `lobby_panel_q`, `info_panel_q`, `banner_q`, `ai_vote_panel_q`, `summary_children_q` | Phase panel cleanup |
| `ResourceDisplayTexts<'w, 's>` | 9 queries | HUD resource display |
| `RankBadgeTexts<'w, 's>` | 6 queries | Rank badge display |

---

## Queries

```rust
// Basic iteration
fn system(query: Query<(&Health, &mut Transform, Option<&Player>)>) {
    for (health, mut transform, player) in &query { /* ... */ }
}

// With filters
fn system(query: Query<&Health, (With<Player>, Without<Enemy>)>) { }

// Single entity (panics if not exactly one)
fn system(query: Query<&Transform, With<Player>>) {
    let transform = query.single();
}

// Safe single
fn system(query: Query<&Transform, With<Player>>) {
    if let Ok(transform) = query.get_single() { /* ... */ }
}

// Specific entity by ID
fn system(query: Query<&Health>) {
    if let Ok(health) = query.get(entity_id) { /* ... */ }
}
```

### Query Filters

| Filter | Purpose |
|---|---|
| `With<T>` | Entity must have T (no data access — faster than `&T` when data not needed) |
| `Without<T>` | Entity must NOT have T |
| `Added<T>` | Component was added this frame |
| `Changed<T>` | Component was mutated this frame (includes Added) |
| `Or<(A, B)>` | Match either filter |

### Performance Rules

- Use `With<T>` instead of `&T` when you don't need the data
- Prefer `&` over `&mut` — maximizes parallelism
- Only request components you need — wider queries = more data access
- Two `&mut` queries on the same component in one system **panic at runtime** unless disambiguated with `Without<>`

### ParamSet (Conflicting Queries)

```rust
fn system(mut set: ParamSet<(
    Query<&mut Health, With<Enemy>>,
    Query<&mut Health, With<Player>>,
)>) {
    for mut hp in set.p0().iter_mut() { hp.0 = 50.0; }
    // p0 borrow dropped before accessing p1
    for mut hp in set.p1().iter_mut() { hp.0 = 100.0; }
}
```

Only one parameter accessible at a time (borrow checker enforced). Max 8.

---

## Commands (Deferred Mutations)

```rust
fn system(mut commands: Commands) {
    // Spawn
    let entity = commands.spawn((ComponentA, ComponentB)).id();

    // Modify
    commands.entity(entity).insert(NewComponent).remove::<OldComponent>();

    // Despawn (recursive by default in 0.15)
    commands.entity(entity).despawn();

    // Resources
    commands.insert_resource(MyResource::new());
    commands.init_resource::<MyResource>(); // uses Default/FromWorld
}
```

**Commands are deferred** — not applied until the next sync point:
- Bevy auto-inserts sync points between `.before()`/`.after()` ordered systems
- Without ordering, commands may not be visible until next frame
- Always applied at end of each schedule

---

## Resources

```rust
#[derive(Resource)]
struct GameConfig { difficulty: u32 }

fn system(config: Res<GameConfig>) { }         // read-only
fn system(mut config: ResMut<GameConfig>) { }  // mutable
fn system(config: Option<Res<GameConfig>>) { } // safe if missing
```

- `app.insert_resource(value)` — explicit value
- `app.init_resource::<T>()` — uses Default or FromWorld
- Use resources for truly global data (settings, caches, external state)
- For "singleton" game objects, prefer entity + marker component

---

## Events

```rust
#[derive(Event)]
struct DamageEvent { entity: Entity, amount: f32 }

// Send
fn sender(mut writer: EventWriter<DamageEvent>) {
    writer.send(DamageEvent { entity, amount: 10.0 });
}

// Receive
fn receiver(mut reader: EventReader<DamageEvent>) {
    for event in reader.read() { /* handle */ }
}

// Register
app.add_event::<DamageEvent>();
```

**Event lifecycle:**
- Events persist for **2 frame updates**, then auto-cleared
- Each `EventReader` independently tracks read position
- Sending is a Vec push — very fast

**Pitfalls:**
- **1-frame lag**: If receiver runs before sender (no ordering), events missed until next frame. Use `.after()`.
- **Run condition gaps**: If a system is gated by a run condition and doesn't run for 2+ frames, events are lost. Use manual event clearing for long-lived events.
- Forgetting `app.add_event::<T>()` — events silently won't work

---

## Change Detection

```rust
// Query filter
fn system(query: Query<&Name, Changed<Health>>) { }

// Manual check via Ref<T>
fn system(query: Query<Ref<Health>>) {
    for health in &query {
        if health.is_changed() { /* ... */ }
        if health.is_added() { /* ... */ }
    }
}

// Resource
fn system(res: Res<MyResource>) {
    if res.is_changed() { /* ... */ }
}

// Removal detection
fn system(mut removals: RemovedComponents<MyComponent>) {
    for entity in removals.read() { /* entity had component removed or was despawned */ }
}
```

**How it works:**
- Triggered by `DerefMut` — holding `&mut` without mutating does NOT trigger
- But calling any function taking `&mut T` WILL trigger, even without mutation
- Bevy does NOT compare values — any `DerefMut` = "changed"
- **Always check equality before assignment** to avoid false triggers and unnecessary downstream work

**This project's pattern** (from `ui_update.rs`): Explicit `!=` guards before Text/Node mutations to avoid spurious GPU re-uploads.

---

## Observers (Reactive Systems)

```rust
// Global observer
app.add_observer(|trigger: Trigger<Explode>, query: Query<&Name>| {
    println!("Entity {:?} exploded!", trigger.entity());
});

// Entity-targeted
commands.spawn((
    Enemy,
    Observer::new(|trigger: Trigger<OnDeath>| { /* ... */ }),
));
```

**Built-in triggers:** `OnAdd`, `OnInsert`, `OnRemove`, `OnReplace`

- Zero per-frame cost when not triggered
- Better than polling systems for rare events
- Support full system parameters (queries, resources, commands)
- First parameter MUST be `Trigger<E>`

---

## Run Conditions

```rust
fn alive(query: Query<&Health, With<Player>>) -> bool {
    query.single().hp > 0.0
}

app.add_systems(Update, gameplay.run_if(alive));
app.configure_sets(Update, MySet.run_if(alive));
```

- Must return `bool`
- Parameters must be **read-only** (no `ResMut`, no `&mut` queries)
- Multiple conditions are ANDed
- Built-in: `resource_exists::<T>`, `resource_changed::<T>`, `in_state(S)`, `on_event::<T>()`, `input_just_pressed(KeyCode)`

---

## System Sets

```rust
#[derive(SystemSet, Debug, Clone, PartialEq, Eq, Hash)]
enum GameSet { Input, Physics, Render }

app.configure_sets(Update, (
    GameSet::Input.before(GameSet::Physics),
    GameSet::Physics.before(GameSet::Render),
));
app.add_systems(Update, move_player.in_set(GameSet::Physics));
```

**Critical:** Set configuration is **per-schedule**. Configuring in `Update` does NOT carry to `FixedUpdate` or `OnEnter`.

---

## Schedule Hierarchy

**Startup (once):** `PreStartup` -> `Startup` -> `PostStartup`

**Per-frame:** `First` -> `PreUpdate` -> `StateTransition` -> `RunFixedMainLoop` -> `Update` -> `PostUpdate` -> `Last`

**Fixed timestep (0-N per frame):** `FixedFirst` -> `FixedPreUpdate` -> `FixedUpdate` -> `FixedPostUpdate` -> `FixedLast`

---

## States (Bevy Built-in)

```rust
#[derive(States, Debug, Clone, PartialEq, Eq, Hash)]
enum AppState { Loading, Menu, InGame }

app.insert_state(AppState::Loading);
app.add_systems(Update, game_logic.run_if(in_state(AppState::InGame)));
app.add_systems(OnEnter(AppState::InGame), spawn_world);
app.add_systems(OnExit(AppState::InGame), despawn_world);

// Transition
fn change_state(mut next: ResMut<NextState<AppState>>) {
    next.set(AppState::InGame);
}
```

**StateScoped** — auto-despawn entities on state exit:
```rust
commands.spawn((MyComponent, StateScoped(AppState::InGame)));
```

**Note:** This project uses a custom `GamePhase` enum in `GameState` resource instead of Bevy States. See `/game-state` skill.

---

## This Project's ECS Patterns

Key patterns used in this codebase:

1. **Phase-gated systems:** `run_if(in_phase_fn(|p| matches!(p, GamePhase::X)))` — custom closures checking `GameState.phase`
2. **Change detection guards:** Explicit `!=` checks before mutations in `ui_update.rs`
3. **SystemParam bundles:** `#[derive(SystemParam)]` structs to keep system parameter counts under 5. Cross-cutting bundles in `system_params.rs`, panel-specific bundles co-located in the file that uses them. See the SystemParam Bundling section above.
4. **Plugin-per-domain:** `GamePlugin`, `CameraPlugin`, `TroopsPlugin`, `SeaPlugin`, etc.
5. **Marker components:** ~60+ UI marker components in `components.rs` for targeted query updates
6. **Resource-heavy state:** `GameState` is a large resource containing players, phase, action queue, movement orders, combat state, etc.
