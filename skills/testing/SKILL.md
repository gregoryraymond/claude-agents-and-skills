---
name: testing
description: Guide for running tests, writing tests, native Bevy UI integration testing, native E2E testing, screenshot testing, and test bridge usage in this Bevy game project. Apply when writing tests, debugging test failures, or verifying UI/gameplay changes.
user-invocable: true
allowed-tools: Read, Grep, Bash, Edit, Write, Agent, Glob
---

# Testing Guide

## Quick Reference

```bash
# Unit tests (fast, no display needed)
just test                                  # 148 tests

# Lobby server tests
just test-server                           # 12 tests

# All unit + server tests
just test-all

# Integration tests (serial, needs display + Vulkan GPU)
just test-integration

# From SSH, set display vars:
XAUTHORITY=$(ls /run/user/1000/.mutter-Xwaylandauth.*) DISPLAY=:0 \
  just test-integration

# Individual integration test binaries:
cargo test --test ui_interaction -p europe-zone-control -- --ignored --nocapture
cargo test --test hud_alignment -p europe-zone-control -- --ignored --nocapture
cargo test --test coastal_overlay -p europe-zone-control -- --ignored --nocapture
cargo test --test army_pathfinding -p europe-zone-control -- --ignored --nocapture
cargo test --test army_multi_turn_march -p europe-zone-control -- --ignored --nocapture
cargo test --test army_selection_movement -p europe-zone-control -- --ignored --nocapture

# Lobby server tests
cargo test -p lobby-server

# E2E native tests (needs running server)
GAME_URL=http://localhost:3031 LOBBY_URL=http://localhost:3031 node e2e/connection.spec.mjs

# Full E2E runner
./e2e/run-e2e.sh
```

## Test Categories

### 1. Unit Tests (`--lib`)

Location: `crates/europe-zone-control/src/game/ui_update.rs` (test modules at bottom)

- **`tests` module** (35 tests) — Happy-path logic: resource formatting, radar positioning, leaderboard sorting, rank computation, tab switching, unit card queue, army recruitment, garrison split, phase visibility
- **`adversarial_tests` module** (47 tests) — Edge cases: i32 overflow, boundary values, empty states, zero-division, double-cancel, timing, proximity thresholds

Key functions tested:
- `format_resource()` — K suffix formatting
- Radar dot positioning math (content-area centering, axis angles)
- Ring concentricity geometry
- Army `enqueue_recruitment()`, `cancel_recruitment_queue()`, `tick_recruitment_queue()`
- `ProvinceTabKind` switching logic

### 2. Native Bevy UI Integration Tests (`--test ui_interaction`)

Location: `crates/europe-zone-control/tests/ui_interaction.rs`
Harness: `crates/europe-zone-control/src/game/test_harness.rs`

In-process integration tests that run inside a real Bevy app with full rendering. The test constructs the same `App` as `main()`, adds a `TestHarness` resource, and drives the test frame-by-frame via a system in `PostUpdate`.

#### Running

```bash
# Requires display (Xwayland or native X11) + Vulkan GPU
cargo test -p europe-zone-control --test ui_interaction -- --ignored --nocapture

# From SSH, set display vars:
XAUTHORITY=$(ls /run/user/1000/.mutter-Xwaylandauth.*) DISPLAY=:0 \
  cargo test -p europe-zone-control --test ui_interaction -- --ignored --nocapture
```

- **Do NOT use `WGPU_BACKEND=gl`** — OpenGL has surface creation issues in this context. Use default Vulkan.
- First compilation takes ~6 minutes, incremental ~18s, test execution ~4s.

#### Architecture

The harness exploits Bevy's event double-buffering:
1. Driver system runs in **`PostUpdate`** (after all game systems)
2. Sends synthetic `MouseButtonInput` / `KeyboardInput` events
3. Events survive to next frame's **`PreUpdate`** where `InputSystem` picks them up
4. Game systems in **`Update`** see `just_pressed()` / `Changed<Interaction>` and react

Key implementation details:
- `WinitPlugin::run_on_any_thread = true` — required because `cargo test` runs on worker threads
- CWD set to workspace root via `CARGO_MANIFEST_DIR` — asset paths are relative to it
- `TestSpeedMultiplier(10.0)` — speeds up animations during tests
- Offline mode — no network connection needed
- `WinitSettings::Continuous` — ensures frames advance without user input

#### TestStep Reference

| Step | Description |
|------|-------------|
| `WaitFrames(u32)` | Wait N frames before next step (use 30-60 for asset loading) |
| `MoveCursor(f32, f32)` | Move cursor to logical pixel coords. Sets `Window::set_cursor_position` |
| `Click` | Left mouse press+release at current cursor position |
| `ClickAt(f32, f32)` | MoveCursor + Click in one step |
| `PressKey(KeyCode)` | Keyboard press+release (e.g. `KeyCode::KeyL`, `KeyCode::Digit5`) |
| `ClickButton(String)` | Find button by marker component name and click its center |
| `AssertPhase(String)` | Assert `GameState.phase` matches (e.g. `"Lobby"`, `"NationSelect"`) |
| `AssertFn(fn(&World) -> Result)` | **Currently skipped** — `&World` conflicts with mutable system params |
| `Screenshot(String)` | **Placeholder** — not yet wired to Bevy's screenshot system |
| `Log(String)` | Print message to stderr |

#### ClickButton Marker Names

The harness finds buttons by querying for ECS marker components:

| Marker name | Component | Notes |
|-------------|-----------|-------|
| `"LobbyMenuBtn::Local"` | `LobbyMenuBtn(LobbyMenuAction::Local)` | Main menu buttons |
| `"LobbyMenuBtn::HostGame"` | `LobbyMenuBtn(LobbyMenuAction::HostGame)` | |
| `"LobbyMenuBtn::JoinGame"` | `LobbyMenuBtn(LobbyMenuAction::JoinGame)` | |
| `"LobbyPlayerCountBtn::<N>"` | `LobbyPlayerCountBtn(N)` | e.g. `"LobbyPlayerCountBtn::2"` |
| `"LobbyBackBtn"` | `LobbyBackBtn` | Back/cancel in lobby screens |
| `"EndTurnButton"` | `EndTurnButton` | In-game end turn |
| `"PauseResumeBtn"` | `PauseResumeBtn` | Pause/resume toggle |
| `"TechButton"` | `TechButton` | Tech tree open/close |
| `"ActionButton::RecruitFootmen"` | `ActionButton { action: ButtonAction::RecruitFootmen }` | Province action buttons |
| `"ActionButton::RecruitArchers"` | `ActionButton { action: ButtonAction::RecruitArchers }` | |
| `"ActionButton::BuildTownHall"` | `ActionButton { action: ButtonAction::BuildTownHall }` | |
| `"ActionButton::BuildBarracks"` | etc. | |
| `"ActionButton::BuildMarket"` | | |
| `"ActionButton::BuildBank"` | | |
| `"ActionButton::BuildDefenses"` | | |
| `"ActionButton::BuildWonder"` | | |
| `"ActionButton::MoveAll"` | | |
| `"ActionButton::MoveHalf"` | | |

#### Writing a New Test

```rust
use europe_zone_control::game::test_harness::*;

#[test]
#[ignore] // requires GPU / display
fn my_ui_flow_test() {
    run_test("my_test_name", vec![
        TestStep::WaitFrames(60),                         // let assets load
        TestStep::AssertPhase("Lobby".into()),
        TestStep::PressKey(KeyCode::KeyL),                // keyboard shortcut
        TestStep::WaitFrames(5),
        TestStep::PressKey(KeyCode::Digit5),              // set AI count
        TestStep::WaitFrames(5),
        TestStep::AssertPhase("NationSelect".into()),
        // Or use ClickButton for mouse interaction:
        // TestStep::ClickButton("LobbyMenuBtn::Local".into()),
    ]);
}
```

#### Known Limitations

- **`AssertFn` is skipped** — `&World` access conflicts with the mutable system parameters in the driver. Future fix: use an exclusive system or split into read-only + write systems.
- **`Screenshot` is a placeholder** — needs wiring to Bevy's camera screenshot observer pattern.
- **Mouse click delivery** — `Window::set_cursor_position()` sets `internal.physical_cursor_position` for `ui_focus_system`, but `CursorMoved` events are NOT sent. If a system relies on `CursorMoved` rather than window cursor position, clicks may not register.
- **All game handlers use `Changed<Interaction>`** (legacy pattern, 17 instances) — no observer-based `Trigger<Pointer<Click>>` usage. This is compatible with the harness's synthetic input approach.
- **Single test per process** — `app.run()` takes over the winit event loop. Each `#[test]` fn is a separate process when run with `--test-threads=1` (default for `#[ignore]` tests).
- **`LobbyAiCountBtn`** — exists in `components.rs` but not yet wired into `find_button_center()`.

#### Extending the Harness

To add support for a new button marker:

1. Add a query for the marker component to the `run_test_harness` system parameters
2. Pass it to `find_button_center()`
3. Add a match arm in `find_button_center()` for the marker name string
4. Document the new marker in the table above

To add a new `TestStep` variant:

1. Add the variant to the `TestStep` enum in `test_harness.rs`
2. Add a match arm in the `run_test_harness` driver system
3. Document it in the TestStep Reference table above

### 3. Visual Alignment Tests (`--test hud_alignment`)

Location: `crates/europe-zone-control/tests/hud_alignment.rs`

These are `#[ignore]` tests that require a display. They:
1. Launch the game binary with `--quick-start --screenshot`
2. Load the JPEG screenshot
3. Analyze pixel data to verify UI component positions

**Test: `hud_visual_alignment_checks`** (6 checks):
- Radar horizontal centering (symmetry ratio)
- Leaderboard in top-left quadrant
- End Day button in bottom-right
- Resource card symmetry around radar
- Gold accents present
- No UI overflow at screen edges

**Test: `radar_detailed_visual_analysis`** (10 checks):
- Radar region detected via gold border
- Circularity (aspect ratio)
- Colored data dots (at least 3/6 detected)
- DAY text above radar
- Nation name below radar
- Resource cards flanking left and right
- Resource vertical alignment
- Gold center dot
- No dots escaping radar boundary
- Ring concentricity (vertical + horizontal symmetry)

### 5. E2E Native Tests

Location: `crates/europe-zone-control/tests/e2e/`

#### Running
```bash
# Full run (builds binary + lobby server, starts server, runs tests)
just e2e

# Quick run (assumes binary + server already running)
just e2e-quick

# Skip build only
just e2e --no-build
```

#### Writing E2E tests

Each test uses `NativeClient` (from `native_helpers.mjs`) which:
- Spawns the game binary with `--test-bridge`
- Sends actions via stdin (e.g. `client.sendAction("pick_nation:Germany")`)
- Reads state from stdout (`__TEST_STATE:{json}` lines)
- Waits for state conditions with `client.waitForState(predicate, timeoutMs)`

Test file: `game_flow_native.spec.mjs` — covers offline flow, 2-player draft, multiplayer host+join, multi-turn gameplay.

### 6. Native Screenshot Harness

```bash
# Basic screenshot
cargo run -p europe-zone-control -- --view --screenshot /path/to/output.png

# Quick-start into gameplay (for HUD testing)
cargo run -p europe-zone-control -- --quick-start --screenshot /path/to/output.png

# Custom camera
cargo run -p europe-zone-control -- --view --screenshot output.png \
  --camera-x 5 --camera-z -50 --camera-distance 25
```

From SSH, prefix with display vars:
```bash
XAUTHORITY=$(ls /run/user/1000/.mutter-Xwaylandauth.*) DISPLAY=:0 cargo run -p europe-zone-control -- ...
```

- **F2** takes a timestamped screenshot to `e2e/screenshots/live_<timestamp>.png`
- Auto-screenshots every 30s to `e2e/screenshots/auto_<N>.jpg` (ring buffer of 10)

## Test Bridge Reference

The native binary with `--test-bridge` writes `__TEST_STATE:{json}` to stdout and reads actions from stdin. Use `NativeClient` from `native_helpers.mjs` to drive it.

### Reading state
```javascript
const client = new NativeClient("./target/debug/europe-zone-control", ["--offline"]);
client.start();
const state = await client.waitForState(s => s.phase === "Lobby");
// Fields: phase, status, turn, player_count, players[], role, owned[]
```

### Sending actions
```javascript
client.sendAction("pick_nation:Germany");
```

### Available actions
| Action | Description |
|--------|-------------|
| `pick_nation:<name>` | Pick nation during draft |
| `vote_ai:<model1>,<model2>,...` | Vote for AI models |
| `host_game` | Create room (like H key) |
| `set_players:<n>` | Set player count |
| `start_game` | Start from WaitingRoom (like S key) |
| `toggle_tech` | Open/close tech tree panel |
| `take_over_slot:<id>` | Take over AI slot mid-game |
| `join_room:<code>` | Join existing room |
| `send_rejoin` | Re-send Rejoin message |

### Extending the test bridge
Add new actions in `src/game/test_bridge.rs` by matching on the command string.

## E2E Test Verification Protocol

When writing or verifying native E2E tests:

### 1. Validate state explicitly
```javascript
const state = await client.waitForState(s => s.phase === "PlayerTurn");
assert(state.player_count === 14, `Expected 14 players, got ${state.player_count}`);
assert(state.role === "Host", `Expected Host role, got ${state.role}`);
```

### 2. Don't mask failures with timeouts
- Tests must assert specific state, not just "didn't time out"
- Use `client.waitForState()` with predicates
- Check stderr output on failure (test bridge logs to stderr)

## Screenshot Verification Workflow

1. Run test, capture screenshots at key UI states
2. Read PNG screenshots directly (Claude Code can read images)
3. Use `e2e/annotate.py` for red rectangle overlays
4. Use Python/Pillow for pixel-precise analysis:
```python
from PIL import Image
img = Image.open("screenshot.png")
crop = img.crop((x1, y1, x2, y2))
crop = crop.resize((crop.width*3, crop.height*3), Image.NEAREST)
crop.save("zoomed.png")
```

## Known Limitations

- **UiScale**: `Val::Px` values are scaled by `UiScale` (1.2 in `main.rs`). Cursor coords are raw pixels. Divide by `ui_scale.0` for UI positioning.
- **Turn timer**: 30s timer runs during tests. Plan sequences to complete within it or extend via test bridge.
- **Dynamic linking**: Dev builds use `dynamic_linking` feature. When running the binary directly (not via `cargo run`), set `LD_LIBRARY_PATH` to include `target/debug/deps/`.
- **test_harness.rs**: Enabled and working. See "Native Bevy UI Integration Tests" section above for usage.
