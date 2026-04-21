---
name: input
description: Guide for Bevy 0.15 input handling — keyboard, mouse, touch, drag state, unified events. Apply when modifying input handling, click detection, or multi-platform input code.
user-invocable: true
allowed-tools: Read, Grep, Bash, Edit, Write, Agent, Glob
---

# Bevy 0.15 Input Handling Reference

**Load this skill when modifying input handling, click detection, drag/pinch, or multi-platform input code.**

---

## Two Approaches for Every Input Type

1. **Resource-based (polling):** Check current state via `Res<ButtonInput<T>>` — best for game logic checking specific inputs
2. **Event-based (reactive):** Read `EventReader<T>` for all activity — best for logging, input mapping, processing all inputs

---

## Keyboard

### Polling (Game Logic)
```rust
fn keyboard(keys: Res<ButtonInput<KeyCode>>) {
    if keys.just_pressed(KeyCode::Space) { /* jump */ }
    if keys.pressed(KeyCode::KeyW) { /* move forward — held */ }
    if keys.just_released(KeyCode::KeyE) { /* released this frame */ }
    if keys.any_pressed([KeyCode::ShiftLeft, KeyCode::ShiftRight]) { /* either shift */ }
}
```

Methods: `.pressed()`, `.just_pressed()`, `.just_released()`, `.get_pressed()`, `.get_just_pressed()`

### Events (Text Input)
```rust
fn text_input(mut evr: EventReader<KeyboardInput>, mut string: Local<String>) {
    for ev in evr.read() {
        if ev.state == ButtonState::Released { continue; }
        match &ev.logical_key {
            Key::Enter => { /* submit */ string.clear(); }
            Key::Backspace => { string.pop(); }
            Key::Character(input) => {
                if !input.chars().any(|c| c.is_control()) {
                    string.push_str(&input);
                }
            }
            _ => {}
        }
    }
}
```

### Physical vs Logical Keys
- `KeyCode` = physical key position (layout-independent) — use for gameplay bindings
- `Key` = logical character (OS-interpreted) — use for text input
- Both available on `KeyboardInput`: `ev.key_code` and `ev.logical_key`

---

## Mouse

### Buttons
```rust
fn mouse(buttons: Res<ButtonInput<MouseButton>>) {
    if buttons.just_pressed(MouseButton::Left) { /* click */ }
    if buttons.pressed(MouseButton::Right) { /* held */ }
}
```

### Scroll Wheel
```rust
fn scroll(mut evr: EventReader<MouseWheel>) {
    for ev in evr.read() {
        match ev.unit {
            MouseScrollUnit::Line => { /* desktop mouse, ev.y lines */ }
            MouseScrollUnit::Pixel => { /* touchpad smooth scroll, ev.y pixels */ }
        }
    }
}
```
**Pitfall:** `Line` unit values are NOT guaranteed to be whole numbers on macOS (non-linear acceleration). Handle `Line` and `Pixel` with different sensitivity.

### Mouse Motion (Delta)
```rust
fn motion(mut evr: EventReader<MouseMotion>) {
    for ev in evr.read() { /* ev.delta.x, ev.delta.y */ }
}
```
Use for camera rotation, FPS-style look. Not tied to cursor position.

### Cursor Position
```rust
fn cursor(window: Single<&Window, With<PrimaryWindow>>) {
    if let Some(pos) = window.cursor_position() {
        // pos: Vec2, window space, origin top-left
    }
}
```

**0.15:** `Single<>` replaces `Query<>.single()` for guaranteed-single queries.

---

## Touch

### Polling
```rust
fn touches(touches: Res<Touches>) {
    for finger in touches.iter() {
        if touches.just_pressed(finger.id()) { /* new touch */ }
        // finger.position(), finger.start_position(), finger.id()
    }
    for finger in touches.iter_just_released() { /* ended */ }
}
```

### Events
```rust
fn touch_events(mut evr: EventReader<TouchInput>) {
    for ev in evr.read() {
        match ev.phase {
            TouchPhase::Started => { /* ev.id, ev.position */ }
            TouchPhase::Moved => { /* dragging */ }
            TouchPhase::Ended => { /* released */ }
            TouchPhase::Canceled => { /* interrupted */ }
        }
    }
}
```

**Limitations:** No built-in gesture recognition, no trackpad finger tracking, no accelerometers/gyroscopes.

---

## Input Mapping

Bevy has **no built-in input mapping**. Options:

1. **Manual abstraction:** System reads raw input -> emits custom "action" events -> other systems consume
2. **Community:** `leafwing-input-manager` (most mature)
3. **Run conditions:** `input_just_pressed(KeyCode)` — prototyping only, no rebinding

---

## This Project's Input Architecture

### Unified Tap Event
The codebase uses a `UnifiedTapEvent` resource to normalize taps across mouse click, touch tap, and evdev touch:

```rust
#[derive(Resource, Default)]
struct UnifiedTapEvent {
    position: Option<Vec2>,  // screen position of tap this frame
}
```

### Drag State
```rust
#[derive(Resource)]
struct DragState {
    left_dragging: bool,
    right_dragging: bool,
    touch_dragging: bool,
    pinch_active: bool,
    pinch_distance: f32,
    // ... start positions, deltas
}
```

### Input Sources

| Source | File | Notes |
|---|---|---|
| Keyboard | `camera.rs` | WASD/arrows for pan, function keys for debug |
| Mouse buttons | `camera.rs`, `node_interaction.rs` | Click selection, drag pan |
| Mouse scroll | `camera.rs` | Zoom |
| Bevy Touches | `camera.rs` | Single-finger drag, two-finger pinch |
| Linux evdev | `touch.rs` | Direct `/dev/input/eventN` reading in background thread |

### Why Custom evdev Touch?
GNOME/Mutter on Wayland only provides pointer emulation for touchscreens — no raw multitouch. The custom evdev plugin reads the touchscreen device directly for proper pinch-to-zoom support on the Linux touchscreen target.

### Key Files
- `camera.rs` — All camera input handling (pan, zoom, drag, pinch)
- `node_interaction.rs` — Click raycasting for city node / army selection
- `touch.rs` — Linux evdev multitouch plugin
- `game/lobby.rs` — Keyboard shortcuts for lobby (H=host, J=join, S=start)
- `game/types.rs` — `UnifiedTapEvent`, `DragState` definitions

---

## Multi-Platform Considerations

| Platform | Input Available |
|---|---|
| **Native Linux** | Keyboard, mouse, Bevy Touches, custom evdev |
| **Native macOS/Windows** | Keyboard, mouse, Bevy Touches |

- **Focus loss:** `KeyboardFocusLost` event fires on Alt-Tab — reset multi-key tracking state.
- **IME:** For international text input, handle `KeyboardInput.logical_key` with `Key::Character` (can contain multi-char strings).

---

## Performance Tips

- Resource polling (`ButtonInput`) is O(1) lookup — fast for specific button checks
- Event reading is proportional to events per frame — fine for normal use
- For high-frequency mouse motion (camera look), process all events per frame, don't just check position
- Avoid running input systems when not needed — use run conditions gated on game phase
