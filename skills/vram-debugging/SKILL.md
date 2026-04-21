---
name: vram-debugging
description: Guide for diagnosing GPU memory leaks on AMD RADV integrated GPU. Covers the vram-bench tool, VRAM monitoring, Bevy change detection pitfalls, and prevention patterns. Apply when the game crashes with VRAM errors, runs slowly, or VRAM usage grows unboundedly.
user-invocable: true
allowed-tools: Read, Grep, Bash, Edit, Write, Agent, Glob
---

# VRAM Leak Debugging Guide

**Load this skill when:** the game crashes with `radv/amdgpu: Not enough memory`, VRAM grows unboundedly, or GPU-related panics occur.

## The Hardware

- **GPU:** AMD Radeon Graphics (RADV GFX1151) — integrated GPU
- **VRAM:** Shared with system RAM (~65GB available, carved from 64GB system RAM)
- **Driver:** Mesa RADV (Vulkan)
- **Key fact:** On integrated GPU, VRAM = system RAM. Running out of VRAM = running out of system RAM.

## Monitoring VRAM

```bash
# Instant reading
cat /sys/class/drm/card*/device/mem_info_vram_used | awk '{print $1/1048576 " MB"}'

# Watch live (1-second updates)
watch -n 1 'echo "VRAM: $(( $(cat /sys/class/drm/card1/device/mem_info_vram_used) / 1048576 )) MB"'

# All GPU memory counters
for f in /sys/class/drm/card1/device/mem_info_*; do echo "$(basename $f): $(( $(cat $f) / 1048576 )) MB"; done
```

Key counters:
- `mem_info_vram_used` — Main GPU memory
- `mem_info_gtt_used` — Graphics Translation Table (CPU-accessible GPU memory)
- `mem_info_vis_vram_used` — CPU-visible VRAM (= VRAM on integrated GPU)

## vram-bench Tool

Location: `crates/europe-zone-control/src/bin/vram_bench.rs`

```bash
# Run a specific layer
just vram-bench                    # All layers, 30s each
cargo run -p europe-zone-control --bin vram-bench -- --layer 2 --duration 30 --interval 2
```

Layers:
- **0** = Bare Bevy + window (baseline, ~250MB)
- **1** = + test cube (basic 3D rendering)
- **2** = + full game (GamePlugin + SeaPlugin + CameraPlugin, ~1.8GB)
- **3** = + node rendering
- **4** = + troops

**Expected results:**
- Each layer should stabilize (flat VRAM after initial spike)
- Leak rate < 1 MB/s is noise
- Leak rate > 5 MB/s is a real leak
- If VRAM grows linearly forever, something is re-uploading to GPU every frame

## The Root Cause Pattern

**Every VRAM leak in this project has been caused by the same pattern:**

1. A system takes `ResMut<GameState>` and writes to it every frame (even if the value doesn't change)
2. This triggers `resource_changed::<GameState>()`
3. `update_territory_overlay` runs (gated by `resource_changed`)
4. It calls `meshes.get_mut()` + `mesh.insert_attribute()` on 45 terrain overlay chunks
5. Each `insert_attribute` marks the mesh as changed, triggering GPU re-upload
6. 45 chunks x ~50KB each x 30fps = **~67 MB/s** of GPU memory churn
7. On AMD RADV, old GPU allocations aren't reclaimed fast enough
8. Result: **unbounded VRAM growth at 1-2 GB/s**

## Bevy Change Detection Rules

### Critical Rule: `DerefMut` = Changed

In Bevy 0.15, ANY mutable access (`DerefMut`) on `ResMut<T>`, `Mut<T>`, or `Assets<T>::get_mut()` marks the resource as changed — even if:
- The data is identical
- The operation is a no-op (`.retain()` on empty vec)
- You immediately return after the write

### Safe (do NOT trigger change detection)
```rust
game_state.phase                    // Deref (read-only) -> no change
game_state.players.len()            // Deref -> no change
let x = game_state.turn_number;     // Deref -> no change
```

### Dangerous (DO trigger change detection)
```rust
game_state.status_message = "same".into()    // DerefMut -> CHANGED even if same value
game_state.disconnected_slots.retain(...)    // DerefMut -> CHANGED even on empty vec
game_state.turn_timer += dt                  // DerefMut -> CHANGED every frame!
materials.iter_mut()                         // marks ALL materials changed
meshes.get_mut(&handle)                      // marks that mesh changed
```

### Prevention Pattern
```rust
// WRONG: triggers DerefMut every frame
pub fn bad_system(mut game_state: ResMut<GameState>) {
    game_state.timer += 0.016;  // Changed every frame!
}

// RIGHT: separate resource for per-frame data
#[derive(Resource, Default)]
pub struct MyTimer(f32);

pub fn good_system(mut timer: ResMut<MyTimer>) {
    timer.0 += 0.016;  // Only MyTimer is marked changed, not GameState
}
```

### Guard Pattern for Conditional Writes
```rust
// WRONG: retain() triggers DerefMut even on empty vec
pub fn bad_cleanup(mut game_state: ResMut<GameState>) {
    game_state.slots.retain(|s| s.active);
}

// RIGHT: check immutably first
pub fn good_cleanup(mut game_state: ResMut<GameState>) {
    if game_state.slots.is_empty() {
        return;  // No DerefMut, no change detection
    }
    game_state.slots.retain(|s| s.active);
}
```

### Text/UI Write Guard
```rust
// WRONG: unconditional write
**text = format!("Turn {}", state.turn);

// RIGHT: check first
let new_text = format!("Turn {}", state.turn);
if **text != new_text {
    **text = new_text;
}
```

## Historical Bugs Fixed

### Bug 1: `check_disconnect_timeouts` (March 2026)
- `.retain()` on empty `disconnected_slots` Vec triggered DerefMut every frame
- Fix: early return if vec is empty

### Bug 2: `update_ocean_camera` (March 2026)
- `materials.iter_mut()` every frame to pass camera position to ocean shader
- Fix: removed system, use `view.world_position` in WGSL shader instead

### Bug 3: `tick_turn_timer` (April 2026)
- `game_state.turn_timer += time.delta_secs()` every frame
- Fix: moved `turn_timer` to separate `TurnTimer` resource

## Diagnosis Checklist

When VRAM grows unboundedly:

1. **Run vram-bench layers 0-2** — if layer 2 leaks but layer 0 doesn't, it's in game code
2. **Search for `ResMut<GameState>` in Update systems** — any that write every frame are suspects
3. **Check `materials.get_mut()`** — are materials being modified every frame?
4. **Check `meshes.get_mut()`** — are meshes being modified every frame?
5. **Verify the guard on `check_disconnect_timeouts`** — the `.is_empty()` early return must be present
6. **Check `resource_changed` systems** — `update_territory_overlay`, `update_country_colors` run when `GameState` changes

## Quick Fix Verification

After fixing a suspected leak:
```bash
# Monitor VRAM for 30 seconds with full game
XAUTH=$(ls /run/user/1000/.mutter-Xwaylandauth.* | head -1)
XAUTHORITY="$XAUTH" DISPLAY=:0 cargo run -p europe-zone-control -- --quick-start --test-bridge > /dev/null 2>/dev/null &
PID=$!
for i in 5 10 15 20 25 30; do
  sleep 5
  VRAM=$(cat /sys/class/drm/card*/device/mem_info_vram_used)
  echo "t=${i}s: VRAM=$((VRAM / 1048576)) MB"
done
kill $PID 2>/dev/null
```

Expected: VRAM should stabilize within 5-10 seconds and stay flat.
Bad: VRAM grows linearly (e.g. +1GB every 5 seconds).

## GPU Error Cascade

When VRAM is exhausted, the crash follows this pattern:
1. `radv/amdgpu: Not enough memory for command submission` — GPU can't allocate command buffers
2. `Device with '' label is invalid` — wgpu device becomes invalid
3. Every Bevy render system panics (mesh allocator, cluster prep, UI, sprites, materials)
4. Game terminates with multiple panic traces

This is NOT recoverable — the only fix is to prevent the VRAM leak.
