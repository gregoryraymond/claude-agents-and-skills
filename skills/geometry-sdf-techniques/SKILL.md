---
name: geometry-sdf-techniques
description: Signed Distance Field (SDF) techniques for terrain coastline smoothing, anti-aliased boundary rendering, distance field generation, and smooth boolean operations. Reference for replacing hard polygon edges with smooth distance-field blending in shaders and mesh generation.
user-invocable: false
---

# Signed Distance Fields (SDF) for Coastline Rendering

This skill covers SDF fundamentals, 2D distance fields for coastlines, shader-based edge softening, GPU distance field generation, boolean operations, and application to this project's terrain/coastal rendering pipeline.

---

## 1. SDF Fundamentals

A **Signed Distance Field** stores, for every point in space, the shortest distance to the nearest surface boundary:

- **Positive** values: point is **outside** the shape (e.g., in the ocean)
- **Negative** values: point is **inside** the shape (e.g., on land)
- **Zero**: point is exactly **on the boundary** (the coastline)

The magnitude tells you HOW FAR from the boundary. This is the key property that makes SDFs useful for smooth rendering -- you get a continuous gradient across the boundary instead of a binary inside/outside classification.

```
Distance values near a coastline:

  Ocean (+)     Coast (0)     Land (-)
  +0.8  +0.5   +0.2  0.0   -0.2  -0.5  -0.8
  ------>       edge         <------
```

### Properties

1. **Gradient magnitude is 1** everywhere (for exact SDFs): `|nabla d| = 1`. This means the distance changes at a constant rate as you move away from the boundary.
2. **Gradient direction points toward nearest boundary point**: useful for computing normals.
3. **Isosurfaces at any threshold** give offset curves/surfaces: `d = 0.1` gives a curve 0.1 units outside the shape.
4. **Linear interpolation is meaningful**: blending two SDF values gives a reasonable intermediate distance (unlike binary masks).

---

## 2. 2D SDF for Coastlines

For a top-down map game, the coastline SDF is a 2D texture where each texel stores the signed distance from that world-space position to the nearest coastline edge.

### What It Replaces

Currently the project uses **BFS distance in grid cells** (the `coastal_distance` BFS in `gen_cliff_glb.rs` propagating up to `COASTAL_MASK_CELLS = 4` cells). This gives integer-stepped distance bands. An SDF texture would provide:

- **Sub-cell precision**: distance varies smoothly within each cell
- **No stepping artifacts**: no visible rings at distance 1, 2, 3, 4
- **Resolution-independent**: the same SDF works at any zoom level
- **Shader-friendly**: sample the texture, apply smoothstep, done

### Conceptual Pipeline

1. Define coastline as polygon edges (already available as country polygon boundaries classified as coastal)
2. Rasterize "seed pixels" at the coastline boundary into a texture
3. Run a distance field algorithm (BFS, JFA, or exact) to fill every texel with signed distance
4. Upload as a single-channel float texture (or R16/R8 normalized)
5. Sample in terrain/coast/ocean shaders for smooth blending

### SDF From Polygon Edges

Given country polygons with edges classified as coastal vs interior:

```rust
// Pseudocode: seed the SDF texture
for each coastal_edge in country_polygons {
    for each pixel along the rasterized edge {
        sdf_texture[pixel] = 0.0;  // zero = on boundary
        seed[pixel] = true;
    }
}
// Then propagate distances outward from seeds
```

The sign is determined by point-in-polygon testing: if the pixel center is inside any land polygon, the distance is negative (inside); otherwise positive (outside/ocean).

---

## 3. Shader-Based Edge Softening

The core rendering technique: use the SDF value to create smooth, anti-aliased transitions at coastline boundaries.

### Basic Pattern: smoothstep on SDF

```wgsl
// In a WGSL fragment shader:
// `d` is the signed distance sampled from the SDF texture
// Positive = ocean, negative = land, zero = coastline

let d: f32 = textureSample(sdf_texture, sdf_sampler, uv).r;

// Hard edge (aliased):
let mask: f32 = step(0.0, d);  // 0 on land, 1 in ocean

// Soft edge (anti-aliased):
let edge_width: f32 = 0.02;  // world-space units of transition
let mask: f32 = smoothstep(-edge_width, edge_width, d);
// 0.0 = fully land, 1.0 = fully ocean, 0.0-1.0 = transition zone
```

### Multi-Zone Coastal Transition

The SDF enables multiple blending zones with different thresholds:

```wgsl
// Distance-based zone classification
let d: f32 = textureSample(sdf_texture, sdf_sampler, uv).r;

// Zone 1: Deep water (d > 0.5)
// Zone 2: Shallow water with seabed visibility (0.0 < d < 0.5)
// Zone 3: Wet sand / surf line (d ~ 0.0, narrow band)
// Zone 4: Dry beach (-0.3 < d < 0.0)
// Zone 5: Vegetation / terrain (d < -0.3)

let shallow_factor: f32 = smoothstep(0.5, 0.0, d);     // 0 in deep, 1 at coast
let beach_factor: f32   = smoothstep(0.05, -0.05, d);   // 0 in water, 1 on land
let veg_factor: f32     = smoothstep(-0.1, -0.4, d);    // 0 on beach, 1 inland

// Blend materials:
let water_color = mix(deep_water, shallow_water, shallow_factor);
let ground_color = mix(sand_color, terrain_color, veg_factor);
let final_color = mix(ground_color, water_color, 1.0 - beach_factor);
```

### Foam / Surf Line

The SDF makes it trivial to place a surf line at the exact waterline:

```wgsl
// Foam where |d| is very small (right at the boundary)
let foam_width: f32 = 0.03;
let foam_factor: f32 = 1.0 - smoothstep(0.0, foam_width, abs(d));
let foam_noise: f32 = textureSample(noise_tex, noise_sampler, uv * 20.0).r;
let foam: f32 = foam_factor * step(0.4, foam_noise);  // noisy foam line
```

---

## 4. fwidth() for Screen-Space Anti-Aliasing

The `fwidth()` function provides **automatic adaptation** of the blur width to the viewing distance and screen resolution. This is the standard technique for resolution-independent SDF rendering.

### How fwidth Works

```wgsl
// fwidth(x) = abs(dpdx(x)) + abs(dpdy(x))
//
// It measures how fast `x` changes across neighboring pixels.
// When zoomed out: `x` changes a lot per pixel -> fwidth is large -> wider blur
// When zoomed in:  `x` changes little per pixel -> fwidth is small -> narrow blur
```

### The Standard Pattern

```wgsl
// Instead of a fixed edge_width:
let d: f32 = textureSample(sdf_texture, sdf_sampler, uv).r;
let w: f32 = fwidth(d);  // screen-space rate of change of distance

// Anti-aliased edge, exactly 1 pixel wide regardless of zoom:
let mask: f32 = smoothstep(w, -w, d);
// land = 1.0, ocean = 0.0, transition = exactly 1 pixel

// For a wider transition (e.g., 2 pixels):
let mask: f32 = smoothstep(2.0 * w, -2.0 * w, d);
```

### Why This Works

| Viewing condition | fwidth(d) | smoothstep range | Visual result |
|---|---|---|---|
| Zoomed in close | Small (e.g., 0.001) | Narrow band | Crisp edge, minimal blur |
| Medium distance | Medium (e.g., 0.01) | Medium band | Soft 1-pixel AA edge |
| Zoomed out far | Large (e.g., 0.1) | Wide band | Smooth blend, no shimmer |

The key insight: `fwidth(d)` measures "how many world-space distance units fit in one pixel." Using this as the smoothstep radius always produces a 1-pixel-wide transition, which is the optimal anti-aliasing width.

### WGSL Availability

WGSL provides `fwidth()`, `dpdx()`, and `dpdy()` as built-in derivative functions. They work in fragment shaders only (not vertex shaders). In WGSL syntax:

```wgsl
let w = fwidth(d);          // L1 norm of partial derivatives
let wx = dpdx(d);           // partial derivative in screen X
let wy = dpdy(d);           // partial derivative in screen Y
let w_l2 = sqrt(wx*wx + wy*wy);  // L2 norm (sometimes preferred)
```

### Caveats

- `fwidth()` is undefined at triangle edges where neighboring fragments belong to different triangles -- this can cause 1-pixel artifacts at mesh seams.
- For multi-zone transitions (beach/shallow/deep), use `fwidth()` for each zone's smoothstep independently.
- In WGSL, derivatives require `@fragment` stage and uniform control flow.

---

## 5. SDF Texture Generation

### Method A: CPU Brute Force (Exact)

For each texel, compute exact distance to every coastline edge segment, take the minimum. O(N * E) where N = texel count, E = edge count.

```rust
// Pseudocode
for y in 0..height {
    for x in 0..width {
        let p = texel_to_world(x, y);
        let mut min_dist = f32::MAX;
        for edge in coastal_edges {
            let d = point_to_segment_distance(p, edge.a, edge.b);
            min_dist = min_dist.min(d);
        }
        // Sign: negative if inside land polygon
        let sign = if point_in_any_land_polygon(p) { -1.0 } else { 1.0 };
        sdf[y * width + x] = sign * min_dist;
    }
}
```

**Performance**: For a 2048x1560 grid with ~5000 coastal edges, this is ~16 billion distance calculations. Too slow for real-time, but fine for offline generation in `gen_cliff_glb.rs` (run once, bake into texture).

### Method B: BFS / Chamfer Distance (Approximate, CPU)

Seed boundary cells with distance 0, then propagate outward using BFS. Each step increments distance by the cell size. This is what the project currently uses (`COASTAL_MASK_CELLS` BFS).

**Improvement over current**: Use a proper Euclidean Distance Transform (EDT) instead of Manhattan/Chebyshev BFS:

```rust
// 8SSEDT (8-point Sequential Signed Euclidean Distance Transform)
// Two-pass algorithm: forward pass (top-left to bottom-right),
// backward pass (bottom-right to top-left).
// Each pass propagates (dx, dy) vectors to nearest seed.
// Final distance = sqrt(dx*dx + dy*dy).
// Complexity: O(N) where N = texel count. Very fast on CPU.
```

### Method C: Jump Flood Algorithm (GPU, Approximate)

The JFA is the standard GPU method for computing distance fields. It runs in O(log2(N)) passes where N is the texture dimension.

#### Algorithm Steps

1. **Initialize**: For each pixel, if it is a seed (on the coastline), store its own coordinates. Otherwise store "no seed" sentinel.

2. **Passes**: For `k` from `N/2` down to `1` (halving each step, so `log2(N)` passes):
   - For each pixel `p`, examine 9 neighbors at offsets `{-k, 0, +k}` x `{-k, 0, +k}`
   - For each neighbor that has a valid seed, compute distance from `p` to that seed
   - Keep the closest seed found

3. **Final**: Each pixel knows its nearest seed. Compute `distance = length(pixel_pos - seed_pos)`.

#### Pass Count

For a texture of dimension `D`:
- Number of passes = `ceil(log2(D))`
- For 2048 wide: 11 passes
- For 4096 wide: 12 passes

Each pass reads and writes a full-screen texture. Total work: `9 * D^2 * log2(D)` texture lookups.

#### GPU Implementation (Compute Shader)

```wgsl
// JFA compute shader (one pass)
@group(0) @binding(0) var input_tex: texture_2d<f32>;
@group(0) @binding(1) var output_tex: texture_storage_2d<rg32float, write>;

@compute @workgroup_size(8, 8)
fn jfa_pass(@builtin(global_invocation_id) id: vec3<u32>) {
    let p = vec2<i32>(id.xy);
    let dims = textureDimensions(input_tex);

    var best_seed = textureLoad(input_tex, p, 0).xy;
    var best_dist = distance_to_seed(vec2<f32>(p), best_seed);

    // step_size is a uniform set to N/2, N/4, ..., 1
    for (var dy = -1; dy <= 1; dy++) {
        for (var dx = -1; dx <= 1; dx++) {
            let neighbor = p + vec2<i32>(dx, dy) * step_size;
            if (neighbor.x >= 0 && neighbor.x < i32(dims.x) &&
                neighbor.y >= 0 && neighbor.y < i32(dims.y)) {
                let seed = textureLoad(input_tex, neighbor, 0).xy;
                if (seed.x >= 0.0) {  // valid seed
                    let d = distance_to_seed(vec2<f32>(p), seed);
                    if (d < best_dist) {
                        best_dist = d;
                        best_seed = seed;
                    }
                }
            }
        }
    }

    textureStore(output_tex, p, vec4<f32>(best_seed, 0.0, 0.0));
}
```

#### JFA Accuracy

JFA is approximate -- it can miss the true nearest seed in rare configurations. Error rate is typically < 0.1% of pixels, and the magnitude of error is small (off by 1-2 pixels). For coastline rendering this is more than sufficient.

#### 1+JFA Variant

Run one pass of standard BFS (propagate to immediate neighbors) before starting JFA. This fills in the 1-pixel neighborhood exactly, then JFA handles long-range propagation. Reduces errors significantly.

---

## 6. SDF Boolean Operations

Boolean operations on SDFs let you combine multiple country shapes into a unified coastline field.

### Basic Operations

```wgsl
// Union: combine two shapes (land OR land)
fn sdf_union(d1: f32, d2: f32) -> f32 {
    return min(d1, d2);
}

// Intersection: overlap of two shapes (land AND land)
fn sdf_intersection(d1: f32, d2: f32) -> f32 {
    return max(d1, d2);
}

// Subtraction: cut shape2 from shape1
fn sdf_subtraction(d1: f32, d2: f32) -> f32 {
    return max(d1, -d2);
}
```

### Smooth Operations (Inigo Quilez Formulas)

Smooth boolean operations create organic, rounded transitions instead of sharp corners. The parameter `k` controls the smoothing radius.

```wgsl
// Smooth union (round merge of two shapes)
fn sdf_smooth_union(d1: f32, d2: f32, k: f32) -> f32 {
    let h = max(k - abs(d1 - d2), 0.0);
    return min(d1, d2) - h * h * 0.25 / k;
}

// Smooth subtraction
fn sdf_smooth_subtraction(d1: f32, d2: f32, k: f32) -> f32 {
    let h = max(k - abs(-d1 - d2), 0.0);
    return max(-d1, d2) + h * h * 0.25 / k;
}

// Smooth intersection
fn sdf_smooth_intersection(d1: f32, d2: f32, k: f32) -> f32 {
    let h = max(k - abs(d1 - d2), 0.0);
    return max(d1, d2) + h * h * 0.25 / k;
}
```

### Application: Merging Country Coastlines

When multiple countries share a landmass, their individual SDFs need to be unioned to create a single "all land" coastline SDF:

```rust
// Offline: compute per-country SDFs, then merge
let mut coastline_sdf = vec![f32::MAX; width * height];
for country in all_land_countries {
    let country_sdf = compute_sdf_for_polygon(&country.polygon, width, height);
    for i in 0..(width * height) {
        // Union: min of distances (closest land boundary wins)
        coastline_sdf[i] = coastline_sdf[i].min(country_sdf[i]);
    }
}
// coastline_sdf now has distance to nearest ANY coastline edge
// Positive = ocean, negative = inside some country
```

For smooth coastlines where countries meet, use `sdf_smooth_union` with a small `k` value (e.g., 0.01 in world units) to slightly round the junction points.

---

## 7. Application to This Project's Terrain

### Current System (BFS-Based)

The project currently uses integer-cell BFS distance for the coastal tint mask in `gen_cliff_glb.rs`:

1. BFS from ocean-adjacent land vertices, propagating up to `COASTAL_MASK_CELLS = 4` cells
2. Each distance ring gets a hardcoded RGB tint and alpha value
3. The vertex colors are interpolated by the GPU across triangles
4. The terrain shader uses `smoothstep(0.85, 0.45, alpha)` to blend cliff texture vs satellite

**Limitations**:
- Only 5 discrete distance bands (0, 1, 2, 3, 4) -- visible as concentric rings if you look closely
- Resolution-dependent: the bands are in grid cells, not world units
- No sub-cell precision at the actual coastline edge
- The BFS is Manhattan/Chebyshev, not Euclidean, so distance bands are slightly square-shaped

### SDF Replacement Strategy

#### Option A: SDF Texture (Recommended for Quality)

Generate a 2D SDF texture offline in `gen_cliff_glb.rs` alongside the terrain mesh:

1. Rasterize all coastal polygon edges as seeds into a texture matching the terrain grid resolution
2. Run 8SSEDT (CPU, exact, fast) to compute Euclidean distance at every texel
3. Assign sign based on land/ocean polygon membership
4. Normalize to a useful range (e.g., -1.0 = 4+ cells inland, +1.0 = 4+ cells into ocean)
5. Save as a single-channel R16 or R32F texture asset
6. In the terrain shader, sample this texture instead of reading vertex-color alpha for the coastal blend

**Shader change**:
```wgsl
// Before (vertex color alpha):
let blend = smoothstep(0.85, 0.45, vertex_color.a + noise * 0.15);

// After (SDF texture):
let d = textureSample(coastal_sdf, sdf_sampler, world_uv).r;
let w = fwidth(d);
// Multi-zone blend using continuous SDF distance
let cliff_blend = smoothstep(0.3 + w, -0.1 - w, d);  // cliff texture
let sand_blend = smoothstep(0.05 + w, -0.2 - w, d);   // sand zone
```

**Advantages**:
- Perfectly smooth transitions at any zoom level
- `fwidth()` automatically adapts blur width
- Multiple zones without discrete stepping
- Foam line placement at `d ~ 0`
- Resolution-independent (can use any texture resolution)

#### Option B: SDF as Vertex Attribute (Compromise)

Compute exact SDF per-vertex in `gen_cliff_glb.rs` instead of BFS cell distance:

1. For each land vertex, compute exact Euclidean distance to nearest coastal edge segment
2. Store as a float in vertex color alpha (or a separate vertex attribute)
3. Shader reads per-vertex SDF, GPU interpolates smoothly across triangles
4. Apply `smoothstep` + `fwidth()` in fragment shader

**Advantages over current BFS**: continuous distance (not integer steps), Euclidean (not Manhattan).
**Disadvantage vs texture**: resolution limited to mesh vertex density; interpolation across large triangles may be inaccurate.

#### Option C: Hybrid (Current BFS + SDF Shader Trick)

Keep the BFS vertex colors but improve the shader to approximate SDF behavior:

```wgsl
// Use the vertex alpha as a rough distance proxy
// Apply fwidth to get screen-space adaptive smoothing
let rough_dist = vertex_color.a;  // 0.45 at coast, 1.0 inland
let w = fwidth(rough_dist);
let blend = smoothstep(0.65 + w * 2.0, 0.45 - w * 2.0, rough_dist);
```

This is the lowest-effort change. It does not fix the discrete stepping but does add `fwidth()`-based adaptation to viewing distance.

---

## 8. SDF in 3D: Isosurface Extraction

For reference (not directly needed for 2D coastline rendering, but relevant to future terrain work):

### 3D SDF

A 3D SDF stores signed distance from every point in a volume to the nearest surface. The surface is the `d = 0` isosurface.

### Extraction Algorithms

- **Marching Cubes**: Classic algorithm. Samples SDF at 8 corners of each cube cell, uses a lookup table to generate triangles. Produces smooth meshes from SDFs.
- **Dual Contouring**: Samples SDF at cell corners AND computes gradient (normal) at edge crossings. Preserves sharp features better than marching cubes.
- **Surface Nets**: Simplified dual method. Places one vertex per cell that contains the surface, connects to neighbors. Simpler than dual contouring.

### Relevance to This Project

If cliff geometry were represented as a 3D SDF (land mass as a signed distance field in 3D), the cliff surface could be extracted via marching cubes or dual contouring. This would produce smooth cliff faces without the current vertical-quad cliff wall approach. However, this is a significantly larger architectural change than 2D SDF for coastline tinting.

---

## 9. Performance Comparison

### SDF Texture vs Per-Vertex BFS

| Aspect | Current BFS (vertex) | SDF Texture | SDF Per-Vertex |
|---|---|---|---|
| **Offline compute time** | Fast (BFS, O(V)) | Medium (8SSEDT, O(T)) | Slow (O(V*E)) |
| **Runtime cost** | Zero (vertex attr) | 1 texture sample/fragment | Zero (vertex attr) |
| **Memory** | In vertex buffer | Extra texture (e.g., 2048x1560 x 2B = 6.4MB for R16) | In vertex buffer |
| **Precision** | Integer cell steps | Sub-pixel continuous | Per-vertex continuous |
| **Zoom adaptation** | None | fwidth() automatic | fwidth() on interpolated |
| **Multi-zone** | Hardcoded per ring | Arbitrary thresholds | Arbitrary thresholds |
| **Implementation effort** | Already done | Medium (new texture + shader) | Low (change gen_cliff_glb) |

### Recommended Path

For this project, **Option B (SDF per-vertex)** is the best cost/benefit ratio:

1. It requires changing only `gen_cliff_glb.rs` (compute exact distance instead of BFS)
2. Store the continuous distance in vertex alpha
3. Add `fwidth()` to the terrain shader for adaptive smoothing
4. No new texture assets, no new shader bindings, no new GPU resource management
5. Quality is good enough at the project's mesh resolutions (2048x1560 and 4096x3120)

If higher quality is needed later (visible stepping at very close zoom), upgrade to **Option A (SDF texture)**.

---

## 10. Reference Links

### Fundamentals
- [Inigo Quilez - Distance Functions](https://iquilezles.org/articles/distfunctions/) -- comprehensive 2D/3D SDF primitive catalog + boolean operations
- [GM Shaders - Signed Distance Fields](https://mini.gmshaders.com/p/sdf) -- accessible introduction
- [Ronja's Tutorials - 2D SDF Basics](https://www.ronja-tutorials.com/post/034-2d-sdf-basics/) -- 2D SDF with rendering
- [Ronja's Tutorials - 2D SDF Combination](https://www.ronja-tutorials.com/post/035-2d-sdf-combination/) -- boolean operations

### Anti-Aliasing
- [Analytical Anti-Aliasing (frost.kiwi)](https://blog.frost.kiwi/analytical-anti-aliasing/) -- comprehensive guide to fwidth/smoothstep AA
- [Using fwidth for Distance-Based Anti-Aliasing](http://www.numb3r23.net/2015/08/17/using-fwidth-for-distance-based-anti-aliasing/) -- focused fwidth technique
- [Perfecting Anti-Aliasing on SDFs (blog.pkh.me)](https://blog.pkh.me/p/44-perfecting-anti-aliasing-on-signed-distance-functions.html) -- advanced AA methods
- [SDF Antialiasing (drewcassidy.me)](https://drewcassidy.me/2020/06/26/sdf-antialiasing/) -- SDF texture AA specifics
- [glsl-aastep](https://github.com/glslify/glsl-aastep) -- reference anti-alias step implementation

### Distance Field Generation
- [Jump Flooding Algorithm (Wikipedia)](https://en.wikipedia.org/wiki/Jump_flooding_algorithm) -- algorithm overview
- [JFA on GPU (blog.demofox.org)](https://blog.demofox.org/2016/02/29/fast-voronoi-diagrams-and-distance-dield-textures-on-the-gpu-with-the-jump-flooding-algorithm/) -- practical GPU implementation
- [JFA Original Paper (NUS)](https://www.comp.nus.edu.sg/~tants/jfa.html) -- academic reference
- [Distance Fields (prideout.net)](https://prideout.net/blog/distance_fields/) -- multiple generation methods compared
- [easy-signed-distance-field (Rust)](https://github.com/gabdube/easy-signed-distance-field) -- pure Rust SDF generator

### Terrain & Game Applications
- [UE4 Terrain Blending with Distance Fields](https://egray.io/blog/ue4-terrain-blending) -- game engine application
- [Terrain Rendering Overview (kosmonaut)](https://kosmonautblog.wordpress.com/2017/06/04/terrain-rendering-overview-and-tricks/) -- terrain techniques catalog
- [SDF Collection (GitHub)](https://github.com/CedricGuillemet/SDF) -- curated papers and resources

### 3D SDF / Isosurface
- [GPU Gems 3 Ch.34 - SDFs via GPU Scan](https://developer.nvidia.com/gpugems/gpugems3/part-v-physics-simulation/chapter-34-signed-distance-fields-using-single-pass-gpu) -- GPU SDF generation
- [Smooth Terrain (Voxel Tools)](https://voxel-tools.readthedocs.io/en/latest/smooth_terrain/) -- SDF-based terrain meshing
- [Inigo Quilez - Raymarching Distance Fields](https://iquilezles.org/articles/raymarchingdf/) -- 3D SDF rendering

### Boolean Operations
- [Inigo Quilez - Smooth Min/Max](https://iquilezles.org/articles/distfunctions/) -- smooth union/intersection formulas
- [SDF Boolean Operations (SorotokiCode)](https://bjcaasenbrood.github.io/SorotokiCode/sdf/operations/) -- visual examples
- [Shadertoy - SDF Smooth Combinations](https://www.shadertoy.com/view/4XBfDK) -- interactive demos

---

## 11. Quick Reference: Key Formulas

### Smoothstep Anti-Aliased Edge

```wgsl
let mask = smoothstep(w, -w, d);  // w = fwidth(d)
```

### Smooth Union (k = smoothing radius)

```wgsl
let h = max(k - abs(d1 - d2), 0.0);
return min(d1, d2) - h * h * 0.25 / k;
```

### Point-to-Line-Segment Distance (for exact SDF computation)

```rust
fn point_to_segment_dist(p: Vec2, a: Vec2, b: Vec2) -> f32 {
    let ab = b - a;
    let ap = p - a;
    let t = (ap.dot(ab) / ab.dot(ab)).clamp(0.0, 1.0);
    let closest = a + ab * t;
    (p - closest).length()
}
```

### 8SSEDT Forward/Backward Pass Masks

```
Forward (top-left to bottom-right):
  (-1,-1) (0,-1) (1,-1)
  (-1, 0)   P

Backward (bottom-right to top-left):
             P   (1, 0)
  (-1, 1) (0, 1) (1, 1)
```

At each pixel, check if propagating from any mask neighbor gives a shorter distance vector than the current one. Two passes over the entire image gives exact Euclidean distances.
