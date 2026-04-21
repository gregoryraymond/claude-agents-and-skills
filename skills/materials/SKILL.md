---
name: materials
description: Guide for Bevy 0.15 materials — StandardMaterial, custom Material trait, AsBindGroup, vertex attributes, shader binding groups. Apply when creating or modifying materials, custom shaders, or rendering pipeline code.
user-invocable: true
allowed-tools: Read, Grep, Bash, Edit, Write, Agent, Glob
---

# Bevy 0.15 Materials Reference

**Load this skill when creating or modifying materials, custom shaders, or rendering pipeline code.**

---

## StandardMaterial (Key Fields)

```rust
StandardMaterial {
    base_color: Color::WHITE,
    base_color_texture: Option<Handle<Image>>,
    emissive: LinearRgba::BLACK,
    emissive_texture: Option<Handle<Image>>,
    perceptual_roughness: 0.5,       // 0 = mirror, 1 = rough
    metallic: 0.0,                    // 0 = dielectric, 1 = metal
    metallic_roughness_texture: Option<Handle<Image>>,
    reflectance: 0.5,
    normal_map_texture: Option<Handle<Image>>,
    flip_normal_map_y: false,         // true for DirectX-style normals
    occlusion_texture: Option<Handle<Image>>,
    double_sided: false,
    cull_mode: Some(Face::Back),      // None = no culling
    unlit: false,                     // true = ignore lighting
    fog_enabled: true,
    alpha_mode: AlphaMode::Opaque,    // Opaque, Mask(f32), Blend, etc.
    depth_bias: 0.0,
    // Also: clearcoat, anisotropy, transmission, thickness, IOR, parallax, UV transform
}
```

### Quick Creation
```rust
// From color
let mat = StandardMaterial::from(Color::srgb(1.0, 0.0, 0.0));

// With texture
let mat = StandardMaterial {
    base_color_texture: Some(asset_server.load("texture.png")),
    ..default()
};
```

### Spawning (0.15)
```rust
commands.spawn((
    Mesh3d(meshes.add(Cuboid::default())),
    MeshMaterial3d(materials.add(StandardMaterial {
        base_color: Color::srgb(0.8, 0.2, 0.1),
        metallic: 0.8,
        ..default()
    })),
    Transform::from_xyz(0.0, 0.5, 0.0),
));
```

**0.15 change:** `MeshMaterial3d(handle)` replaces direct `Handle<StandardMaterial>` component.

---

## Custom Material Trait

```rust
#[derive(AsBindGroup, Debug, Clone, Asset, TypePath)]
pub struct MyMaterial {
    #[uniform(0)]
    color: LinearRgba,
    #[texture(1)]
    #[sampler(2)]
    color_texture: Handle<Image>,
}

impl Material for MyMaterial {
    fn fragment_shader() -> ShaderRef {
        "shaders/my_material.wgsl".into()
    }
    fn alpha_mode(&self) -> AlphaMode { AlphaMode::Opaque }
    // Optional: fn vertex_shader() -> ShaderRef { ... }
    // Optional: fn specialize(...) -> Result<(), ...> { ... }
}

// Register plugin
app.add_plugins(MaterialPlugin::<MyMaterial>::default());

// Spawn
commands.spawn((
    Mesh3d(meshes.add(Capsule3d::default())),
    MeshMaterial3d(materials.add(MyMaterial {
        color: LinearRgba::RED,
        color_texture: asset_server.load("texture.png"),
    })),
));
```

---

## AsBindGroup Attributes

### Field-Level

| Attribute | Usage |
|---|---|
| `#[uniform(N)]` | Bind as uniform buffer (type must impl `ShaderType`) |
| `#[texture(N)]` | Bind `Handle<Image>` as texture |
| `#[sampler(N)]` | Bind sampler for texture |
| `#[storage(N)]` | Bind storage buffer (optional: `read_only`, `buffer`) |

### Texture Options
```rust
#[texture(1, dimension = "2d", sample_type = "float", filterable = true)]
#[sampler(2, sampler_type = "filtering")]
my_texture: Handle<Image>,
```

### Optional Textures
```rust
#[texture(1)]
#[sampler(2)]
my_texture: Option<Handle<Image>>,  // None uses FallbackImage
```

### Struct-Level
```rust
#[derive(AsBindGroup)]
#[uniform(0, MyMaterialUniform)]  // converts via Into<MyMaterialUniform>
struct MyMaterial { /* ... */ }
```

---

## WGSL Binding Groups

```wgsl
// Group 0 = View (camera, projection, time)
// Group 1 = Mesh (transform, skinning)
// Group 2 = Material (YOUR bindings)

@group(2) @binding(0) var<uniform> material: MyMaterialUniform;
@group(2) @binding(1) var base_texture: texture_2d<f32>;
@group(2) @binding(2) var base_sampler: sampler;
```

**Rule:** Material bindings always go in `@group(2)`. Groups 0 and 1 are reserved by Bevy.

---

## ShaderRef

```rust
pub enum ShaderRef {
    Default,                        // Use context default
    Handle(Handle<Shader>),         // Runtime handle
    Path(AssetPath<'static>),       // File path (most common)
}

// Most common usage:
fn fragment_shader() -> ShaderRef {
    "shaders/my_material.wgsl".into()
}
```

---

## Material Specialization

For shader variants without runtime branching:

```rust
impl Material for MyMaterial {
    fn specialize(
        pipeline: &MaterialPipeline<Self>,
        descriptor: &mut RenderPipelineDescriptor,
        layout: &MeshVertexBufferLayout,
        key: MaterialPipelineKey<Self>,
    ) -> Result<(), SpecializedMeshPipelineError> {
        // Modify descriptor based on key
        descriptor.primitive.cull_mode = None; // example: disable culling
        Ok(())
    }
}
```

---

## Alpha Modes

| Mode | Usage |
|---|---|
| `Opaque` | No transparency (fastest) |
| `Mask(threshold)` | Binary alpha test — pixel is fully visible or fully invisible |
| `Blend` | Standard alpha blending (sorting required) |
| `Premultiplied` | Pre-multiplied alpha |
| `Add` | Additive blending (glow effects) |
| `Multiply` | Multiply blending |
| `AlphaToCoverage` | MSAA-based transparency |

**Performance:** Opaque > Mask > all blending modes. Transparent objects require sorting.

---

## Custom Vertex Attributes

```rust
// Define custom attribute
pub const ATTRIBUTE_OCT_NORMAL: MeshVertexAttribute =
    MeshVertexAttribute::new("OctNormal", 988_540_900, VertexFormat::Snorm16x2);

// Add to mesh
mesh.insert_attribute(ATTRIBUTE_OCT_NORMAL, oct_normal_data);

// In specialize(), request the attribute in the vertex buffer layout
let vertex_layout = layout.get_layout(&[
    Mesh::ATTRIBUTE_POSITION.at_shader_location(0),
    ATTRIBUTE_OCT_NORMAL.at_shader_location(1),
])?;
descriptor.vertex.buffers = vec![vertex_layout];
```

---

## This Project's Custom Materials

Four custom materials in `sea.rs`:

| Material | Shader | Purpose |
|---|---|---|
| `OceanMaterial` | `ocean_material.wgsl` | Deep ocean: Gerstner waves, Fresnel, Beer-Lambert depth |
| `FogMaterial` | `fog_material.wgsl` | Edge fog: fades to opaque at map boundaries |
| `CoastMaterial` | `coast_material.wgsl` | Coastal strip: sand, rock, shore foam transitions |
| `TerrainMaterial` | `terrain_material.wgsl` | Unified terrain: satellite/cliff/beach blend via vertex alpha |

All use `AsBindGroup` with uniforms and textures. `TerrainMaterial` uses the custom `ATTRIBUTE_OCT_NORMAL` (Snorm16x2 octahedral encoding — 4 bytes vs 12 for Float32x3).

### Terrain Material Vertex Color Convention

The terrain shader blends based on vertex color alpha:
- `alpha = 1.0` → pure satellite texture
- `alpha ≈ 0.5` → cliff rock texture blend
- `alpha = 0.0` → beach sand texture
- RGB channels carry warm tint to mask blue satellite bleeding at coastlines

See CLAUDE.md coastal rendering section for full vertex color table.

---

## Lights (Quick Reference)

### DirectionalLight (Sun)
```rust
commands.spawn((
    DirectionalLight {
        illuminance: 100_000.0,  // lux
        shadows_enabled: true,
        ..default()
    },
    Transform::default().looking_to(Vec3::new(-1.0, -1.0, -1.0), Vec3::Y),
));
```

### PointLight
```rust
commands.spawn((
    PointLight { intensity: 1500.0, range: 20.0, ..default() },
    Transform::from_xyz(4.0, 8.0, 4.0),
));
```

### AmbientLight (Resource)
```rust
commands.insert_resource(AmbientLight { color: Color::WHITE, brightness: 100.0 });
```

**0.15:** Light bundles (`PointLightBundle`, etc.) are deprecated — spawn the light component directly.

This project uses a day/night cycle (`SunLight` component in `map.rs`) animating `DirectionalLight` rotation + color temperature + `AmbientLight` brightness.
