---
name: geometry-polygon-offset
description: Comprehensive reference for polygon offset/buffer operations used in terrain and coastline geometry — covers inward/outward offsetting algorithms, straight skeletons, join types, Clipper library usage, and application to beach zones, borders, and cliff walls.
user-invocable: false
---

# Polygon Offset / Buffer Operations

Reference for polygon offset (inflate/deflate) algorithms and their application to terrain geometry, coastline rendering, and map borders.

---

## 1. Core Algorithm: Edge-Normal Offset

The fundamental polygon offset algorithm works by translating each edge along its inward or outward normal, then computing new vertex positions at the intersections of adjacent translated edges.

### Step-by-Step Algorithm

```
Input:  Polygon P with vertices v0, v1, ..., v(n-1) in CCW order
        Offset distance d (positive = outward/inflate, negative = inward/shrink)
Output: Offset polygon P'

For each edge e_i = (v_i, v_(i+1)):
  1. Compute edge direction:  dir_i = normalize(v_(i+1) - v_i)
  2. Compute outward normal:  n_i = (dir_i.y, -dir_i.x)   // 90-degree CW rotation for CCW polygon
  3. Translate edge outward:  e'_i passes through (v_i + d * n_i) with direction dir_i

For each vertex v_i (intersection of edges e'_(i-1) and e'_i):
  4. Compute miter direction:  miter_i = normalize(n_(i-1) + n_i)
  5. Compute miter length:     dot = miter_i . n_(i-1)
                               offset_i = miter_i * (d / dot)
  6. New vertex position:      v'_i = v_i + offset_i
```

### Miter Direction and Length

At each vertex, the offset point lies at the intersection of two translated edges. The **miter vector** is the angular bisector of the two edge normals. The miter length grows as `d / cos(half_angle)` where `half_angle` is half the angle between adjacent edges.

```
miter = normalize(normal_a + normal_b)
dot   = miter.dot(normal_a)           // = cos(half_angle)
offset = miter * (d / dot)
```

**Critical degenerate cases:**
- **Parallel edges** (`dot ~ 0`): miter length approaches infinity. Clamp `dot` to a minimum (e.g., `dot.max(0.1)`) or fall back to one normal.
- **Near-zero-length edges**: `normalize()` fails. Skip or merge degenerate edges before offsetting.
- **Collinear edges** (`normal_a == normal_b`): miter equals the shared normal, `dot = 1.0`, works correctly.

### Example: Border Mesh in This Project

The `make_border_mesh` function in `map.rs` uses exactly this algorithm:

```rust
// Edge normals
let norm_a = Vec2::new(edge_a.y, -edge_a.x);
let norm_b = Vec2::new(edge_b.y, -edge_b.x);

// Miter direction (angular bisector)
let mut miter = (norm_a + norm_b).normalize_or_zero();
if miter == Vec2::ZERO { miter = norm_a; }

// Miter length with clamped dot product
let dot = miter.dot(norm_a).max(0.5);  // clamp prevents spikes
let offset = miter * (fade_width / dot);

let outer = p + offset;   // outward offset vertex
let inner = p - offset;   // inward offset vertex
```

The `dot.max(0.5)` clamp limits the miter ratio to 2x, preventing long spikes at acute angles.

---

## 2. Inward Offset (Shrink / Deflate)

Shrinking a polygon moves edges inward. This is used for:
- Creating beach zones by shrinking coastline polygons
- Generating territory overlay margins
- Computing inner borders

### Degeneracies When Polygon Collapses

As the offset distance increases, an inward-offset polygon eventually collapses:

1. **Edge collapse**: A short edge shrinks to zero length. The two vertices at its endpoints merge into one. The offset polygon loses a vertex.

2. **Region split**: A concave polygon's inward offset can split into multiple disconnected polygons. The offset wavefront from one concave section collides with the wavefront from another section.

3. **Complete collapse**: At sufficient offset distance, the polygon shrinks to nothing (area = 0). For a convex polygon, this happens at `d = area / perimeter` (the inradius for regular polygons).

### Handling Strategies

| Strategy | Complexity | Robustness | When to Use |
|----------|-----------|------------|-------------|
| Ignore (clamp to empty) | Trivial | Low | Fixed small offsets where collapse is impossible |
| Straight skeleton | High | High | Need exact topology at every offset distance |
| Clipper library | Medium | High | Production use, handles all degeneracies automatically |
| BFS grid approximation | Low | Medium | Grid-based terrain where exact polygon offset is overkill |

### BFS Grid Approximation (Used in This Project)

Instead of computing exact polygon offsets, this project uses BFS on the terrain grid to approximate inward offsets:

- **Beach zones**: BFS propagates `beach_factor` inward from coastline edges. Each BFS ring is equivalent to one grid cell of inward offset. The `beach_skip` array marks vertices within the beach transition zone.
- **Coastal mask**: BFS propagates `coastal_distance` inward from ocean-adjacent land vertices, up to `COASTAL_MASK_CELLS = 4` cells. Each distance ring gets graduated vertex colors.
- **Taper BFS**: Extends `beach_factor` 6 cells beyond `BEACH_REGIONS` rectangle edges for gradual transition.

This avoids all polygon offset degeneracies because it operates on a discrete grid rather than continuous geometry.

---

## 3. Outward Offset (Grow / Inflate)

Growing a polygon moves edges outward. This is used for:
- Extending cliff walls outward to cover staircase gaps
- Creating coastline test points to classify edges as coastal vs. interior
- Generating soft-edged border strips

### Self-Intersection in Concave Polygons

Outward offset of a **convex** polygon is always simple (no self-intersections). But outward offset of a **concave** polygon produces self-intersections at reflex vertices (interior angle > 180 degrees):

```
Reflex vertex: the two translated edges diverge instead of converging.
The miter point ends up INSIDE the original polygon, and the offset
boundary crosses itself, creating loops that must be removed.
```

### Loop Removal

After computing raw offset vertices, self-intersections must be detected and removed:

1. **Compute all edge-edge intersections** in the raw offset boundary
2. **Build a planar graph** from the intersecting segments
3. **Extract the outermost boundary** (the valid offset polygon)
4. **Discard inner loops** (invalid self-intersection artifacts)

This is computationally expensive and numerically fragile. Use a library (Clipper2) for production code.

### Coastline Edge Classification (Used in This Project)

The `make_border_mesh` function uses a simplified outward offset to classify edges:

```rust
let coast_test_offset: f32 = 0.05; // degrees outward
let mid = (verts[i] + verts[j]) * 0.5;
let edge = (verts[j] - verts[i]).normalize_or_zero();
let outward = Vec2::new(edge.y, -edge.x);
let test_pt = mid + outward * coast_test_offset;

// If test point is NOT inside any other land polygon -> coastline edge
let on_other_land = all_polys.iter().any(|poly| point_in_polygon(test_pt, poly));
edge_is_coast.push(!on_other_land);
```

This is a point-sample test, not a full polygon offset — it avoids all self-intersection complexity by only needing one test point per edge.

---

## 4. Straight Skeleton

The straight skeleton is the geometric dual of polygon offsetting. It encodes the complete topology of all possible inward offsets.

### Wavefront Propagation Model

Imagine each edge of the polygon as a wall. All walls begin moving inward simultaneously at constant speed. The paths traced by the moving vertices form the straight skeleton.

```
Time t=0:  Original polygon edges
Time t>0:  Each edge has moved inward by distance t
           Vertices track along angular bisectors of adjacent edges

Events:
  - Edge event:  An edge collapses to zero length (two vertices meet)
                 -> Remove the edge, merge vertices, continue
  - Split event: A vertex hits a non-adjacent edge
                 -> Split the wavefront into two separate polygons
                 -> Continue propagation on each sub-polygon
```

### Angular Bisectors

Each skeleton vertex moves along the **angular bisector** of its two adjacent edge directions. The speed of a vertex depends on the angle:

```
speed = 1 / cos(half_angle)

For a 90-degree corner:  speed = 1 / cos(45) = sqrt(2) ~ 1.414
For a 170-degree corner: speed = 1 / cos(85) = 1 / 0.087 ~ 11.5  (very fast!)
For a 180-degree edge:   speed = infinity (parallel edges, no bisector)
```

This is why acute angles cause spikes in naive offset algorithms — the vertex moves much faster than the edges.

### Straight Skeleton vs. Medial Axis

| Property | Straight Skeleton | Medial Axis |
|----------|------------------|-------------|
| Vertex paths | Straight lines (angular bisectors) | Parabolic arcs (equidistant from edges AND vertices) |
| At convex vertices | Identical (both follow angular bisector) | Identical |
| At reflex vertices | Straight line bisector | Parabolic arc (equidistant from vertex) |
| Computation | Edge events + split events | Voronoi diagram of edges |
| Offset contours | Polygonal (straight edges) | Polygonal with circular arcs |

### When to Use Straight Skeleton

- When you need the complete offset topology at all distances (e.g., procedural building roofs)
- When you need mitered offsets specifically (no rounding at corners)
- When the offset polygon must remain a polygon with straight edges

### When NOT to Use

- Simple fixed-distance offsets: use edge-normal method or Clipper
- Grid-based terrain: use BFS approximation
- When rounded corners are acceptable: use Clipper with Round join type

---

## 5. Join Types at Corners

When offsetting outward at a convex vertex (or inward at a reflex vertex), the two translated edges diverge, leaving a gap. The **join type** determines how this gap is filled.

### Miter Join

Extend both translated edges until they intersect. The intersection point becomes the offset vertex.

```
Pros:  Sharp corners preserved, simple computation
Cons:  Acute angles produce extremely long spikes
       Miter length = d / cos(half_angle) -> infinity as angle -> 180
Fix:   Miter limit (max ratio of miter length to offset distance)
       When exceeded, fall back to bevel or square
```

**Miter limit**: Clipper default is 2.0. This means the miter point can be at most 2x the offset distance from the original vertex. For angles more acute than `2 * arccos(1/miter_limit)`, the join is beveled instead.

| Miter Limit | Max Miter Length | Bevel Threshold Angle |
|-------------|-----------------|----------------------|
| 1.0 | 1x offset | Always bevel (useless) |
| 1.414 | 1.414x | 90 degrees |
| 2.0 | 2x | ~60 degrees |
| 4.0 | 4x | ~29 degrees |
| 10.0 | 10x | ~11 degrees |

### Round Join

Insert a circular arc between the two translated edges. The arc is centered at the original vertex with radius equal to the offset distance.

```
Pros:  No spikes, smooth appearance, natural for organic shapes
Cons:  Increases vertex count (arc approximated by line segments)
       Arc tolerance parameter controls segment count vs. smoothness
```

**Arc tolerance** in Clipper: maximum distance between the true arc and the polygonal approximation. Smaller values = more segments = smoother arcs. Default is 0.25 (in the same units as coordinates).

### Square Join (Bevel)

Connect the endpoints of the two translated edges with a straight line (chamfer/bevel).

```
Pros:  No spikes, simple, minimal extra vertices (one per corner)
Cons:  Corners are flattened, polygon loses sharp features
```

### Comparison for Game Terrain

| Join Type | Best For | Avoid For |
|-----------|----------|-----------|
| Miter (with limit) | Country borders, territory overlays, rectangular UI elements | Coastlines with acute headlands |
| Round | Beach zone boundaries, organic coastlines | Performance-critical meshes (vertex count) |
| Square/Bevel | Quick prototyping, LOD-distant geometry | Close-up visible geometry |

---

## 6. Clipper Library (Industry Standard)

Clipper2 by Angus Johnson is the industry-standard open-source library for polygon clipping and offsetting. Available in C++, C#, Delphi, and Rust (`clipper2` crate on crates.io).

### ClipperOffset API

```
ClipperOffset
  .AddPaths(paths, JoinType, EndType)   // add polygons to offset
  .Execute(delta)                        // compute offset
  -> Vec<Path>                           // result polygons
```

**Parameters:**
- `delta > 0`: inflate (grow outward)
- `delta < 0`: deflate (shrink inward)
- `JoinType`: Miter, Round, Square (Bevel)
- `EndType`: Polygon (closed), OpenJoined, OpenButt, OpenSquare, OpenRound

**Properties:**
- `MiterLimit` (default 2.0): max miter ratio before falling back to square join
- `ArcTolerance` (default 0.25): precision of arc approximation for Round joins

### Key Behaviors

1. **Positive delta on closed polygon**: outer contour expands, inner holes contract
2. **Negative delta on closed polygon**: outer contour contracts, inner holes expand
3. **Self-intersection resolution**: automatically resolves self-intersections in the result
4. **Polygon splitting**: a shrinking polygon that splits into disconnected pieces produces multiple output paths
5. **Polygon collapse**: a polygon that shrinks to nothing produces empty output
6. **Hole handling**: holes in input polygons are properly offset (holes shrink when polygon grows, grow when polygon shrinks)

### Rust Usage (clipper2 crate)

```rust
use clipper2::*;

let polygon = vec![(0.0, 0.0), (10.0, 0.0), (10.0, 10.0), (0.0, 10.0)];
let paths = Paths::from(vec![polygon]);

let mut co = ClipperOffset::new();
co.add_paths(&paths, JoinType::Miter, EndType::Polygon);
let result = co.execute(1.5);  // inflate by 1.5 units

// result contains the offset polygon(s)
```

### When to Use Clipper vs. Manual Offset

| Scenario | Use Clipper | Use Manual |
|----------|------------|------------|
| Complex concave polygons | Yes | No (self-intersection handling too complex) |
| Simple convex polygons | Overkill | Yes (edge-normal method is sufficient) |
| Grid-based approximation | No | Yes (BFS on grid) |
| Need exact polygon output | Yes | Depends on complexity |
| Performance-critical hot path | Profile first | May be faster for simple cases |
| Polygon boolean operations too | Yes (Clipper does both) | No |

---

## 7. Minkowski Sum Approach

Polygon offsetting is mathematically equivalent to the **Minkowski sum** (for outward offset) or **Minkowski difference** (for inward offset) of the polygon with a disk of radius `d`.

### Definition

```
Outward offset:  P_offset = P (+) D_r     (Minkowski sum with disk of radius r)
Inward offset:   P_offset = P (-) D_r     (Minkowski difference / erosion)
```

For a **miter join**, the structuring element is not a disk but a point (the offset is computed edge-by-edge). For a **round join**, the structuring element is a disk. For a **square join**, the structuring element is a square.

### Convex Polygon Minkowski Sum

For two convex polygons, the Minkowski sum is computed by merging their edge sequences sorted by angle:

```
1. Sort edges of P by outward normal angle
2. Sort edges of D by outward normal angle
3. Merge the two sorted sequences
4. Concatenate edge vectors in merged order
5. Trace the path from start to build the sum polygon
```

Time complexity: O(n + m) for convex polygons with n and m vertices.

### Non-Convex Polygon Minkowski Sum

For non-convex polygons, the Minkowski sum is much more complex:
1. Decompose the polygon into convex pieces
2. Compute pairwise Minkowski sums of each piece with the disk
3. Compute the union of all pairwise sums

This is O(n^2 m^2) in the worst case. Use Clipper or CGAL for production implementations.

### Robustness Concerns

- **Floating-point precision**: repeated vector addition accumulates error. For exact results, use rational arithmetic (as CGAL does).
- **Degenerate inputs**: zero-length edges, collinear vertices, and self-intersecting polygons all require special handling.
- **Coordinate scaling**: Clipper internally uses integer coordinates for robustness. Scale floating-point coordinates to integers (e.g., multiply by 1000), offset, then scale back.

---

## 8. Application to Terrain: Beach Zones

### Goal

Create smooth beach transition zones by conceptually "shrinking" the coastline polygon inward, with the strip between the original coastline and the shrunk polygon becoming the beach.

### Approach Used in This Project (BFS Grid Approximation)

Rather than computing exact polygon offsets, the project uses BFS on the terrain grid:

```
1. Identify coastline vertices (land vertices adjacent to ocean)
2. BFS inward from coastline, propagating beach_factor
3. Each BFS ring = ~1 grid cell of inward offset
4. beach_factor decreases with distance from coast
5. Vertices with beach_factor > 0 get:
   - Height ramped down toward BEACH_BASE_Y (-0.35)
   - Vertex colors blended toward sand tones
   - Alpha reduced for shader beach/cliff texture blending
```

### Why BFS Instead of Polygon Offset

1. **Grid alignment**: Terrain is a regular grid. BFS naturally produces grid-aligned results.
2. **No degeneracies**: BFS on a grid never produces self-intersections or collapses.
3. **Variable width**: Beach width varies naturally with coastline geometry (wider in coves, narrower on headlands) because BFS propagates from all coastline edges simultaneously.
4. **Integration with vertex colors**: BFS distance directly maps to graduated vertex color values.
5. **Performance**: BFS is O(n) in grid cells. Polygon offset on complex coastlines would be much slower.

### Constants That Must Stay in Sync

```
BEACH_BASE_Y    = -0.35   // in gen_cliff_glb.rs — must be < ocean Y
Ocean Y         = -0.25   // in spawn_sea (sea.rs) — water surface level
CLIFF_BASE_Y    = -0.20   // in gen_cliff_glb.rs — cliff wall bottom
BEACH_REGIONS   = [...]   // in sea.rs — must cover actual coastline coordinates
COASTAL_MASK_CELLS = 4    // BFS depth for coastal vertex color blending
```

---

## 9. Application to Borders: Soft-Edged Country Borders

### Goal

Draw soft-edged borders around country polygons that fade from opaque at the polygon edge to transparent at a fixed distance inward and outward.

### Approach Used in This Project (Miter Offset Strip)

The `make_border_mesh` function creates a triangle strip by offsetting each vertex inward and outward:

```
For each polygon vertex:
  1. Compute edge normals for adjacent edges
  2. Compute miter direction (bisector of normals)
  3. Clamp dot product to 0.5 minimum (miter limit = 2x)
  4. Compute outer vertex: v + miter * (width / dot)
  5. Compute center vertex: v (on polygon edge)
  6. Compute inner vertex: v - miter * (width / dot)

Triangle strip: outer(alpha=0) -> center(alpha=1) -> inner(alpha=0)
```

### Coastline Edge Skipping

Border strips must NOT be drawn over coastline edges (they would obscure cliff/beach rendering). Each edge is classified:

```
For each edge midpoint:
  1. Compute outward-offset test point (0.05 units outward)
  2. Test if point is inside ANY other land polygon
  3. If not -> coastline edge -> skip border triangles for this edge
```

### Why Not Use Clipper for Borders

The border mesh is a triangle strip with per-vertex alpha, not a filled polygon. Clipper produces offset polygon contours, but the border needs the spatial relationship between original edge, inner offset, and outer offset at each vertex. The manual miter calculation preserves this relationship directly.

---

## 10. Application to Cliff Walls: Outward Offset

### Goal

Cliff walls are vertical quads extruded downward from coastline edges. To cover staircase artifacts from the terrain grid, cliff walls may need to be offset slightly outward from the exact polygon boundary.

### Approach

Cliff walls in `gen_cliff_glb.rs` are generated at grid cell boundaries where land meets ocean. The cliff wall geometry:

```
For each land->ocean edge on the grid:
  1. Top vertices: land vertex positions at terrain height
  2. Bottom vertices: same XZ position, Y = CLIFF_BASE_Y (-0.2)
  3. Emit two triangles forming a vertical quad
```

Near beach zones, cliff walls extend deeper: bottom Y = `BEACH_BASE_Y` (-0.35) instead of `CLIFF_BASE_Y` (-0.2), to cover the deeper beach slope.

### Outward Offset for Gap Coverage

If cliff walls need outward offset to cover grid staircase gaps:

```
For each cliff edge:
  1. Compute edge normal pointing away from land (toward ocean)
  2. Offset top and bottom vertices by small amount along normal
  3. This pushes the cliff face slightly into the ocean volume
  4. Ocean surface plane at Y=-0.25 covers the base of the offset wall
```

**Key constraint from CLAUDE.md**: Do NOT move terrain surface vertices in XZ. The terrain grid must remain locked to geographic coordinates. Only cliff wall geometry (which is separate from the terrain surface) may be offset outward.

---

## 11. Robust Implementation Considerations

### Floating-Point Precision

| Issue | Mitigation |
|-------|-----------|
| Accumulated rounding in vertex chains | Use double precision (f64) for offset computation, convert to f32 for mesh output |
| Near-zero edge lengths | Skip edges shorter than epsilon, merge vertices closer than epsilon |
| Nearly-parallel adjacent edges | Clamp `dot` product minimum (e.g., `dot.max(0.1)`) to bound miter length |
| Self-intersection from precision loss | Use Clipper (integer arithmetic internally) for complex polygons |

### Parallel Edges

When two adjacent edges are nearly parallel (angle ~ 180 degrees):
- The miter direction is well-defined (perpendicular to both edges)
- The miter length approaches `d / 1.0 = d` (normal offset)
- But `normalize(n_a + n_b)` can be numerically unstable when `n_a ~ n_b`
- **Fix**: If `|n_a + n_b| < epsilon`, use `n_a` directly as the miter

### Acute Angles (Spikes)

When two adjacent edges form an acute angle (< 60 degrees exterior):
- Miter length exceeds `2 * d`
- The offset vertex is far from the original polygon
- **Fix 1**: Miter limit (clamp `dot` minimum, e.g., `dot.max(0.5)` limits to 2x)
- **Fix 2**: Fall back to bevel join (connect translated edge endpoints directly)
- **Fix 3**: Fall back to round join (arc between translated edges)

### Winding Order

- **CCW polygon + positive offset** = outward (inflate)
- **CCW polygon + negative offset** = inward (deflate)
- **CW polygon**: normals point inward, so signs are reversed
- **Always normalize winding order** before offsetting. Compute signed area: positive = CCW, negative = CW.

```rust
fn signed_area(verts: &[Vec2]) -> f32 {
    let n = verts.len();
    let mut area = 0.0;
    for i in 0..n {
        let j = (i + 1) % n;
        area += verts[i].x * verts[j].y;
        area -= verts[j].x * verts[i].y;
    }
    area * 0.5
}
// positive -> CCW, negative -> CW
```

### Self-Intersection Detection

For outward offset of concave polygons, check for self-intersections:

```rust
fn segments_intersect(a1: Vec2, a2: Vec2, b1: Vec2, b2: Vec2) -> Option<Vec2> {
    let d1 = a2 - a1;
    let d2 = b2 - b1;
    let cross = d1.x * d2.y - d1.y * d2.x;
    if cross.abs() < 1e-10 { return None; } // parallel
    let t = ((b1 - a1).x * d2.y - (b1 - a1).y * d2.x) / cross;
    let u = ((b1 - a1).x * d1.y - (b1 - a1).y * d1.x) / cross;
    if t >= 0.0 && t <= 1.0 && u >= 0.0 && u <= 1.0 {
        Some(a1 + d1 * t)
    } else {
        None
    }
}
```

For production use, prefer Clipper which handles all self-intersection cases robustly.

---

## 12. Algorithm Selection Guide

| Scenario | Recommended Approach | Reason |
|----------|---------------------|--------|
| Simple convex polygon, fixed offset | Edge-normal with miter | Fast, simple, no degeneracies |
| Complex concave polygon | Clipper2 library | Handles self-intersections, splitting, collapse |
| Grid-based terrain (beach zones) | BFS on grid | Natural grid alignment, no polygon degeneracies |
| Border strip with alpha fade | Manual miter offset strip | Need per-vertex alpha, not just polygon contour |
| Coastline edge classification | Point-sample outward test | Only need boolean in/out, not full offset polygon |
| Procedural roof generation | Straight skeleton | Need complete offset topology at all distances |
| Variable-width offset | Weighted straight skeleton | Different edges move at different speeds |
| CAD / manufacturing tolerance | Clipper2 or CGAL | Need exact, robust results with hole handling |

---

## References

- [An Algorithm for Inflating and Deflating Polygons (Baeldung)](https://www.baeldung.com/cs/polygons-inflating-deflating)
- [A Survey of Polygon Offsetting Strategies (Cacciola)](http://fcacciola.50webs.com/Offseting%20Methods.htm)
- [CGAL 2D Straight Skeleton and Polygon Offsetting](https://doc.cgal.org/latest/Straight_skeleton_2/index.html)
- [Clipper2 Overview (Angus Johnson)](https://www.angusj.com/clipper2/Docs/Overview.htm)
- [ClipperOffset Class Documentation](http://www.angusj.com/clipper2/Docs/Units/Clipper.Offset/Classes/ClipperOffset/_Body.htm)
- [Clipper2 JoinType Documentation](http://www.angusj.com/clipper2/Docs/Units/Clipper/Types/JoinType.htm)
- [Clipper2 Rust Crate](https://docs.rs/clipper2/)
- [Clipper2 GitHub Repository](https://github.com/AngusJohnson/Clipper2)
- [CGAL 2D Minkowski Sums](https://doc.cgal.org/latest/Minkowski_sum_2/index.html)
- [Minkowski Sum of Convex Polygons (CP-Algorithms)](https://cp-algorithms.com/geometry/minkowski.html)
- [Computing Mitered Offset Curves Based on Straight Skeletons](https://www.tandfonline.com/doi/full/10.1080/16864360.2014.997637)
- [Step-By-Step Straight Skeletons (Eder, SoCG 2020)](https://drops.dagstuhl.de/storage/00lipics/lipics-vol164-socg2020/LIPIcs.SoCG.2020.76/LIPIcs.SoCG.2020.76.pdf)
- [polygon-offset npm library](https://github.com/w8r/polygon-offset)
- [Polygon Offset in Berkeley IDETC/CIE 2005](https://mcmains.me.berkeley.edu/pubs/DAC05OffsetPolygon.pdf)
