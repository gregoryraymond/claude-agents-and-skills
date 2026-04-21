---
name: mesh-extrusion
description: Reference for mesh extrusion techniques used in terrain cliff walls and vertical geometry generation. Covers boundary edge detection, vertical quad strip extrusion, skirt generation for LOD crack prevention, normal and UV calculation for extruded faces, degenerate quad handling, XZ-only smoothing, corner filling, and cull mode considerations. Apply when modifying cliff wall generation, terrain skirts, or any boundary extrusion code in gen_cliff_glb.rs.
user-invocable: false
---

# Mesh Extrusion Techniques for Terrain Cliff Walls and Vertical Geometry

## Overview

Mesh extrusion is the process of generating new geometry by projecting existing edges or faces along a direction -- typically downward for terrain cliff walls. In this project, boundary edges between land and ocean cells on a heightmap grid are extruded vertically to create cliff walls that hide the raw terrain edge where land meets water.

The primary implementation lives in `gen_cliff_glb.rs`, which runs as an offline tool to produce `.glb` mesh files containing both the terrain surface and extruded cliff walls in a single draw call.

---

## 1. Boundary Edge Detection

### The Problem

A terrain grid classifies each cell (or vertex) as land or ocean. The visual boundary between these two classifications must be covered by vertical cliff geometry. Finding where to place cliff walls requires detecting **boundary edges** -- grid edges where one side is land and the other is ocean.

### Algorithm: Cell-Based Boundary Classification

On a regular grid with `rows x cols` vertices, cells are the quads between four adjacent vertices. A cell "has land" if **any** of its four corner vertices is classified as land.

```rust
let cell_has_land = |row: isize, col: isize| -> bool {
    if row < 0 || col < 0 || row >= (rows - 1) as isize || col >= (cols - 1) as isize {
        return false; // Out-of-bounds cells are ocean
    }
    let tl = r * cols + c;
    is_land(tl) || is_land(tl + 1)
        || is_land((r + 1) * cols + c)
        || is_land((r + 1) * cols + c + 1)
};
```

A boundary edge exists between two grid vertices when the cells on either side of that edge differ in their land classification.

### Horizontal Boundary Edges

For each row of vertices, scan pairs of adjacent vertices `(v0, v1)` where `v0 = row*cols + col` and `v1 = row*cols + col + 1`. The edge is horizontal (runs along the column axis). Check the cell above (`row - 1, col`) and the cell below (`row, col`):

```
cell_above = cell_has_land(row - 1, col)
cell_below = cell_has_land(row, col)
if cell_above != cell_below -> this is a boundary edge
```

### Vertical Boundary Edges

For each column of vertices, scan pairs of adjacent vertices `(v0, v1)` where `v0 = row*cols + col` and `v1 = (row+1)*cols + col`. The edge is vertical (runs along the row axis). Check the cell to the left (`row, col - 1`) and the cell to the right (`row, col`):

```
cell_left = cell_has_land(row, col - 1)
cell_right = cell_has_land(row, col)
if cell_left != cell_right -> this is a boundary edge
```

### Outward Direction Computation

For each land vertex adjacent to at least one ocean vertex, compute an outward direction vector pointing from land toward ocean. This is the average of unit vectors pointing toward each ocean neighbor:

```rust
let mut dx = 0.0f32;
let mut dz = 0.0f32;
let mut n = 0;
if col > 0 && !is_land(idx - 1) { dx -= lon_step; n += 1; }
if col < cols - 1 && !is_land(idx + 1) { dx += lon_step; n += 1; }
if row > 0 && !is_land(idx - cols) { dz += lat_step; n += 1; }
if row < rows - 1 && !is_land(idx + cols) { dz -= lat_step; n += 1; }
// Normalize
let len = (dx * dx + dz * dz).sqrt().max(0.001);
outward_dir.insert(idx, [dx / len, dz / len]);
```

This direction is used for optional outward offset of cliff bases and for computing smooth normals. The direction lives in XZ space only -- cliffs are vertical, so the Y component is always zero.

### Skip Conditions

Not all boundary edges produce cliff walls. Edges are skipped when:
- Either vertex has no corresponding terrain vertex (`grid_to_vert[v].is_none()`)
- Either vertex is in a **beach zone** (beach zones use sloped terrain instead of cliff walls)
- The cliff height is degenerate (top too close to bottom -- see Section 6)

---

## 2. Cliff Wall Generation: Vertical Quad Strips

### The Core Pattern: Top-Bottom Vertex Pairs

For each boundary vertex, create two new vertices at the same XZ position:
- **Top vertex**: at terrain surface height (the cliff edge)
- **Bottom vertex**: at a constant base Y level below the water surface

```rust
// Top of cliff: terrain height (or MIN_LAND_H minimum)
let top_y = if is_land(grid_idx) {
    heights[grid_idx].max(MIN_LAND_H)  // Enforce minimum cliff height
} else {
    heights[grid_idx].min(0.0)         // Ocean vertices clamp to 0
};

// Bottom of cliff: constant flat base
let bot_y = CLIFF_BASE_Y;  // Currently -0.2
```

These pairs are cached per grid vertex so that multiple edges sharing a vertex reuse the same pair:

```rust
let mut cliff_pair: HashMap<usize, (u32, u32)> = HashMap::new();
```

### Emitting Quad Strips as Triangle Pairs

Each boundary edge connects two grid vertices `v0` and `v1`. Their cliff pairs are `(t0, b0)` and `(t1, b1)`. A quad is formed:

```
t0 --- t1    (top edge, at terrain height)
|  \   |
|   \  |
b0 --- b1    (bottom edge, at CLIFF_BASE_Y)
```

This quad is emitted as two triangles. The **winding order** (which determines which side faces outward) depends on which side of the edge is land:

```rust
if flip {
    // Land is on the "below" or "right" side
    indices.push(t0); indices.push(t1); indices.push(b1);
    indices.push(t0); indices.push(b1); indices.push(b0);
} else {
    // Land is on the "above" or "left" side
    indices.push(t0); indices.push(b1); indices.push(t1);
    indices.push(t0); indices.push(b0); indices.push(b1);
}
```

The `flip` parameter is set based on which adjacent cell contains land, ensuring the outward-facing normal points away from land (toward the ocean viewer).

### Constants That Must Stay In Sync

| Constant | Value | Location | Purpose |
|----------|-------|----------|---------|
| `CLIFF_BASE_Y` | -0.2 | `gen_cliff_glb.rs` | Bottom of cliff walls |
| `BEACH_BASE_Y` | -0.35 | `gen_cliff_glb.rs` | Bottom of beach slopes (below ocean) |
| `MIN_LAND_H` | 0.03 | `gen_cliff_glb.rs` | Minimum terrain height for cliff tops |
| Ocean Y | -0.25 | `sea.rs` `spawn_sea` | Water surface plane height |

**Rule**: `BEACH_BASE_Y < Ocean Y < CLIFF_BASE_Y < MIN_LAND_H`. Beach slopes must be below water. Cliff bases can be at or above water because cliff walls visually cover the transition. Terrain tops must be above cliff bases.

---

## 3. Skirt Generation for LOD Crack Prevention

### The Problem

When terrain is rendered with multiple levels of detail (LOD), adjacent chunks at different resolutions have vertices that do not align at their shared edges. This produces visible cracks -- thin gaps through which the background (sky, ocean, void) is visible.

### How Skirts Work

A **skirt** is a strip of vertical triangles extruded downward from each edge vertex of a terrain chunk. The skirt extends below the surface by a fixed amount, creating a "curtain" that hangs below the terrain edge.

When two adjacent chunks have a height mismatch at their boundary, the skirts from both sides overlap vertically. The terrain surface of the higher-resolution chunk covers the top of the gap, and the skirt of the lower-resolution chunk fills from below. Neither chunk needs to know its neighbor's vertex positions.

```
Chunk A surface:     ___/\___
Chunk A skirt:       |      |   (hangs down from edge vertices)
                     |      |
Chunk B surface:         ___/\___
Chunk B skirt:           |      |
                         |      |
```

Where the chunks meet, the overlapping skirts ensure no background is visible.

### Implementation Pattern

```rust
// For each edge vertex of the terrain chunk:
let edge_vertex_pos = positions[edge_vi];
let skirt_depth = 0.5; // Must exceed maximum expected LOD height difference

// Add skirt vertex directly below
let skirt_vi = positions.len() as u32;
positions.push([edge_vertex_pos[0], edge_vertex_pos[1] - skirt_depth, edge_vertex_pos[2]]);

// Connect to next edge vertex's skirt with a quad (2 triangles)
// Same pattern as cliff wall quad emission
```

### Skirt vs Cliff Wall Comparison

| Property | Cliff Wall | Skirt |
|----------|-----------|-------|
| Purpose | Visual feature (cliff face) | Hide LOD seam artifacts |
| Visibility | Intentionally visible | Should be invisible (covered by adjacent terrain) |
| Height | Terrain height to constant base Y | Small constant depth below surface |
| Texturing | Cliff rock texture with UVs | Usually inherits terrain texture or untextured |
| Position | Only at land/ocean boundaries | At every chunk edge |

### Skirt Limitations

- **Z-fighting**: Overlapping skirts can z-fight with each other. Mitigate by using a small depth bias or ensuring skirts are always behind the main terrain in the depth buffer.
- **Overdraw**: Skirts that are never visible still cost rasterization. Keep skirt depth minimal.
- **Does not fix T-junctions**: Skirts hide gaps but do not solve vertex-sharing problems at chunk boundaries. For watertight meshes, use stitching or shared boundary vertices instead.

### This Project's Approach

This project does not use runtime LOD with skirts. Instead, it generates two complete LOD meshes offline (`coastline_lod0.glb` at 2048x1560, `coastline_lod1.glb` at 4096x3120) and switches between them based on camera distance. The cliff walls serve a similar purpose to skirts -- they hide the raw terrain edge where land meets the ocean plane -- but they are a visible design feature, not a hidden seam fix.

---

## 4. Normal Calculation for Extruded Faces

### Face Normal from Cross Product

For any triangle with vertices A, B, C (in winding order), the face normal is:

```rust
let edge1 = B - A;
let edge2 = C - A;
let face_normal = edge1.cross(edge2);  // Not normalized yet
```

The direction of the cross product depends on winding order. Counter-clockwise winding (when viewed from the front) produces an outward-facing normal.

### Smooth Normals via Accumulation

Rather than flat-shading each cliff face, this project accumulates face normals at shared vertices to produce smooth shading across the cliff surface:

```rust
let mut normals_accum = vec![[0.0f32; 3]; vertex_count];
for tri in indices.chunks_exact(3) {
    let a = Vec3::from(positions[tri[0]]);
    let b = Vec3::from(positions[tri[1]]);
    let c = Vec3::from(positions[tri[2]]);
    let n = (b - a).cross(c - a);  // Area-weighted (larger triangles contribute more)
    for &vi in &[tri[0], tri[1], tri[2]] {
        normals_accum[vi][0] += n.x;
        normals_accum[vi][1] += n.y;
        normals_accum[vi][2] += n.z;
    }
}
// Normalize all accumulated normals
let normals: Vec<[f32; 3]> = normals_accum.iter().map(|n| {
    let v = Vec3::from(*n).normalize_or_zero();
    if v == Vec3::ZERO { [0.0, 1.0, 0.0] } else { v.into() }
}).collect();
```

### Key Properties of This Approach

- **Area-weighted**: The un-normalized cross product has magnitude proportional to triangle area, so larger triangles contribute more to the vertex normal. This is generally desirable for terrain.
- **Shared vertices between terrain and cliff**: The top cliff vertex is at the same position as the terrain boundary vertex. Because they are separate vertices in the buffer (different indices), they get independent normals -- the cliff top normal points outward/downward while the terrain surface normal points upward. This creates a hard edge at the cliff lip, which is visually correct.
- **Fallback for degenerate normals**: Vertices with zero accumulated normal (no adjacent triangles, or all triangles are degenerate) get `[0.0, 1.0, 0.0]` (pointing up). This prevents NaN in the shader.

### Alternative: Angle-Weighted Normals

For higher quality, weight each face normal's contribution by the angle it subtends at the vertex rather than by area. This prevents large but grazing triangles from dominating the normal. Not currently used in this project because area-weighting produces acceptable results for cliff walls.

---

## 5. UV Assignment for Extruded Faces

### World-Position-Based UVs

Cliff wall UVs are computed from world-space position rather than edge length. This ensures that the cliff texture tiles uniformly in world space regardless of mesh topology:

```rust
const CLIFF_UV_SCALE: f32 = 0.5; // 1 tile per 2 world units
let u = (x * 0.7 + z * 0.3) * CLIFF_UV_SCALE;  // Horizontal: mixed X and Z
let top_v = top_y * CLIFF_UV_SCALE;              // Vertical: based on height
let bot_v = bot_y * CLIFF_UV_SCALE;
```

### Why Mixed X and Z for U Coordinate

Pure X-based UVs would create texture swimming on cliff faces that run parallel to the X axis (all vertices have nearly the same X, so U barely changes). The `0.7 * x + 0.3 * z` mix ensures texture variation regardless of cliff orientation. This is a simplified form of **triplanar mapping** projected onto a single axis.

### Alternative: Edge-Length-Based UVs

For cliffs that need texture to follow the coastline direction (e.g., horizontal sediment banding that follows the cliff face), accumulate edge length along the boundary:

```rust
let mut accumulated_length = 0.0;
for each boundary edge (v0, v1) in order:
    let dx = positions[v1][0] - positions[v0][0];
    let dz = positions[v1][2] - positions[v0][2];
    let edge_len = (dx * dx + dz * dz).sqrt();
    uv_u[v0] = accumulated_length * UV_SCALE;
    accumulated_length += edge_len;
    uv_u[v1] = accumulated_length * UV_SCALE;
```

This requires boundary edges to be ordered (a chain traversal), which adds complexity. The world-position approach avoids this requirement entirely.

### UV Scale Tuning

- Too large a scale (small tiles) makes texture repetition obvious -- visible grid seams on the cliff face.
- Too small a scale (large tiles) stretches the texture, losing detail.
- `CLIFF_UV_SCALE = 0.5` means one texture tile spans 2 world units, which balances detail and repetition for the project's cliff rock texture.

---

## 6. Degenerate Quad Handling

### When Top and Bottom Heights Are Equal (or Nearly Equal)

A cliff quad where the top vertex height equals the bottom vertex height produces a **degenerate quad** -- a quad with zero area. This creates:
- Zero-area triangles that waste GPU cycles
- Undefined normals (cross product of parallel edges is zero)
- Potential z-fighting with adjacent geometry
- Visual artifacts: thin bright or dark lines from floating-point imprecision

### Detection and Skipping

The project uses a minimum height threshold to skip degenerate cliffs:

```rust
if top_y <= bot_y + 0.08 {
    // Degenerate cliff -- terrain is at or below the cliff base.
    // Return sentinel values so emit_cliff_edge can detect and skip.
    cliff_pair.insert(grid_idx, (u32::MAX, u32::MAX));
    return (u32::MAX, u32::MAX);
}
```

The threshold of `0.08` world units means cliffs shorter than this are not emitted. The sentinel value `u32::MAX` propagates to `emit_cliff_edge`, which checks:

```rust
if t0 == u32::MAX || t1 == u32::MAX {
    return; // Skip this edge entirely
}
```

### Why 0.08 and Not 0.0

A threshold of exactly zero would only catch perfectly degenerate quads. In practice, floating-point arithmetic means heights that should be equal are off by tiny amounts (`1e-7`), producing near-degenerate quads that are technically non-zero but visually just a sliver. The `0.08` threshold catches these and also skips very short cliffs at the beach-cliff transition boundary that appear as "stubby teeth."

### Beach Zone Interaction

In beach zones, terrain is sloped below the ocean surface. Beach vertices may have heights well below `CLIFF_BASE_Y`, making their cliff quads inverted (top below bottom). The `beach_skip` system handles this by skipping cliff emission entirely for beach vertices, but the degenerate check provides a safety net for vertices at the beach-cliff transition where heights are marginal.

---

## 7. Smoothing Extruded Geometry

### The Problem: Grid-Aligned Staircase

On a regular grid, the land/ocean boundary follows cell edges, producing a staircase pattern -- 90-degree zigzags that do not resemble natural coastlines. This staircase is directly visible on cliff walls.

### Solution: Laplacian Smoothing in XZ Only

After all cliff quads are emitted, apply Laplacian smoothing to cliff vertex positions. **Critical constraint: only smooth in XZ, never in Y.** Moving cliff vertices vertically would either expose gaps at the top (detaching from terrain surface) or create gaps at the bottom (rising above the ocean surface).

```rust
for _ in 0..30 {  // 30 smoothing passes
    let prev = positions.clone();
    for vi in cliff_start..total_verts {
        // Only smooth within the same row (top-top or bottom-bottom)
        let same: Vec<usize> = adj[vi].iter()
            .filter(|&&n| (is_top[vi] && is_top[n]) || (is_bot[vi] && is_bot[n]))
            .copied().collect();
        if same.is_empty() { continue; }
        let (mut ax, mut az) = (0.0f32, 0.0f32);
        for &ni in &same {
            ax += prev[ni][0];
            az += prev[ni][2];
        }
        let n = same.len() as f32;
        positions[vi][0] = prev[vi][0] * 0.5 + (ax / n) * 0.5;  // lambda = 0.5
        positions[vi][2] = prev[vi][2] * 0.5 + (az / n) * 0.5;
    }
}
```

### Key Design Decisions

1. **Top and bottom rows smooth independently**: The filter `(is_top[vi] && is_top[n]) || (is_bot[vi] && is_bot[n])` ensures top vertices only average with other top vertices, and bottom vertices only with other bottom vertices. This prevents the cliff face from shearing (top moving left while bottom moves right).

2. **Adjacency from triangle connectivity**: The adjacency list is built from cliff triangles, not from grid topology. This means only vertices that are actually connected by triangles influence each other, respecting mesh topology.

3. **30 passes with lambda=0.5**: Aggressive smoothing that significantly rounds the staircase. Each pass cuts high-frequency variation roughly in half. After 30 passes, the coastline is visually smooth at normal viewing distances.

4. **Sync back to terrain**: After smoothing, cliff-top vertex XZ positions are copied back to their corresponding terrain surface vertices:

```rust
for (&grid_idx, &(top_vi, _)) in &cliff_pair {
    if let Some(tv) = grid_to_vert[grid_idx] {
        positions[tv as usize][0] = positions[top_vi as usize][0];
        positions[tv as usize][2] = positions[top_vi as usize][2];
    }
}
```

This ensures the terrain mesh edge exactly matches the cliff top, preventing visible gaps at the cliff lip.

### WARNING: Never Smooth Y

Moving cliff vertices in Y breaks the three-layer architecture:
- **Top vertices** must match terrain surface height (otherwise a gap appears at the cliff lip)
- **Bottom vertices** must be at `CLIFF_BASE_Y` (otherwise gaps appear above the ocean)

See CLAUDE.md "Key Lessons From Failed v18 Attempt" for the full history of why XZ-only smoothing is mandatory.

### WARNING: Never Smooth Terrain Surface Vertices in XZ

The terrain surface vertices are locked to geographic lon/lat coordinates. Moving them in XZ misaligns the satellite texture, causing wrong texture sampling. Cliff smoothing works because cliff vertices are duplicates (separate buffer entries) that do not carry satellite texture alignment. See CLAUDE.md for the v18 postmortem.

---

## 8. Corner Filling: Closing Staircase Gaps

### The Problem

On a grid-based boundary, the staircase pattern creates L-shaped corners where two perpendicular boundary edges meet. At each corner, there is a triangular gap between the two cliff quads -- the quads share a vertex at the corner but leave an open triangle on the inside of the turn.

```
    Land | Ocean       Cliff quads form an L-shape:
    -----+-----        |===|
         |             |   |
    Land | Land        |   +===|
                           gap here at the inside corner
```

### Solution: Corner Triangle Caps

For each grid vertex that has boundary edges on two perpendicular sides, emit an additional triangle to fill the gap. The triangle connects:
- The two bottom vertices of the adjacent cliff quads
- The bottom vertex of the corner itself

This is only needed at concave corners (where the land is on the inside of the L). Convex corners (land on the outside) do not produce gaps because the cliff quads overlap rather than gap.

### Detection

A vertex is a concave corner when it has ocean neighbors on two perpendicular sides. For example, ocean to the left AND ocean above (but land to the right and below). The specific perpendicular pairs to check are:
- Left + Above
- Left + Below
- Right + Above
- Right + Below

### Implementation Consideration

In this project, the 30-pass Laplacian smoothing largely eliminates corner gaps by rounding the staircase into smooth curves. Explicit corner filling is not currently implemented because smoothing makes it unnecessary. However, if smoothing passes are reduced (e.g., for performance), corner filling becomes important to prevent visible gaps in the cliff wall.

---

## 9. Double-Sided Rendering vs Single-Sided: Cull Mode Considerations

### Single-Sided (Back-Face Culling)

The default for most game meshes. Triangles are only visible from their front face (determined by winding order). The GPU discards triangles viewed from behind, saving ~50% rasterization cost.

**For cliff walls**: Single-sided is correct because:
- Cliffs are viewed from the ocean side (outward normal faces the camera)
- The land side of cliff walls is never visible (covered by terrain surface)
- Back-face culling doubles effective cliff rendering performance

### Double-Sided (No Culling)

Both sides of every triangle are rendered. Required when:
- Geometry can be viewed from either side (e.g., tree leaves, paper, cloth)
- Winding order is inconsistent or unknown
- The mesh is not a closed solid

**For terrain in this project**: The terrain mesh is single-sided (normals point up). Double-sided would waste GPU on the invisible underside.

### Setting Cull Mode in Bevy

```rust
// In a custom material:
fn specialize(descriptor: &mut RenderPipelineDescriptor, ...) {
    descriptor.primitive.cull_mode = Some(Face::Back);  // Default: cull back faces
    // descriptor.primitive.cull_mode = None;            // Double-sided
    // descriptor.primitive.cull_mode = Some(Face::Front); // Cull front (rare)
}
```

### When Double-Sided Matters for Extrusion

If cliff wall winding order is accidentally inconsistent (some quads wound clockwise, others counter-clockwise), double-sided rendering is a quick fix. However, this is a band-aid -- the correct fix is to ensure consistent winding. In `emit_cliff_edge`, the `flip` parameter controls winding based on which side contains land, ensuring all cliff faces wind consistently outward.

### Debugging Tip

If cliff walls appear invisible from certain angles, the likely cause is incorrect winding order (the `flip` parameter is wrong for that edge). Set `cull_mode = None` temporarily to confirm, then fix the winding logic.

---

## 10. How This Project Uses Extrusion: gen_cliff_glb.rs

### Pipeline Overview

The `gen_cliff_glb.rs` binary is an offline mesh generation tool that runs before the game. It produces `.glb` files containing a single mesh with both terrain surface and cliff walls.

**Step-by-step pipeline:**

1. **Grid generation**: Create a `rows x cols` grid covering Europe (lon/lat bounds). Classify each vertex as land or ocean using point-in-polygon tests against country definitions.

2. **Beach processing**: Identify beach zones via `BEACH_REGIONS` rectangles. Apply BFS to compute `beach_factor` (0.0 = inland, 1.0 = ocean edge). Slope beach vertex heights from terrain height down to `BEACH_BASE_Y`. Extend with taper BFS (`BEACH_TAPER_CELLS_BASE = 6`) beyond rectangle edges for gradual transition.

3. **Terrain mesh emission**: Emit triangles for cells with at least one land vertex. Skip all-ocean cells. Handle mixed land/ocean cells in beach zones specially (skip to avoid spike artifacts).

4. **Coastal distance BFS**: Propagate distance from ocean inland up to `COASTAL_MASK_CELLS = 4`. Assign graduated vertex colors that transition from cliff-textured (near coast) to pure satellite texture (inland). This masks blue satellite bleeding at coastlines.

5. **Boundary detection and cliff extrusion** (this skill's focus):
   - Compute `cell_has_land` for each grid cell
   - Compute `outward_dir` for each boundary land vertex
   - For each boundary edge: create top/bottom vertex pairs via `get_cliff()`, emit quad via `emit_cliff_edge()`
   - Skip beach-zone edges (`is_beach_vertex` check)
   - Skip degenerate cliffs (height < 0.08 threshold)

6. **Laplacian smoothing**: 30 passes of XZ-only Laplacian smoothing on cliff vertices, top and bottom rows independently. Sync cliff-top positions back to terrain surface.

7. **Normal computation**: Accumulate face normals at vertices across all triangles (terrain + cliff), normalize.

8. **GLB export**: Write positions, normals, UVs, vertex colors, and indices to a binary `.glb` file.

### Key Functions

| Function | Purpose |
|----------|---------|
| `get_cliff(grid_idx, ...)` | Create or retrieve cached top/bottom vertex pair for a grid vertex. Handles height clamping, degenerate detection, UV and vertex color assignment. |
| `emit_cliff_edge(v0, v1, flip, ...)` | Emit two triangles forming a cliff wall quad between two boundary vertices. Handles winding via `flip`. |
| `is_beach_vertex(grid_idx)` | Check if a vertex should suppress cliff wall emission (beach zone or ocean vertex adjacent to beach). |
| `cell_has_land(row, col)` | Check if a grid cell contains any land vertex. Used for boundary edge detection. |

### Vertex Color Encoding for Cliff Faces

Cliff vertices use a specific vertex color encoding that the terrain shader interprets:

- **Top vertex**: `[0.45, 0.32, 0.22, 0.35]` -- warm orange-brown (sandstone/limestone), alpha 0.35
- **Bottom vertex**: `[0.28, 0.22, 0.16, 0.35]` -- darker shadow (wet rock at waterline), alpha 0.35

The alpha channel controls the terrain shader's blend between satellite texture and cliff texture via `smoothstep(0.85, 0.45, alpha)`. At alpha 0.35, the cliff texture dominates (~95%), ensuring the cliff face shows rock texture rather than satellite imagery.

### LOD Levels

Two LOD meshes are generated:
- **LOD 0** (2048x1560 grid): Used when camera is zoomed out. Lower vertex count.
- **LOD 1** (4096x3120 grid): Used when camera is zoomed in. Smoother coastlines with more vertices. Beach taper cells and smoothing passes are scaled proportionally.

Both LODs use identical extrusion logic -- the higher resolution grid naturally produces smoother cliff walls because the staircase steps are smaller.

---

## Common Pitfalls and Rules

### DO

- Always check for degenerate quads before emitting cliff geometry
- Use sentinel values (e.g., `u32::MAX`) to propagate skip decisions through cached vertex pairs
- Keep cliff base at a constant Y for clean visual appearance (no wavy bottom edge)
- Smooth cliff vertices in XZ only, never Y
- Sync smoothed cliff-top positions back to terrain surface vertices
- Use the `beach_skip` array as the single source of truth for beach-zone decisions
- Verify `BEACH_BASE_Y < Ocean Y` whenever either constant changes

### DO NOT

- Do not emit cliff walls in beach zones (beach slopes replace them)
- Do not smooth terrain surface vertices in XZ (breaks satellite texture alignment)
- Do not use angle-weighted normals unless area-weighted produces visible artifacts
- Do not assume boundary edges form a single connected chain (islands create multiple chains)
- Do not set cliff base Y above the ocean surface Y (would expose the cliff-ocean gap)
- Do not reduce smoothing passes below ~20 without adding explicit corner filling

### Debugging Checklist

1. **Invisible cliff walls**: Check winding order (`flip` parameter). Temporarily set `cull_mode = None`.
2. **Blue fringe at cliff tops**: Ocean vertices in mixed cells need cliff-like vertex colors (not pure satellite alpha).
3. **Bright ridges at beach-cliff boundary**: `MIN_LAND_H` override may be forcing beach-sloped vertices back up. Check `beach_skip` coverage.
4. **Gaps between cliff quads**: Corner filling needed, or smoothing passes too low.
5. **Staircase visible on cliff face**: Smoothing pass count too low, or smoothing not running on cliff vertices.
6. **Cliff texture swimming/stretching**: UV scale needs tuning, or the X/Z mix ratio is wrong for the cliff orientation.

---

## References

- [Terrain Rendering In Games -- Basics (Kosmonautblog)](https://kosmonautblog.wordpress.com/2017/06/04/terrain-rendering-overview-and-tricks/)
- [Red Blob Games: Polygonal Map Generation for Games](http://www-cs-students.stanford.edu/~amitp/game-programming/polygon-map-generation/)
- [Cliff Displacement/Extrusion -- Unreal Engine Forums](https://forums.unrealengine.com/t/cliff-displacement-extrusion-for-more-realistic-cliffs/143301)
- [Procedural World: Emancipation from the Skirt (LOD Crack Prevention)](http://procworld.blogspot.com/2013/07/emancipation-from-skirt.html)
- [GameDev.net: Terrain LOD and Cracks](https://www.gamedev.net/forums/topic/713470-terrain-lod-and-cracks/)
- [GameDev.net: Realistic Cliffs for Terrain](https://gamedev.net/forums/topic/556744-realistic-cliffs-caves-etc-for-terrain/)
- [NVIDIA GPU Gems 3: Generating Complex Procedural Terrains](https://developer.nvidia.com/gpugems/gpugems3/part-i-geometry/chapter-1-generating-complex-procedural-terrains-using-gpu)
- [Simplygon: Remeshing Terrain Chunks for Hierarchical LODs](https://www.simplygon.com/posts/dfa443af-04e2-4204-a866-72285f937028)
- [Nick's Voxel Blog: Dual Contouring Seams and LOD](http://ngildea.blogspot.com/2014/09/dual-contouring-chunked-terrain.html)
- [CGAL: Polygon Mesh Processing (Extrusion)](https://doc.cgal.org/latest/Polygon_mesh_processing/index.html)
- [GameDev.net: Mesh Data Structures -- Finding Boundary Edges](https://www.gamedev.net/forums/topic/715347-mesh-data-structures-finding-boundary-edges-hole/)
