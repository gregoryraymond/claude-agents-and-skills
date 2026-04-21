---
name: animation
description: Guide for Bevy 0.15 animation — AnimationGraph, AnimationPlayer, skeletal animation, transitions, procedural animation. Apply when modifying soldier animations, day/night cycle, or any animated behavior.
user-invocable: true
allowed-tools: Read, Grep, Bash, Edit, Write, Agent, Glob
---

# Bevy 0.15 Animation Reference

**Load this skill when modifying animations — soldier models, day/night cycle, UI transitions, or any animated behavior.**

---

## Animation System Overview (0.15)

Bevy 0.15 introduced `AnimationGraph` for blending and transitioning between clips. This replaces direct AnimationPlayer clip management for complex setups.

### Core Types

| Type | Purpose |
|---|---|
| `AnimationPlayer` | Component that drives playback on an entity |
| `AnimationGraph` | Asset defining blend tree of animation nodes |
| `AnimationNodeIndex` | Index into the graph (returned when adding clips) |
| `AnimationTransitions` | Component enabling smooth blending between clips |
| `AnimationClip` | Asset containing keyframe data |

---

## AnimationGraph Pattern

```rust
// Build the graph
let (graph, node_indices) = AnimationGraph::from_clips([
    idle_clip.clone(),
    walk_clip.clone(),
    attack_clip.clone(),
]);

// Store the graph as an asset
let graph_handle = graphs.add(graph);

// The entity with AnimationPlayer gets the graph
commands.entity(player_entity).insert((
    AnimationGraphHandle(graph_handle),
    AnimationTransitions::new(),
));
```

### Playing Animations

```rust
fn play_animation(
    mut players: Query<(&mut AnimationPlayer, &mut AnimationTransitions)>,
    indices: Res<MyAnimationIndices>,
) {
    for (mut player, mut transitions) in &mut players {
        // Transition to walk with 0.3s blend
        transitions
            .play(&mut player, indices.walk, Duration::from_secs_f32(0.3))
            .repeat();
    }
}
```

### AnimationPlayer API

| Method | Purpose |
|---|---|
| `.play(index)` | Start playing a clip node |
| `.repeat()` | Loop the current animation |
| `.set_speed(f32)` | Playback speed multiplier |
| `.pause()` / `.resume()` | Pause/resume |
| `.is_playing_clip(handle)` | Check what's playing |
| `.elapsed()` | Current time |
| `.seek_to(f32)` | Jump to specific time |

---

## Skeletal Animation from GLTF

```rust
// Load model with animations
let scene = asset_server.load("models/soldier.glb#Scene0");
let idle = asset_server.load("models/soldier.glb#Animation0");
let walk = asset_server.load("models/soldier.glb#Animation1");
let attack = asset_server.load("models/soldier.glb#Animation2");

// After scene is spawned, find the AnimationPlayer entity
// (usually a child of the root scene entity)
fn setup_animations(
    mut commands: Commands,
    players: Query<Entity, Added<AnimationPlayer>>,
    mut graphs: ResMut<Assets<AnimationGraph>>,
) {
    for entity in &players {
        let (graph, indices) = AnimationGraph::from_clips([
            idle_clip.clone(), walk_clip.clone(), attack_clip.clone(),
        ]);
        commands.entity(entity).insert((
            AnimationGraphHandle(graphs.add(graph)),
            AnimationTransitions::new(),
        ));
    }
}
```

**Key pattern:** The `AnimationPlayer` is usually on a **child entity** of the scene root, not the root itself. Query for `Added<AnimationPlayer>` to find it after the scene loads.

---

## Procedural Animation

For non-skeletal animation (transforms, colors, scales):

```rust
fn animate_bounce(
    time: Res<Time>,
    mut query: Query<&mut Transform, With<Bouncing>>,
) {
    for mut transform in &mut query {
        transform.translation.y = (time.elapsed_secs() * 2.0).sin() * 0.5;
    }
}
```

### Timer-Based Animation
```rust
#[derive(Component)]
struct AnimTimer(Timer);

fn tick_animation(
    time: Res<Time>,
    mut query: Query<(&mut AnimTimer, &mut Sprite)>,
) {
    for (mut timer, mut sprite) in &mut query {
        timer.0.tick(time.delta());
        if timer.0.just_finished() {
            // Advance sprite frame, change state, etc.
        }
    }
}
```

### Tweening (No Built-in)
Bevy has no built-in tweening. Options:
- **Manual:** Lerp values in systems using `Time::delta_secs()`
- **Community:** `bevy_tweening` crate for declarative tweens
- **Timer-based:** `Timer` + easing functions

---

## This Project's Animation Architecture

### Soldier Animations (`troops.rs`)

Five animation nodes per soldier entity:
1. **Idle** — default standing pose
2. **Walk** — marching movement
3. **Sit** — resting/encamped
4. **Pick_up** — building/constructing
5. **Attack** — combat strike

**Animation graph structure:**
```
AnimationGraph
├── Node 0: Idle
├── Node 1: Walk
├── Node 2: Sit
├── Node 3: Pick_up
└── Node 4: Attack
```

**State transitions:**
- `Marching` state → Walk animation
- `Encamped` state → Idle animation
- `ActionAnimation` phase → Attack animation (during combat)
- Building action → Pick_up animation

**Player-color tinting:** After spawning a soldier GLB, the system traverses mesh children and applies player color to `StandardMaterial.base_color`.

### Day/Night Cycle (`map.rs`)

Animated `SunLight` component:
- `DirectionalLight` rotation orbits around the map
- Color temperature shifts (warm sunrise → neutral noon → cool sunset)
- `AmbientLight` brightness varies with sun angle
- Cycle driven by `Time::elapsed_secs()` with configurable period

### Animation Phase Flow

During `GamePhase::ActionAnimation` (2-5 seconds):
1. Armies with movement orders play **Walk** animation and lerp position
2. Armies attacking play **Attack** animation
3. Building actions play **Pick_up** animation
4. Timer expires → transition to `CombatResolution`

### Key Files
- `troops.rs` — `TroopsPlugin`, soldier model spawning, animation graph setup, tinting, march/attack animation systems
- `map.rs` — `SunLight` component, day/night cycle system
- `game/army.rs` — Army entity state (Marching/Encamped), visual state updates
- `game/mod.rs` — `ActionAnimation` phase systems registration

---

## Performance Tips

- Animation systems run in `PostUpdate` — don't fight the schedule
- For many animated entities, skeletal animation is GPU-accelerated
- Avoid playing the same animation transition every frame — check if already playing before calling `transitions.play()`
- Use `AnimationTransitions` for smooth blends instead of hard-cutting between clips
- Sprite sheet animation is CPU-side — scales linearly with entity count
