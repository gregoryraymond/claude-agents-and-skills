---
name: geometry-vertex-color-shader
description: >
  Documents the vertex color RGBA encoding contract between gen_cliff_glb.rs (CPU mesh generator)
  and terrain_material.wgsl (GPU shader). Vertex colors encode surface type metadata, NOT visual
  color. The shader interprets RGBA channels to blend between satellite, cliff rock, and beach
  sand textures.
triggers:
  - vertex color
  - terrain shader
  - cliff texture blend
  - beach alpha
  - coastal mask
  - terrain_material.wgsl
  - gen_cliff_glb
  - surface type encoding
---

# Vertex Color / Shader Contract

## Core Principle

Vertex color RGBA is a **surface-type encoding**, not a visual color. The CPU mesh generator
(`gen_cliff_glb.rs`) writes RGBA values that the GPU shader (`terrain_material.wgsl`) interprets
to blend between three tileable textures: satellite terrain, cliff rock, and beach sand.

Changing vertex color values changes which texture the shader selects and how much of each
texture appears. There is no 1:1 relationship between vertex RGB and on-screen pixel color.

---

## Alpha Channel: Surface Type Selector

The alpha channel is the primary control signal. It drives two `smoothstep` blend curves
in the fragment shader:

```wgsl
// terrain_material.wgsl lines 166-168
let cliff_t     = smoothstep(0.85, 0.45, a);       // terrain-to-cliff
let beach_t_raw = smoothstep(0.35, 0.05, a);       // cliff-to-beach
```

Where `a = vertex_alpha + noise` (noise is ~+/-0.1 from `noise(wp.xz * 5.0) * 0.1`).

### Alpha Value Reference Table

| Alpha | cliff_t | beach_t | Effective Blend | Used For |
|-------|---------|---------|-----------------|----------|
| 1.00  | 0.00    | 0.00    | 100% satellite terrain | Interior land, far from coast |
| 0.92  | ~0.00   | 0.00    | ~100% satellite, faint cliff possible with noise | Coastal mask distance 3 |
| 0.78  | ~0.12   | 0.00    | ~88% satellite + ~12% cliff | Coastal mask distance 2 |
| 0.60  | ~0.56   | 0.00    | ~44% satellite + ~56% cliff | Coastal mask distance 1 |
| 0.45  | ~0.88   | 0.00    | ~12% satellite + ~88% cliff | Coast edge (distance 0), ocean vertices |
| 0.35  | 1.00    | 0.00    | 100% cliff rock texture | Cliff wall faces (top and bottom) |
| 0.20  | 1.00    | ~0.50   | 50% cliff + 50% beach | Beach transition zone |
| 0.00  | 1.00    | 1.00    | 100% beach sand texture | Full beach at ocean edge |

**Note**: `beach_t` is further masked by surface normal slope (`beach_slope_mask = smoothstep(0.3, 0.7, normal.y)`).
Vertical cliff faces get `beach_slope_mask ~ 0`, so even with low alpha they show cliff texture, not beach.
This prevents beach sand from appearing on steep cliff walls.

### Key Alpha Thresholds

- **> 0.85**: Pure satellite texture (cliff_t = 0)
- **0.85 to 0.45**: Satellite-to-cliff blend zone (cliff_t ramps 0 to 1)
- **< 0.45**: Full cliff texture (cliff_t = 1)
- **0.35 to 0.05**: Cliff-to-beach blend zone (beach_t ramps 0 to 1)
- **< 0.05**: Full beach sand (beach_t = 1)
- **Noise adds ~0.1 variation**, breaking up blend boundaries organically

---

## RGB Channels: Tint Multiplier

RGB is multiplied onto the **blended texture result** in the shader:

```wgsl
// terrain_material.wgsl lines 176-177
let terrain_final = terrain_color * vert_color.rgb;
let cliff_final   = cliff_color * vert_color.rgb;
```

- **(1.0, 1.0, 1.0)** = no tint, pure texture color. Used for inland terrain.
- **(0.72, 0.62, 0.48)** = warm brown tint. Used at coast edge (distance 0) to neutralize
  blue satellite pixels from polygon/texture misalignment.
- Intermediate values interpolate between these two extremes based on coastal distance.

Beach texture is applied directly (not multiplied by vertex RGB):
```wgsl
// terrain_material.wgsl line 183
base_color = mix(base_color, beach_color, beach_t);
```

This means RGB tint only affects the terrain and cliff portions of the blend, not beach sand.

---

## Vertex Color Assignment Locations (gen_cliff_glb.rs)

### 1. Terrain Surface Vertices (lines ~785-835)

Decision tree (evaluated in order):

| Condition | RGBA | Purpose |
|-----------|------|---------|
| Ocean vertex, beach zone | `[1.0, 0.92-t*0.10, 0.75-t*0.25, max(1.0-t*3.5, 0.0)]` | Beach-colored ocean vertex for smooth interpolation |
| Ocean vertex, non-beach | `[0.72, 0.62, 0.48, 0.45]` | Cliff-like color to prevent blue teeth at cliff tops |
| Land vertex, beach zone (bf > 0.01) | `[1.0, 0.92-t*0.10, 0.75-t*0.25, max(1.0-t*3.5, 0.0)]` | Beach alpha ramp: full beach at bf > 0.28 |
| Land vertex, coastal mask (cd < 4) | `[0.72+t*0.28, 0.62+t*0.38, 0.48+t*0.52, 0.45+t*0.55]` | Graduated coastal mask, t = cd/4 |
| Land vertex, interior | `[1.0, 1.0, 1.0, 1.0]` | Pure satellite texture |

Where:
- `bf` = `beach_factor[idx]`, range 0.0 (inland edge of beach) to 1.0+ (ocean edge)
- `cd` = `coastal_dist[idx]`, integer BFS distance from nearest ocean vertex
- `t` = normalized parameter (bf or cd/coastal_mask_cells)

### 2. Cliff Wall Vertices (lines ~1062-1068)

| Position | RGBA | Purpose |
|----------|------|---------|
| Cliff top | `[0.45, 0.32, 0.22, 0.35]` | Darker warm rock, alpha 0.35 = full cliff texture |
| Cliff base | `[0.28, 0.22, 0.16, 0.35]` | Deep shadow rock, alpha 0.35 = full cliff texture |

Both use alpha 0.35 which maps to cliff_t = 1.0 (100% cliff rock texture).
The RGB difference creates a natural darkening gradient from top to bottom,
enhanced by the shader's own `height_factor = smoothstep(-0.2, 0.1, wp.y)` darkening.

---

## Coastal Distance Mask (BFS System)

### Why It Exists

The satellite terrain texture contains blue ocean pixels at the polygon-based coastline
because the satellite image's coastline does not perfectly align with the polygon land/ocean
classification. Without masking, land vertices 1-4 cells from the polygon boundary sample
blue ocean pixels, creating visible blue triangles on ALL coastlines.

### How It Works

A BFS propagates from every ocean-adjacent land vertex, computing integer distance inland.
`COASTAL_MASK_CELLS = 4` defines the maximum propagation depth.

| Distance (cd) | t = cd/4 | R | G | B | Alpha | Cliff Blend % |
|---------------|----------|------|------|------|-------|---------------|
| 0 (coast edge) | 0.00 | 0.72 | 0.62 | 0.48 | 0.45 | ~88% |
| 1 | 0.25 | 0.79 | 0.72 | 0.61 | 0.59 | ~56% |
| 2 | 0.50 | 0.86 | 0.81 | 0.74 | 0.73 | ~20% |
| 3 | 0.75 | 0.93 | 0.91 | 0.87 | 0.86 | ~0% |
| 4+ | 1.00 | 1.00 | 1.00 | 1.00 | 1.00 | 0% |

The graduated transition prevents any visible "ring" at a fixed distance threshold.

### Ocean Vertex Override

Ocean vertices in mixed land/ocean cell triangles must NOT keep the default `[1.0, 1.0, 1.0, 1.0]`.
At alpha 1.0, the shader shows pure satellite texture (blue ocean). GPU interpolation between a
cliff-colored land vertex (alpha 0.45) and a satellite-blue ocean vertex (alpha 1.0) creates
visible blue "teeth" at cliff tops.

Fix: ocean vertices get `[0.72, 0.62, 0.48, 0.45]` (same as coast-edge land vertices) so
interpolation across mixed-cell triangles stays consistently cliff-textured. The ocean surface
plane at y=-0.25 covers these vertices anyway.

---

## Beach Alpha Ramp

Beach zones use an aggressive alpha ramp to push vertices to full beach texture quickly:

```rust
let beach_alpha = (1.0 - bf * 3.5).max(0.0);
```

| beach_factor (bf) | Alpha | Shader Blend |
|-------------------|-------|--------------|
| 0.00 | 1.00 | Pure satellite (inland edge) |
| 0.10 | 0.65 | Satellite/cliff mix |
| 0.20 | 0.30 | Mostly cliff transitioning to beach |
| 0.28 | 0.02 | Nearly full beach |
| 0.30+ | 0.00 | Full beach sand texture |

The 3.5x multiplier means beach texture fully takes over by `bf = 0.29`.
This creates a narrow but visible transition strip at the inland edge of beach zones.

---

## Shader Texture Pipeline

### Three Input Textures

| Binding | Texture | UV Source | Scale Uniform |
|---------|---------|-----------|---------------|
| 1-2 | `terrain_tex` (satellite) | Mesh UV (lon/lat mapped) | N/A |
| 3-4 | `cliff_tex` (tileable rock) | World-space: `(wp.x*s + wp.z*s*0.7, wp.y*3.0)` | `tex_scales.x` |
| 5-6 | `beach_tex` (tileable sand) | World-space: `wp.xz * s` | `tex_scales.y` |

### Blending Order (fragment shader)

```
1. Sample all three textures
2. Apply cliff color modifiers (warm tint, height darkening)
3. Apply beach color modifiers (warm boost, wet sand darkening)
4. terrain_final = satellite * vertex_rgb
5. cliff_final   = cliff_rock * vertex_rgb
6. base = mix(terrain_final, cliff_final, cliff_t)     // terrain -> cliff
7. base = mix(base, beach_color, beach_t * slope_mask) // result -> beach
8. Apply lighting (sun diffuse + hemisphere ambient + cliff fill)
```

### TerrainMaterial Rust Struct (sea.rs lines 36-49)

```rust
pub struct TerrainMaterial {
    pub tex_scales: Vec4,       // x=cliff_scale, y=beach_scale, z=unused, w=unused
    pub terrain_texture: Handle<Image>,
    pub cliff_texture: Handle<Image>,
    pub beach_texture: Handle<Image>,
}
```

Configured with `AlphaMode::Opaque` and no backface culling (cliff faces visible from both sides).

---

## Critical Invariants

1. **Alpha drives texture selection.** Changing alpha without understanding the smoothstep curves
   will cause wrong textures to appear (e.g., setting alpha to 0.5 on inland vertices would
   show cliff rock instead of satellite).

2. **RGB tints terrain and cliff, not beach.** Beach color comes directly from the beach texture,
   not from vertex RGB. Vertex RGB only modulates the satellite and cliff portions.

3. **Ocean vertices must match adjacent land style.** Never leave ocean vertices at
   `[1.0, 1.0, 1.0, 1.0]` as this creates blue satellite bleeding through GPU interpolation.

4. **Cliff walls use alpha 0.35.** This places them firmly in the "full cliff texture" zone.
   Do not change this without verifying the smoothstep curves still produce 100% cliff blend.

5. **Noise breaks up blend boundaries.** The shader adds `noise(wp.xz * 5.0) * 0.1` to alpha
   before the smoothstep calls. This means blend boundaries are fuzzy by ~0.1 alpha units.
   Keep alpha values for different zones at least 0.15 apart to avoid unintended overlap.

6. **Beach slope mask prevents sand on cliff faces.** Even if alpha is 0 (full beach), vertical
   surfaces (normal.y near 0) will show cliff texture due to `beach_slope_mask`.

---

## Files Involved

| File | Role |
|------|------|
| `crates/europe-zone-control/src/bin/gen_cliff_glb.rs` | CPU: assigns vertex RGBA per surface type |
| `crates/europe-zone-control/assets/shaders/terrain_material.wgsl` | GPU: interprets RGBA to blend textures |
| `crates/europe-zone-control/src/sea.rs` | Rust: `TerrainMaterial` struct and `Material` impl |
| `crates/europe-zone-control/assets/textures/sand_color.png` | Beach sand tileable texture |
| `crates/europe-zone-control/assets/textures/rock_color.png` | Cliff rock tileable texture |
