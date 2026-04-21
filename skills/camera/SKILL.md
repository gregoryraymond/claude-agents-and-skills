---
name: camera
description: Guide for Bevy 0.15 3D camera — orbital controls, raycasting, coordinate transforms, viewport conversion, projection. Apply when modifying camera behavior, click detection, or world-space coordinate math.
user-invocable: true
allowed-tools: Read, Grep, Bash, Edit, Write, Agent, Glob
---

# Bevy 0.15 3D Camera Reference

**Load this skill when modifying camera controls, raycasting, coordinate transforms, or viewport logic.**

---

## Spawning a Camera (0.15 Pattern)

```rust
// Camera3d auto-inserts: Camera, Projection, Transform, Tonemapping, etc.
commands.spawn((
    Camera3d::default(),
    Transform::from_xyz(10.0, 12.0, 16.0).looking_at(Vec3::ZERO, Vec3::Y),
));

// With custom projection
commands.spawn((
    Camera3d::default(),
    Projection::Perspective(PerspectiveProjection {
        fov: 60.0_f32.to_radians(),
        ..default()
    }),
    Transform::from_xyz(10.0, 12.0, 16.0).looking_at(Vec3::ZERO, Vec3::Y),
));

// Orthographic
commands.spawn((
    Camera3d::default(),
    Projection::Orthographic(OrthographicProjection {
        scaling_mode: ScalingMode::FixedVertical(16.0),
        ..OrthographicProjection::default_3d()  // NOTE: default_3d(), not default()
    }),
    Transform::from_xyz(10.0, 12.0, 16.0).looking_at(Vec3::ZERO, Vec3::Y),
));
```

**Never use `Camera3dBundle`** — it's deprecated in 0.15.

---

## Coordinate System

Bevy uses **right-handed** coordinates:
- **X** = right
- **Y** = up  
- **Z** = toward the viewer (out of screen)
- **Forward** = **-Z**

**UI coordinates:** Origin top-left, Y increases downward.

---

## Viewport-to-World Conversion

```rust
fn handle_click(
    camera_q: Query<(&Camera, &GlobalTransform)>,
    windows: Query<&Window>,
) {
    let (camera, cam_transform) = camera_q.single();
    if let Some(cursor_pos) = windows.single().cursor_position() {
        // 0.15: Returns Result, not Option
        if let Ok(ray) = camera.viewport_to_world(cam_transform, cursor_pos) {
            // ray.origin: Vec3
            // ray.direction: Dir3
            // Intersect with ground plane:
            if let Some(distance) = ray.intersect_plane(Vec3::ZERO, InfinitePlane3d::new(Vec3::Y)) {
                let world_pos = ray.get_point(distance);
            }
        }
    }
}
```

**World-to-viewport** (for UI overlays on 3D objects):
```rust
if let Ok(viewport_pos) = camera.world_to_viewport(cam_transform, world_position) {
    // viewport_pos: Vec2 in window pixel coordinates
}
```

**0.15 change:** Both methods return `Result` instead of `Option`.

---

## Raycasting for Object Selection

```rust
fn pick_object(
    camera_q: Query<(&Camera, &GlobalTransform)>,
    windows: Query<&Window>,
    meshes: Query<(&GlobalTransform, &Handle<Mesh>, Entity)>,
    mesh_assets: Res<Assets<Mesh>>,
) {
    let (camera, cam_tf) = camera_q.single();
    let Some(cursor) = windows.single().cursor_position() else { return };
    let Ok(ray) = camera.viewport_to_world(cam_tf, cursor) else { return };

    let mut closest: Option<(Entity, f32)> = None;
    for (transform, mesh_handle, entity) in &meshes {
        if let Some(mesh) = mesh_assets.get(mesh_handle) {
            if let Some([near, _far]) = mesh.compute_aabb() {
                // Test ray against AABB or mesh triangles
            }
        }
    }
}
```

**Simpler alternative:** Use `bevy_picking` (built-in in 0.15) for UI and 3D entity picking.

---

## Orbital Camera Pattern

This project's orbital camera (`camera.rs`) uses:

```rust
#[derive(Component)]
struct MapCamera {
    look_at: Vec3,      // target point
    distance: f32,      // distance from target
    pitch: f32,         // vertical angle (radians)
    yaw: f32,           // horizontal angle (radians)
}
```

**Update pattern:**
```rust
fn update_camera(mut query: Query<(&MapCamera, &mut Transform)>) {
    for (cam, mut transform) in &mut query {
        let offset = Vec3::new(
            cam.distance * cam.pitch.cos() * cam.yaw.sin(),
            cam.distance * cam.pitch.sin(),
            cam.distance * cam.pitch.cos() * cam.yaw.cos(),
        );
        transform.translation = cam.look_at + offset;
        transform.look_at(cam.look_at, Vec3::Y);
    }
}
```

### Controls Implemented

| Input | Action |
|---|---|
| WASD / Arrow keys | Pan (translate look_at) |
| Right-click drag | Pan |
| Left-click drag | Pan |
| Scroll wheel | Zoom (change distance) |
| Touch drag | Pan |
| Pinch | Zoom |

### Animated Panning

```rust
#[derive(Resource)]
struct CameraPan {
    target: Vec3,
    duration: f32,
    elapsed: f32,
}
```

Smooth interpolation from current look_at to target over duration using `Time::delta_secs()`.

---

## Zoom Implementation

| Projection | How to Zoom |
|---|---|
| Perspective | Move camera closer/farther (change distance or `Transform.translation`) |
| Orthographic | Change `OrthographicProjection.scale` (smaller = zoom in) |

**Don't** change `PerspectiveProjection.fov` for gameplay zoom — it distorts the view. FOV changes are for cinematic effects only.

---

## Multiple Cameras

```rust
// Camera render order: higher = on top
commands.spawn((
    Camera3d::default(),
    Camera { order: 0, ..default() }, // main scene
));
commands.spawn((
    Camera3d::default(),
    Camera {
        order: 1,
        clear_color: ClearColorConfig::None, // don't clear previous camera's output
        ..default()
    },
));
```

Use `Camera.is_active = false` to disable a camera without despawning.

---

## Anti-Aliasing

This project uses FXAA (configured in `main.rs`):

```rust
commands.spawn((
    Camera3d::default(),
    bevy::core_pipeline::fxaa::Fxaa::default(),
    Msaa::Off, // MSAA is off — FXAA handles AA
));
```

Options: `Msaa::Off/Sample2/Sample4/Sample8`, FXAA, TAA (temporal). MSAA is now a per-entity component in 0.15, not a global resource.

---

## Debug Features

This project's camera provides:

| Key | Action |
|---|---|
| **F2** | Screenshot to `e2e/screenshots/live_<timestamp>.png` |
| **F3** | Toggle wireframe rendering |
| **F4** | Toggle ocean visibility |

Auto-screenshots every 30s to `e2e/screenshots/auto_<N>.png` (ring buffer of 10).

---

## Performance Tips

- Use frustum culling (enabled by default) — don't render offscreen objects
- For LOD: check `camera.world_to_viewport()` distance or direct `Transform` distance
- Avoid recalculating camera matrix every frame if nothing changed — use change detection on `MapCamera`
- `viewport_to_world` / `world_to_viewport` are cheap — no need to cache

---

## This Project's Camera Architecture

- **File:** `crates/europe-zone-control/src/camera.rs`
- **Component:** `MapCamera` with look_at/distance/pitch
- **Resource:** `CameraPan` for animated panning, `DragState` for input tracking
- **Plugin:** `CameraPlugin` registered in `main.rs`
- **Input sources:** keyboard, mouse, touch (Bevy Touches), Linux evdev (custom `touch.rs`)
- **Coordinate overlay:** HUD showing world coordinates at cursor position (debug)
