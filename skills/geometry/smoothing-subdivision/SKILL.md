---
name: smoothing-and-subdivision
description: Guide for Laplacian mesh smoothing and center-fan subdivision used in terrain/cliff/beach geometry generation. Covers pass counts, XZ constraints, scalar field smoothing, cliff vertex smoothing, T-junction prevention, and alternative approaches.
user-invocable: true
allowed-tools: Read, Grep, Bash
---

# Mesh Smoothing and Subdivision Guide

This skill covers the smoothing and subdivision techniques used in the Europe Zone Control terrain pipeline (`gen_cliff_glb.rs`). These techniques reduce grid-aligned staircase artifacts on coastlines and beach slopes.

## Laplacian Smoothing

### Formula

Standard Laplacian smoothing moves each vertex toward the average of its neighbors:

```
new_position = (1 - lambda) * old_position + lambda * avg(neighbor_positions)
```

In this project, `lambda = 0.5` everywhere:

```rust
positions[vi][0] = prev[vi][0] * 0.5 + (ax / n) * 0.5;
```

This is equivalent to: `vertex = 0.5 * self + 0.5 * avg_neighbors`.

### Convergence Behavior

- Each pass reduces high-frequency variation by approximately half.
- After N passes, the mesh converges toward the centroid of the original vertices (shrinkage problem).
- More passes = smoother surface but increased volume loss and over-smoothing.
- For open boundaries, vertices at edges smooth slower because they have fewer neighbors.
- Laplacian smoothing is a diffusion process -- it behaves like applying a heat equation to the vertex positions.

### When Laplacian Smoothing Helps

- Removing grid-aligned staircase patterns from rasterized boundaries (e.g., coastlines on a regular grid).
- Softening sharp corners in cliff wall geometry.
- Reducing noise in scalar fields (beach_factor, heightmap values).

### When Laplacian Smoothing Does NOT Help

- Structural issues like 90-degree corners where two cliff walls meet -- smoothing rounds the corner but creates visible shrinkage.
- Satellite texture misalignment -- smoothing vertex positions moves them away from their geographic coordinates, causing texture sampling to read wrong pixels.
- Eliminating staircase entirely on low-resolution grids -- the grid resolution sets a floor on achievable smoothness.

---

## CRITICAL RULE: Never Smooth Terrain Surface Vertices in XZ

**This is the single most important rule in the smoothing system.**

Terrain surface vertices sit on a regular grid where each vertex's XZ position corresponds to a specific geographic longitude/latitude. The satellite texture is sampled based on these XZ coordinates. If you move terrain vertices in XZ:

1. The vertex samples a different part of the satellite texture than the geographic point it represents.
2. Coastline features (bays, peninsulas) in the satellite image no longer align with the mesh geometry.
3. UV recalculation does NOT fix this because the satellite image is georeferenced -- the correct pixel for a given world position is fixed.

**The v18 disaster**: 40 passes of full Laplacian smoothing (including XZ) on terrain vertices near the coast caused the terrain to look "melted" -- satellite texture showed ocean blue on land vertices because they had been displaced from their geographic positions. This is documented in CLAUDE.md as a permanent prohibition.

**What IS allowed:**
- Smoothing terrain vertex **heights (Y only)** -- this changes the elevation profile without breaking texture alignment.
- Smoothing **cliff wall vertices** in XZ -- cliff walls are extruded geometry, not part of the geographic grid. Their XZ positions can move freely.
- Smoothing **scalar fields** (beach_factor, coastal_dist) that are evaluated per-grid-cell -- the grid positions don't move, only the values change.

---

## Beach Factor Smoothing (Scalar Field)

**Location**: `gen_cliff_glb.rs` lines ~577-623

**Purpose**: The beach_factor field is computed from a BFS distance to the ocean boundary. On a regular grid, BFS distances create staircase contour lines (the "Manhattan distance" artifact). Laplacian smoothing of the scalar field produces rounder, more natural contour lines without moving any vertex positions.

### Implementation Details

```rust
let smooth_passes = 6 * lod_scale;  // 6 passes at LOD0
// ...
buf[idx] = buf[idx] * 0.5 + avg * 0.5;  // lambda = 0.5
```

**Constraints enforced:**
- Only vertices INSIDE the BFS beach zone are smoothed (`0 < dist_to_ocean < beach_slope_cells`).
- Ocean-edge vertices (`dist_to_ocean == 0`) are pinned at `beach_factor = 1.0` -- never smoothed.
- When averaging, only neighbors that are also in the beach zone contribute. This prevents inland vertices (`beach_factor = 0`) from pulling the contour inward, which would cause a "dip then rise" artifact in the beach slope.
- After each pass, values are written back from the buffer to the main array only for in-zone vertices.

### Pass Count: 6

Six passes is enough to round out the worst staircase corners in the beach_factor field without over-diffusing the gradient. The beach zone is typically 8-15 cells wide, so 6 passes affect roughly half the zone depth -- smoothing the boundary shape while preserving the overall slope magnitude.

**Scaling**: `6 * lod_scale` means LOD1 (with fewer grid cells) gets proportionally fewer passes.

---

## Cliff Vertex Smoothing (XZ Only)

**Location**: `gen_cliff_glb.rs` lines ~1200-1257

**Purpose**: Cliff walls are vertical quads extruded downward from terrain boundary edges. On a regular grid, the boundary follows staircase patterns (axis-aligned steps). Smoothing the cliff vertex positions in XZ only (preserving Y heights) rounds these staircases into smoother curves.

### Implementation Details

```rust
for _ in 0..30 {
    let prev = positions.clone();
    for vi in cliff_start..total_verts {
        // Only average with same-row neighbors (top with top, bottom with bottom)
        let same: Vec<usize> = adj[vi]
            .iter()
            .filter(|&&n| (is_top[vi] && is_top[n]) || (is_bot[vi] && is_bot[n]))
            .copied()
            .collect();
        // Smooth XZ only -- Y is preserved
        positions[vi][0] = prev[vi][0] * 0.5 + (ax / n) * 0.5;
        positions[vi][2] = prev[vi][2] * 0.5 + (az / n) * 0.5;
    }
}
```

**Key design decisions:**

1. **XZ only**: Y (height) is never modified. Cliff tops stay at terrain height, cliff bottoms stay at `CLIFF_BASE_Y`. Only the horizontal silhouette is smoothed.

2. **Same-row constraint**: Top vertices only average with other top vertices; bottom vertices only average with other bottom vertices. This prevents the smoothing from collapsing the cliff wall vertically (pulling tops down or bottoms up).

3. **Adjacency from triangle connectivity**: The adjacency graph is built from the cliff triangle indices, not the grid. This means only vertices that share a triangle edge are considered neighbors -- geometrically meaningful adjacency.

4. **Post-smoothing sync**: After smoothing, cliff-top vertex XZ positions are copied back to their corresponding terrain boundary vertices:

```rust
for (&grid_idx, &(top_vi, _)) in &cliff_pair {
    if let Some(tv) = grid_to_vert[grid_idx] {
        positions[tv as usize][0] = positions[top_vi as usize][0];
        positions[tv as usize][2] = positions[top_vi as usize][2];
    }
}
```

This ensures the terrain surface edge matches the cliff wall top exactly -- no gaps or overlaps at the cliff/terrain seam.

**IMPORTANT**: This sync moves terrain boundary vertices in XZ, which is an exception to the "never move terrain in XZ" rule. It is acceptable because:
- Only the outermost boundary vertices are affected (1 cell ring).
- These vertices are at the cliff edge where satellite texture is ocean-colored anyway.
- The coastal vertex color system (BFS distance masking) ensures these vertices use cliff texture, not satellite texture.

### Pass Count: 30

Thirty passes is aggressive -- it significantly rounds staircase corners. This is acceptable for cliff walls because:
- Cliff walls use procedural cliff texture (not satellite), so XZ displacement doesn't cause texture misalignment.
- The visual priority is smooth silhouette over geographic precision.
- Cliff walls are narrow vertical strips -- shrinkage from over-smoothing is minimal in practice.

However, 30 passes cannot eliminate staircase at 90-degree corners where the coastline turns sharply. The grid resolution limits the achievable corner radius.

---

## Center-Fan Subdivision

**Location**: `gen_cliff_glb.rs` lines ~862-930

**Purpose**: Cells near coastlines and beach zones get subdivided from 2 triangles (standard quad split) into 4 triangles (center-fan pattern). This doubles the geometric resolution in the transition zone without affecting the rest of the terrain.

### How It Works

A standard grid cell has 4 corner vertices (TL, TR, BL, BR) and is split into 2 triangles along a diagonal. With center-fan subdivision:

1. A new center vertex is created at the average of the 4 corners (position, UV, and vertex color are all averaged).
2. Four triangles are emitted: TL-TR-C, TR-BR-C, BR-BL-C, BL-TL-C.

```
Standard (2 tri):     Center-fan (4 tri):
TL----TR              TL----TR
|   / |               | \  / |
|  /  |               |  C   |
| /   |               | /  \ |
BL----BR              BL----BR
```

### T-Junction Prevention

The critical property of center-fan subdivision is that it preserves all 4 original edges of the cell (TL-TR, TR-BR, BR-BL, BL-TL). The center vertex connects to all 4 corners via interior edges only.

This means a subdivided cell shares the exact same edge vertices with its non-subdivided neighbor. There is no T-junction -- no new vertex inserted along a shared edge.

**Why T-junctions are bad**: If subdivision inserted a midpoint on a shared edge, the neighboring cell would not have that vertex. During rasterization, the two cells would disagree on the edge geometry, creating visible cracks (hairline gaps that show through to the background).

**Comparison with other subdivision schemes:**

- **Catmull-Clark subdivision** splits each face into 4 sub-faces with new edge and face vertices. It produces smooth limit surfaces but creates T-junctions at the boundary between subdivided and non-subdivided regions unless the entire mesh is subdivided uniformly. Not suitable for selective per-cell subdivision.
- **Loop subdivision** works on triangle meshes (not quads) and also creates T-junctions at LOD boundaries. Same problem.
- **Center-fan** is the only scheme that allows per-cell subdivision decisions without T-junction artifacts, at the cost of lower smoothness (no limit surface properties).

### When Cells Get Subdivided

```rust
let needs_subdiv = |tl, tr, bl, br| -> bool {
    [tl, tr, bl, br]
        .iter()
        .any(|&c| beach_factor[c] > 0.0 || coastal_dist[c] < coastal_mask_cells)
};
```

A cell is subdivided if ANY of its 4 corner vertices:
- Has `beach_factor > 0.0` (is in or near a beach zone), OR
- Has `coastal_dist < coastal_mask_cells` (is near any coastline, including cliffed coasts).

This ensures higher resolution exactly where the terrain transitions between land and water -- where smooth curvature matters most.

### Attributes on Center Vertex

The center vertex inherits averaged attributes from all 4 corners:
- **Position**: arithmetic mean of the 4 corner positions (XYZ).
- **UV**: arithmetic mean of the 4 corner UVs (satellite texture coordinates).
- **Vertex color**: arithmetic mean of the 4 corner RGBA values (cliff/beach blend factors).

This averaging produces a smooth interpolation at the cell center, which is geometrically correct for a planar quad.

---

## Pass Count Guidelines

| Target | Passes | Rationale |
|--------|--------|-----------|
| Scalar fields (beach_factor) | 6 | Enough to round staircase without destroying gradient magnitude |
| Cliff vertex XZ | 15-30 | Aggressive smoothing acceptable because cliff uses procedural texture |
| Terrain vertex Y (if ever needed) | 3-6 | Conservative -- height changes affect gameplay and visual silhouette |
| Terrain vertex XZ | **NEVER** | Prohibited -- destroys satellite texture alignment (v18 lesson) |

**General rule**: Start with fewer passes and increase only if visual artifacts remain. Each doubling of passes roughly halves the remaining high-frequency content but also doubles the shrinkage.

---

## Alternative Approaches to Coastline Smoothness

When Laplacian smoothing is insufficient or inappropriate, consider these alternatives:

### SDF-Based Edge Softening (Shader)
Compute a signed distance field from the coastline in the fragment shader. Use it to blend land/water materials with a smooth transition zone. This achieves sub-pixel smoothness without modifying any mesh geometry.

**Pros**: Perfect smoothness, resolution-independent.
**Cons**: Requires SDF computation (texture or analytical), adds shader complexity.

### Higher Mesh Resolution at Coastlines
Subdivide only the cells near the coastline (already done via center-fan subdivision). Can be extended to multiple levels of subdivision, but each level quadruples triangle count in the subdivided zone.

**Pros**: More geometry = smoother silhouette.
**Cons**: Increased vertex/triangle count, diminishing returns past 2 levels.

### Outward Cliff Wall Offset
Instead of smoothing the terrain boundary, offset cliff wall geometry outward by a small amount. The cliff wall then covers the staircase steps. This is purely additive -- no existing vertices are moved.

**Pros**: Hides staircase without moving any terrain geometry.
**Cons**: Cliff walls slightly wider than the actual coastline; can create overlap artifacts if offset is too large.

### Alpha Blending at Coast Boundary (Shader)
In the terrain shader, use vertex alpha (already present via the coastal distance BFS) to blend terrain material with a transparent or water-tinted material near the coast. This softens the visual boundary without geometric changes.

**Pros**: Already partially implemented via the coastal vertex color system.
**Cons**: Limited by vertex density -- alpha changes are linear across triangles.

### Anti-Aliased Coastline Rendering
Apply post-process anti-aliasing (FXAA, TAA) that specifically targets high-contrast edges at the coastline. This is a screen-space technique that doesn't affect geometry or shaders.

**Pros**: Zero mesh/shader changes.
**Cons**: Can blur other details; TAA adds temporal ghosting; may not eliminate large staircase steps.

---

## Fixed Boundary Vertices

A common technique in mesh smoothing is to pin (freeze) certain vertices so they are never moved by the smoothing passes. This project uses boundary pinning in two places:

1. **Ocean-edge vertices in beach_factor smoothing**: Vertices at `dist_to_ocean == 0` are pinned at `beach_factor = 1.0`. This anchors the beach slope at the waterline and prevents the smooth contour from drifting inland.

2. **Implicit terrain grid pinning**: All terrain surface vertices are implicitly pinned in XZ (the critical rule above). Only cliff wall vertices are free to move in XZ.

When adding new smoothing passes, always identify which vertices must be fixed:
- Vertices at material boundaries (land/ocean edge)
- Vertices shared with other geometry systems (terrain/cliff seam)
- Vertices whose positions encode geographic data (the entire terrain grid)

---

## Summary of Smoothing in gen_cliff_glb.rs

| System | What is smoothed | Dimensions | Passes | Lambda | Constraint |
|--------|-----------------|------------|--------|--------|------------|
| Beach factor | Scalar field on grid | N/A (scalar) | 6 | 0.5 | Only in-zone vertices; pin ocean-edge at 1.0; only beach-zone neighbors |
| Cliff vertices | Cliff wall positions | XZ only | 30 | 0.5 | Same-row only (top/top, bot/bot); post-sync to terrain boundary |
| Center-fan subdiv | Cell triangulation | N/A | N/A | N/A | Only cells with beach_factor > 0 or coastal_dist < mask; preserves all shared edges |
| Terrain surface XZ | **PROHIBITED** | -- | -- | -- | Destroys satellite texture alignment (v18 lesson) |
