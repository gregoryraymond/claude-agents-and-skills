---
name: assets
description: Guide for Bevy 0.15 asset system — loading, GLTF/GLB models, textures, fonts, handles, hot-reload. Apply when loading assets, managing handles, or debugging missing/broken assets.
user-invocable: true
allowed-tools: Read, Grep, Bash, Edit, Write, Agent, Glob
---

# Bevy 0.15 Asset System Reference

**Load this skill when loading assets, managing handles, working with GLTF models, or debugging asset issues.**

---

## Core Types

| Type | Purpose |
|---|---|
| `AssetServer` (Resource) | Loads assets asynchronously from files |
| `Assets<T>` (Resource) | Typed collection of loaded assets, indexed by `AssetId` |
| `Handle<T>` | Reference-counted ID pointing to an asset |
| `AssetPath` | Virtual filesystem path (`"folder/file.ext"` or `"path/file.ext#Label"`) |

---

## Loading Assets

```rust
fn setup(asset_server: Res<AssetServer>) {
    let font: Handle<Font> = asset_server.load("fonts/heading.ttf");
    let texture: Handle<Image> = asset_server.load("textures/grass.png");
    let scene: Handle<Scene> = asset_server.load("models/tree.glb#Scene0");
}
```

**Key facts:**
- `load()` is **async and non-blocking** — asset not available immediately
- `load()` is **idempotent** — same path returns same handle without re-loading
- Assets are in `assets/` folder at the repo root

### Checking Load State
```rust
if asset_server.is_loaded_with_dependencies(&handle) { /* ready */ }
```

### Accessing Loaded Data
```rust
fn use_asset(textures: Res<Assets<Image>>, my_handle: Res<MyTextureHandle>) {
    if let Some(image) = textures.get(&my_handle.0) { /* use it */ }
}
```

---

## Handles: Strong vs Weak

```rust
let strong = handle.clone();       // Increments ref count — keeps asset alive
let weak = handle.clone_weak();    // Does NOT keep asset alive
```

**Critical rule:** Assets are automatically unloaded when all strong handles are dropped. If you forget to store a handle, the asset gets unloaded immediately.

**Pattern:** Store handles in resources:
```rust
#[derive(Resource)]
struct GameAssets {
    font: Handle<Font>,
    soldier_scene: Handle<Scene>,
}
```

---

## Procedural Assets

```rust
fn create_mesh(mut meshes: ResMut<Assets<Mesh>>) {
    let handle: Handle<Mesh> = meshes.add(my_custom_mesh);
}

fn create_material(mut materials: ResMut<Assets<StandardMaterial>>) {
    let handle = materials.add(StandardMaterial {
        base_color: Color::srgb(0.8, 0.2, 0.1),
        ..default()
    });
}
```

---

## GLTF / GLB Loading

### Quick Spawn (Scene)
```rust
commands.spawn((
    SceneRoot(asset_server.load("models/soldier.glb#Scene0")),
    Transform::from_xyz(2.0, 0.0, -5.0),
));
```

### GLTF Sub-Asset Labels

| Label | Bevy Type |
|---|---|
| `Scene{N}` | `Scene` |
| `Node{N}` | ECS entity hierarchy |
| `Mesh{N}/Primitive{N}` | `Mesh` |
| `Texture{N}` | `Image` |
| `Material{N}` | `StandardMaterial` |
| `Animation{N}` | `AnimationClip` |
| `InverseBindMatrices{N}` | (renamed from `Skin` in 0.15) |

### Advanced: Navigate GLTF Contents
```rust
#[derive(Resource)]
struct MyModel(Handle<Gltf>);

fn use_model(
    model: Res<MyModel>,
    gltf_assets: Res<Assets<Gltf>>,
    gltf_meshes: Res<Assets<GltfMesh>>,
) {
    if let Some(gltf) = gltf_assets.get(&model.0) {
        let scene = gltf.scenes[0].clone();           // by index
        let named = gltf.named_scenes["MyScene"].clone(); // by name
        let mesh = gltf_meshes.get(&gltf.named_meshes["Wheel"]).unwrap();
        let bevy_mesh = mesh.primitives[0].mesh.clone();
    }
}
```

### Texture Recommendations
- PNG/JPEG work out of the box but lack mipmaps and GPU compression
- **KTX2 with zstd** is recommended for production (enable `ktx2` + `zstd` features)
- Missing mipmaps = grainy/noisy textures at distance
- Textures embedded in ASCII `.gltf` (base64) CANNOT be loaded — use `.glb`
- Export tangents from 3D editor for normal maps (avoids runtime generation)

---

## Meshes from Code

### Creating
```rust
let mesh = Mesh::new(PrimitiveTopology::TriangleList, RenderAssetUsages::default())
    .with_inserted_attribute(Mesh::ATTRIBUTE_POSITION, positions)  // Vec<[f32; 3]>
    .with_inserted_attribute(Mesh::ATTRIBUTE_NORMAL, normals)      // Vec<[f32; 3]>
    .with_inserted_attribute(Mesh::ATTRIBUTE_UV_0, uvs)            // Vec<[f32; 2]>
    .with_inserted_indices(Indices::U32(indices));                  // Vec<u32>
```

### Standard Vertex Attributes

| Constant | Type | Required For |
|---|---|---|
| `ATTRIBUTE_POSITION` | Float32x3 | Always required |
| `ATTRIBUTE_NORMAL` | Float32x3 | Lighting (without = black mesh) |
| `ATTRIBUTE_UV_0` | Float32x2 | Textured materials |
| `ATTRIBUTE_TANGENT` | Float32x4 | Normal maps |
| `ATTRIBUTE_COLOR` | Float32x4 | Per-vertex coloring |
| `ATTRIBUTE_JOINT_INDEX` | Uint16x4 | Skeletal animation |
| `ATTRIBUTE_JOINT_WEIGHT` | Float32x4 | Bone weights |

### Auto-Compute Normals
```rust
mesh.compute_flat_normals();   // Hard edges
mesh.compute_smooth_normals(); // Smooth shading
```

### Spawning (0.15)
```rust
commands.spawn((
    Mesh3d(meshes.add(mesh)),
    MeshMaterial3d(materials.add(StandardMaterial::default())),
    Transform::from_xyz(0.0, 0.5, 0.0),
));
```

### Built-in Primitives
```rust
meshes.add(Cuboid::new(1.0, 1.0, 1.0));
meshes.add(Sphere::new(0.5));
meshes.add(Capsule3d::default());
meshes.add(Plane3d::default().mesh().size(10.0, 10.0));
meshes.add(Cylinder::new(0.5, 2.0));
```

### Mesh Pitfalls
- **No normals** = black/unlit mesh
- **Wrong winding order** = invisible faces (culled). Counter-clockwise = front face.
- **Missing UVs** with textured material = undefined behavior
- **Missing tangents** = broken normal maps
- **UV convention:** Top-left origin `[0.0, 0.0]` (unlike OpenGL's bottom-left)
- Modified meshes need manual `Aabb` recalculation for frustum culling

---

## Hot Reloading

Enable `file_watcher` feature for automatic reload during development. Changes to asset files are picked up automatically.

This project's shaders hot-reload on save — see `/wgsl-shaders` skill.

---

## This Project's Asset Structure

```
assets/
├── shaders/          # WGSL shaders (5 files, hot-reload)
│   ├── ocean_material.wgsl
│   ├── sea_material.wgsl
│   ├── coast_material.wgsl
│   ├── terrain_material.wgsl
│   └── fog_material.wgsl
├── textures/         # Texture maps
│   ├── ocean_normal.png
│   ├── shore_foam.png
│   ├── sand_color.png, sand_normal.png
│   └── rock_color.png, rock_normal.png
├── icons/            # UI icons (~25 PNGs)
├── fonts/            # heading.ttf (Cinzel), body.ttf (Source Sans Pro)
├── models/           # GLB models (soldier, tower, tent)
├── terrain/          # Generated terrain chunk GLBs
├── satellite_*.png   # Satellite texture tiles
├── heightmap.bin     # Embedded 512x320 u8 heightmap
└── bathymetry.png    # Ocean depth map
```

**Key resources:**
- `GameFonts` — stores heading + body font handles
- `HeightmapData` — loaded from embedded binary in `heightmap.rs`
- Soldier GLBs loaded in `troops.rs` with animation clips
- Terrain chunk GLBs loaded in `map.rs`
