---
name: triangulation
description: Reference for polygon triangulation algorithms used in terrain and country polygon mesh generation, covering ear clipping, Delaunay, CDT, quality metrics, subdivision strategies, and Rust crate selection.
user-invocable: false
---

# Polygon Triangulation for Terrain and Country Meshes

This skill covers the theory, trade-offs, and practical application of polygon triangulation algorithms as used in this project for country polygon rendering and terrain mesh generation.

---

## 1. Ear Clipping

### How It Works

Ear clipping is the simplest polygon triangulation algorithm. It operates on a simple (non-self-intersecting) polygon defined as an ordered list of vertices.

**Core concept:** An "ear" is a triangle formed by three consecutive vertices (prev, curr, next) where:
1. The vertex `curr` is **convex** (the interior angle is less than 180 degrees).
2. No other polygon vertex lies **inside** the triangle (prev, curr, next).

**Algorithm steps:**
1. Determine the polygon's winding order (CCW or CW) by computing the signed area.
2. Maintain a list of remaining vertex indices.
3. For each vertex in the remaining list, test whether it forms an ear:
   - Compute the cross product `(curr - prev) x (next - curr)` to check convexity relative to the known winding.
   - For every other remaining vertex, test if it falls inside the triangle using barycentric coordinates.
4. If an ear is found, emit the triangle (prev, curr, next) and remove `curr` from the remaining list.
5. Repeat until 3 vertices remain; emit the final triangle.
6. Safety: cap iterations at O(n^2) to prevent infinite loops on degenerate input.

**Fallback:** If no ear is found (degenerate polygon, near-collinear vertices, floating-point issues), fall back to fan triangulation from vertex 0 as a last resort.

### Complexity

- **Time:** O(n^2) for the basic algorithm. Each ear search is O(n) for the point-in-triangle tests, and up to n ears must be clipped.
- **Space:** O(n) for the remaining vertex list and output indices.
- **Optimized variants** maintain separate lists for convex, reflex, and ear-tip vertices, reducing inner-loop work. These bring practical performance closer to O(n) for most real-world polygons, though worst-case remains O(n^2).

### When to Use

- Polygons with fewer than ~100 vertices (country boundaries in this project have 20-80 vertices).
- When simplicity and zero external dependencies matter more than triangle quality.
- When the output will be further subdivided (subdivision improves quality regardless of initial triangulation).
- When the polygon has no holes.

### Limitations

- Produces **skinny triangles** frequently. The algorithm greedily clips the first valid ear it finds without considering triangle quality.
- Does not natively handle polygons with holes (requires bridge insertion preprocessing).
- O(n^2) becomes problematic above ~1000 vertices.

---

## 2. Delaunay Triangulation

### Definition

A Delaunay triangulation of a point set maximizes the minimum angle across all triangles. Equivalently, for every triangle in the mesh, the circumscribed circle (circumcircle) contains no other points from the set.

### Key Properties

- **Max-min angle:** Among all possible triangulations of a point set, the Delaunay triangulation maximizes the smallest angle. This directly minimizes skinny triangles.
- **Circumcircle property:** No point lies strictly inside the circumcircle of any triangle. This is the defining property and the basis for most algorithms.
- **Unique** (for points in general position; degenerate cases with co-circular points may have multiple valid triangulations).
- **Locally optimal:** Every edge in a Delaunay triangulation satisfies the "empty circumcircle" condition. Flipping any edge would produce a worse minimum angle.

### Algorithms

| Algorithm | Complexity | Notes |
|-----------|-----------|-------|
| Bowyer-Watson | O(n log n) average | Incremental insertion; most common in practice |
| Divide and conquer | O(n log n) | Theoretically optimal; harder to implement |
| Fortune's sweep line | O(n log n) | Good for large point sets; uses parabolic front |

### When to Use

- When you have a **point cloud** (not a polygon boundary) and want high-quality triangles.
- Terrain heightfield generation from scattered elevation samples.
- When triangle quality matters more than preserving specific edges.

### Limitation

Standard Delaunay triangulation works on point sets, **not polygons**. It does not guarantee that polygon edges appear in the output. A country boundary edge might be "flipped" away by the Delaunay criterion.

---

## 3. Constrained Delaunay Triangulation (CDT)

### Definition

CDT is a Delaunay triangulation that **preserves specified constraint edges** (such as polygon boundaries). It maximizes the minimum angle **subject to the constraint** that certain edges must appear in the output.

### How It Differs from Standard Delaunay

| Property | Delaunay | CDT |
|----------|----------|-----|
| Input | Point set | Point set + constraint edges |
| Edge preservation | No guarantee | Constraint edges always present |
| Circumcircle property | Strict (no point inside any circumcircle) | Relaxed (points may be inside circumcircle if blocked by a constraint edge) |
| Triangle quality | Optimal for given points | Optimal subject to constraints |
| Polygon triangulation | Not directly applicable | Directly triangulates polygon interiors |

### The "Visibility" Condition

In CDT, two points are "visible" to each other if the line segment between them does not cross any constraint edge. The modified Delaunay condition is: for each triangle, its circumcircle contains no point that is **visible** from all three vertices. Constraint edges act as barriers.

### Applications

- **Terrain mesh generation:** Constraint edges represent breaklines (cliffs, ridges, rivers, coastlines). The triangulation respects these features while maximizing triangle quality elsewhere.
- **GIS:** Breaklines in Geographic Information Systems are exactly constraint edges in CDT. Cliffs, roads, and shorelines must appear as mesh edges for correct terrain rendering.
- **Polygon fill with quality:** Given a polygon boundary as constraints, CDT produces the highest-quality triangulation that respects the boundary.

### When to Use

- When you need polygon edges preserved AND good triangle quality.
- When triangulating complex polygons with many vertices (> 100).
- When the mesh will be used for interpolation (heightmap sampling, vertex color blending) where skinny triangles cause visible artifacts.

---

## 4. Triangle Quality Metrics

### Why Quality Matters for Rendering

GPU rasterizers interpolate vertex attributes (position, UV, color, normal) across triangle faces using barycentric coordinates. Triangle shape directly affects interpolation accuracy:

| Triangle Shape | Interpolation Quality | Visual Effect |
|---------------|----------------------|---------------|
| Equilateral | Excellent | Smooth gradients, accurate sampling |
| Moderately elongated | Acceptable | Minor interpolation bias |
| Skinny/sliver | Poor | Banding, color jumps, texture swimming |
| Degenerate (near-zero area) | Broken | Z-fighting, flickering, holes |

### Common Metrics

**Minimum Angle (theta_min)**
- The smallest interior angle of the triangle.
- Ideal: 60 degrees (equilateral). Acceptable: > 20 degrees. Bad: < 10 degrees.
- Delaunay triangulation maximizes this metric globally.
- Most intuitive metric; directly correlates with interpolation quality.

**Aspect Ratio (AR)**
- Defined as `2 * r_inscribed / r_circumscribed` where r_inscribed is the inradius and r_circumscribed is the circumradius.
- Range: 0 to 1. Equilateral = 1, degenerate = 0.
- Alternative definition: `longest_edge / shortest_altitude`. Equilateral = 1.15, bad triangles > 5.

**Edge Ratio**
- `longest_edge / shortest_edge`.
- Equilateral = 1. Acceptable: < 3. Bad: > 5.
- Quick to compute; good for flagging obviously bad triangles.

**Condition Number**
- Based on the Jacobian matrix mapping from reference to actual triangle.
- Range: 1 (equilateral) to infinity (degenerate).
- Most mathematically rigorous; used in finite element analysis.

### Skinny Triangle Problems in This Project

Skinny triangles cause specific rendering artifacts in terrain/country meshes:

1. **Vertex color bleeding:** When a skinny triangle spans a coastline, one vertex has "land" color and the distant vertex has "ocean" color. The long, thin interpolation zone creates a visible color streak rather than a clean boundary.

2. **Heightmap aliasing:** A skinny triangle samples heights at its three vertices. If the triangle is elongated along a contour line, the interior interpolates poorly across the perpendicular direction, creating flat "shelves" instead of smooth slopes.

3. **Z-fighting:** Near-degenerate triangles (area approaching zero) produce inconsistent depth values, causing flickering when overlapping geometry (territory overlay, ocean surface) is rendered at similar depths.

4. **Texture swimming:** UV interpolation across a skinny triangle is non-uniform. Moving the camera slightly shifts which texels are sampled, producing a "swimming" or "shimmering" effect on the texture.

---

## 5. Triangulating Polygons with Holes

### The Problem

Ear clipping works on simple polygons (a single closed boundary). Country polygons in this project do not have holes, but the general technique is important for:
- Islands within lakes
- Enclaves (country A entirely surrounded by country B)
- UI panels with cutout regions

### Bridge Insertion

The standard approach converts a polygon-with-holes into a single "degenerate" polygon by inserting bridge edges:

1. **Sort holes** by their leftmost (minimum-x) vertex.
2. For each hole, find the **closest visible vertex** on the outer boundary (or an already-bridged hole).
3. Insert a **bridge edge**: duplicate the two connection vertices and splice the hole's vertex sequence into the outer boundary at the connection point.
4. The bridge edge appears twice with opposite orientations, creating a zero-width "slit" that the ear clipper traverses.

**Result:** A single polygon with `n_outer + sum(n_hole_i) + 2 * num_holes` vertices that can be triangulated by standard ear clipping.

### CDT Alternative

CDT handles holes natively:
1. Add all boundary edges (outer + holes) as constraints.
2. Run CDT on all vertices.
3. Remove triangles that fall inside holes (determined by a flood-fill from a known-interior seed point, or by winding number tests).

This approach is simpler to implement correctly and produces better-quality triangles.

---

## 6. Subdivision Strategies

### Edge-Based Subdivision (Used in `triangulate.rs`)

The `subdivide_triangles` function in this project performs iterative longest-edge bisection:

1. For each triangle, compute edge lengths in the XZ (lon/lat) plane.
2. If the longest edge exceeds `max_edge`, split it by inserting a midpoint vertex.
3. The triangle becomes two triangles sharing the new midpoint.
4. A **midpoint cache** (keyed by canonical edge pair) ensures shared edges produce a single midpoint vertex, maintaining mesh watertightness.
5. Repeat until no edge exceeds the threshold.

**Purpose:** Country polygons from ear clipping produce large, flat triangles. Subdivision creates enough vertices for smooth heightmap displacement. Without it, a triangle spanning a mountain range would interpolate linearly between its three corners, missing all intermediate terrain detail.

**Key detail:** Subdivision operates in the XZ plane (geographic coordinates), not Y (height). The Y values of midpoints are interpolated from parent vertices but will be overwritten by heightmap sampling in the next pipeline step.

### Center-Fan Subdivision (Used in `gen_cliff_glb.rs`)

For the terrain grid mesh, cells near coastlines and beaches use center-fan subdivision instead of the standard 2-triangle quad split:

**Standard quad (2 triangles):**
```
TL---TR        TL---TR
|  / |    or   | \  |
| /  |         |  \ |
BL---BR        BL---BR
```
The diagonal edge creates an asymmetry. On terrain slopes, this diagonal can produce visible ridges.

**Center-fan (4 triangles):**
```
TL---TR
|\ /|
| C |
|/ \|
BL---BR
```
A center vertex C (average of all four corners) connects to all four edges, producing 4 triangles: TL-TR-C, TR-BR-C, BR-BL-C, BL-TL-C.

**Why center-fan prevents T-junctions:**
If one quad is subdivided and its neighbor is not, the midpoint vertex on the shared edge has no corresponding vertex in the neighbor. This creates a T-junction: a vertex that sits on another triangle's edge but is not part of that triangle's vertex list. The GPU sees a gap (crack) at T-junctions.

Center-fan subdivision avoids this because:
- All four original corner vertices remain in place (shared edges with neighbors are unchanged).
- The center vertex is interior to the quad and connects only to this quad's own corners.
- No new vertices are placed on shared edges.

**When it is used:** Cells where any vertex has `beach_factor > 0` or `coastal_dist < COASTAL_MASK_CELLS`. These are exactly the cells where terrain height varies rapidly (beach slopes, cliff transitions) and where the 2-triangle diagonal would create visible artifacts.

---

## 7. How This Project Uses Triangulation

### Country Polygon Meshes (`triangulate.rs` + `map.rs`)

**Pipeline:**
1. Country boundary vertices (lon/lat `Vec2` arrays from `geo/*.rs`) are passed to `triangulate_polygon()`.
2. Ear clipping produces triangle indices over the original vertices.
3. Positions are mapped to 3D: `[lon, y_height, -lat]` (negated Z so north is up).
4. `subdivide_triangles()` splits large triangles until no edge exceeds `max_edge` (typically ~0.5 degrees).
5. Subdivided positions get Y values from heightmap sampling.
6. The mesh is assigned a material (terrain texture + vertex colors).

**Why ear clipping is sufficient here:** Country polygons have 20-80 vertices. At this scale, ear clipping runs in microseconds. The subsequent subdivision pass improves triangle quality by breaking up skinny triangles. Country polygons have no holes (islands are separate polygon entries, e.g., "France" and "France (Corsica)").

### Terrain Grid Mesh (`gen_cliff_glb.rs`)

**Pipeline:**
1. A regular grid of vertices covers the map area, spaced at fixed lon/lat intervals.
2. Each grid cell is a quad with 4 vertices (TL, TR, BL, BR).
3. Land cells are emitted as either 2 triangles (standard) or 4 triangles (center-fan) depending on proximity to coastlines.
4. Ocean-only cells are skipped entirely.
5. Mixed land/ocean cells in beach zones are skipped (ocean surface covers the gap).
6. Cliff wall geometry is extruded separately from boundary edges.

**No ear clipping here:** The terrain mesh is a structured grid. Triangulation is trivial (each quad becomes 2 or 4 triangles with known connectivity). The challenge is deciding WHICH quads to emit and HOW to subdivide them, not computing a triangulation.

### Territory Overlay (`territory_overlay.rs`)

The territory overlay reuses terrain surface vertices (from the loaded GLB) to build per-country ownership meshes. It does not re-triangulate; it uses the existing triangle indices filtered by which country owns which vertices (via the terrain country map).

---

## 8. Rust Crates for Triangulation

### `earcutr`

- **Algorithm:** Ear clipping (port of Mapbox's earcut.js).
- **Handles holes:** Yes, via bridge insertion (built-in).
- **Quality:** Low (greedy ear selection, many skinny triangles).
- **Performance:** Very fast for small-to-medium polygons. O(n^2) worst case but O(n) typical.
- **Input format:** Flat coordinate array + hole index array.
- **When to use:** Quick polygon fill where quality does not matter, or when you need hole support without CDT complexity.
- **When NOT to use:** Terrain meshes where interpolation quality matters.

### `spade`

- **Algorithm:** Constrained Delaunay Triangulation (CDT).
- **Handles holes:** Yes (add hole boundaries as constraints, then remove interior triangles).
- **Quality:** High (Delaunay-optimal subject to constraints).
- **Performance:** O(n log n) typical.
- **API:** `ConstrainedDelaunayTriangulation` struct with `insert` and `add_constraint_edge` methods.
- **When to use:** Complex polygons with holes, terrain mesh generation where triangle quality matters, any case where input edges must be preserved.
- **When NOT to use:** Overkill for simple convex or near-convex polygons with < 20 vertices.

### `delaunator`

- **Algorithm:** Standard Delaunay triangulation (Bowyer-Watson variant, port of Mapbox's delaunator).
- **Handles holes:** No.
- **Handles constraints:** No.
- **Quality:** High (full Delaunay, maximizes minimum angle).
- **Performance:** Very fast, O(n log n). One of the fastest Rust implementations.
- **Input format:** Flat coordinate array.
- **When to use:** Triangulating point clouds (e.g., scattered elevation samples, particle systems). When you do NOT need to preserve specific edges.
- **When NOT to use:** Polygon triangulation (cannot guarantee boundary edges). Anything with holes or constraints.

### Decision Matrix

| Scenario | Recommended Crate |
|----------|------------------|
| Simple polygon, < 100 vertices, no holes | Hand-rolled ear clipping (as in `triangulate.rs`) or `earcutr` |
| Polygon with holes | `earcutr` (simple) or `spade` CDT (quality) |
| Point cloud triangulation | `delaunator` |
| Terrain mesh with breaklines/coastlines | `spade` CDT |
| Polygon fill + subsequent subdivision | Hand-rolled ear clipping (subdivision fixes quality) |
| Performance-critical, millions of points | `delaunator` |

### This Project's Choice

The project uses a **hand-rolled ear clipping implementation** in `triangulate.rs` (approximately 120 lines of code). This was chosen because:

1. Country polygons are small (20-80 vertices). Performance is not a concern.
2. No external dependency. The algorithm is simple enough to implement correctly in-place.
3. Subsequent `subdivide_triangles` compensates for ear clipping's quality limitations by breaking skinny triangles.
4. No polygons with holes exist in the data (islands are separate entries).
5. The terrain grid mesh in `gen_cliff_glb.rs` does not use polygon triangulation at all (it is a structured grid).

If the project ever needs to triangulate complex polygons with holes (e.g., merged multi-polygon countries, UI cutouts), switching to `earcutr` or `spade` would be the appropriate upgrade path.

---

## 9. Reference Links

- [Triangulation by Ear Clipping (Geometric Tools)](https://www.geometrictools.com/Documentation/TriangulationByEarClipping.pdf) -- Definitive reference for ear clipping with holes
- [Ear-Clipping Based Algorithms of Generating High-Quality Polygon Triangulation (arXiv)](https://arxiv.org/pdf/1212.6038) -- Improved ear clipping with Delaunay edge-flip refinement
- [Constrained Delaunay Triangulation (Wikipedia)](https://en.wikipedia.org/wiki/Constrained_Delaunay_triangulation) -- CDT definition, properties, and applications
- [Polygon Triangulation via Ear-Clipping with Delaunay Refinement](http://lin-ear-th-inking.blogspot.com/2011/04/polygon-triangulation-via-ear-clipping.html) -- Hybrid approach combining ear clipping with Delaunay edge flips
- [Delaunay Mesh Generation (Shewchuk)](https://people.eecs.berkeley.edu/~jrs/meshbook.html) -- Authoritative book on Delaunay refinement for mesh generation
- [Triangle Quality Metrics (Coreform)](https://coreform.com/cubit_help/mesh_generation/mesh_quality_assessment/triangular_metrics.htm) -- Comprehensive list of triangle quality measures
- [Ear Clipping Triangulation Tutorial (Nils Olovsson)](https://nils-olovsson.se/articles/ear_clipping_triangulation/) -- Step-by-step implementation walkthrough
