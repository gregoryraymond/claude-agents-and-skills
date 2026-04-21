---
name: mesh-fundamentals
description: Reference for 3D mesh fundamentals relevant to terrain and game geometry generation. Covers vertex/index buffers, triangle winding, grid-based meshes, boundary detection, mixed cells, degenerate geometry, vertex color encoding, and common pitfalls. Apply when working on mesh generation, terrain geometry, or debugging visual artifacts.
user-invocable: true
allowed-tools: Read, Grep, Bash
---

# 3D Mesh Fundamentals for Terrain/Game Geometry

## Vertex Buffers and Mesh Attributes

A mesh is defined by parallel arrays of per-vertex data (vertex buffers) plus an index buffer that describes how vertices connect into triangles.

### Position Buffer (`ATTRIBUTE_POSITION` / `Float32x3`)

The fundamental attribute -- each vertex has an `[f32; 3]` world-space position `[x, y, z]`. Without positions, there is no geometry.

```rust
let positions: Vec<[f32; 3]> = vec![
    [0.0, 1.0, 0.0],   // vertex 0: peak
    [-1.0, 0.0, 0.0],  // vertex 1: bottom-left
    [1.0, 0.0, 0.0],   // vertex 2: bottom-right
];
```

### Normal Buffer (`ATTRIBUTE_NORMAL` / `Float32x3`)

Per-vertex surface normals `[nx, ny, nz]` control how lighting interacts with the surface. A flat triangle has one geometric normal; per-vertex normals allow smooth shading across triangle boundaries.

**Calculating a face normal from vertices:**

```rust
let v0 = positions[0];
let v1 = positions[1];
let v2 = positions[2];
let edge1 = [v1[0] - v0[0], v1[1] - v0[1], v1[2] - v0[2]];
let edge2 = [v2[0] - v0[0], v2[1] - v0[1], v2[2] - v0[2]];
// Cross product: edge1 x edge2
let normal = [
    edge1[1] * edge2[2] - edge1[2] * edge2[1],
    edge1[2] * edge2[0] - edge1[0] * edge2[2],
    edge1[0] * edge2[1] - edge1[1] * edge2[0],
];
// Normalize to unit length
let len = (normal[0]*normal[0] + normal[1]*normal[1] + normal[2]*normal[2]).sqrt();
let normal = [normal[0]/len, normal[1]/len, normal[2]/len];
```

The cross product order determines which side of the triangle the normal points. Swapping `edge1` and `edge2` flips the normal.

### UV Buffer (`ATTRIBUTE_UV_0` / `Float32x2`)

Texture coordinates `[u, v]` map each vertex to a position on a 2D texture. `[0.0, 0.0]` is one corner, `[1.0, 1.0]` is the opposite.

- UVs outside `[0, 1]` tile or clamp depending on sampler settings
- Terrain grids typically derive UVs from world position: `u = (lon - min_lon) / (max_lon - min_lon)`
- UV seams occur where the mapping is discontinuous -- vertices at a seam must be duplicated with different UV values

```rust
// Terrain grid UV from geographic coordinates
let u = (lon - LON_MIN) / (LON_MAX - LON_MIN);
let v = (lat - LAT_MIN) / (LAT_MAX - LAT_MIN);
let uvs: Vec<[f32; 2]> = vec![[u, v]];
```

### Vertex Color Buffer (`ATTRIBUTE_COLOR` / `Float32x4`)

RGBA per-vertex colors `[r, g, b, a]`. In this project, vertex colors encode metadata for the shader rather than literal display colors:

- **RGB channels**: Warm tint applied to satellite texture (e.g., `[0.72, 0.62, 0.48]` for cliff-colored coastal vertices)
- **Alpha channel**: Controls the satellite-vs-cliff texture blend in the terrain shader via `smoothstep(0.85, 0.45, alpha)`. Lower alpha = more cliff texture, higher alpha = more satellite texture.

```rust
// Coastal vertex: warm brown tint, low alpha = cliff texture dominates
let cliff_color: [f32; 4] = [0.72, 0.62, 0.48, 0.45];

// Interior vertex: pure white, full alpha = pure satellite texture
let interior_color: [f32; 4] = [1.0, 1.0, 1.0, 1.0];

// Beach vertex: sand-colored, alpha ramps to 0.0 at water edge
let beach_color: [f32; 4] = [0.85, 0.78, 0.65, 0.15];
```

**Critical rule**: Vertex colors interpolate linearly across a triangle face on the GPU. If one vertex has alpha 0.45 (cliff) and an adjacent vertex has alpha 1.0 (satellite), the triangle face will show a gradient. This is why ALL vertices in a mixed-cell triangle must have compatible colors -- mismatched alphas between land and ocean vertices cause blue fringe artifacts.

### Index Buffer

An array of vertex indices that defines which vertices form each triangle. Three consecutive indices = one triangle. Using indices avoids duplicating vertex data when multiple triangles share a vertex.

```rust
use bevy::render::mesh::Indices;
use bevy::render::render_resource::PrimitiveTopology;

let mut mesh = Mesh::new(PrimitiveTopology::TriangleList, default());
mesh.insert_attribute(Mesh::ATTRIBUTE_POSITION, positions);
mesh.insert_attribute(Mesh::ATTRIBUTE_NORMAL, normals);
mesh.insert_attribute(Mesh::ATTRIBUTE_UV_0, uvs);
mesh.insert_attribute(Mesh::ATTRIBUTE_COLOR, colors);
mesh.insert_indices(Indices::U32(indices));
```

**Memory savings**: A grid of 100x100 vertices has 10,000 unique vertices but ~20,000 triangles (60,000 index entries). Without an index buffer, you would need 60,000 vertices with duplicated position/normal/UV/color data. With an index buffer, you store 10,000 vertices + 60,000 `u32` indices.

**Index type**: Use `Indices::U32` for meshes with >65,535 vertices. `Indices::U16` saves memory but overflows silently if vertex count exceeds 65,535 -- triangles will reference wrong vertices, producing garbled geometry.

## Triangle Fundamentals

### Winding Order

The order in which a triangle's three vertices are listed determines its **front face**. Looking at the triangle from the front:

- **Counter-clockwise (CCW)**: Vertices go counter-clockwise. This is the default front-face convention in most engines including Bevy/wgpu.
- **Clockwise (CW)**: Vertices go clockwise. This would be the back face in the default convention.

```
CCW (front-facing in Bevy/wgpu):     CW (back-facing):

      v0                                   v0
     / \                                  / \
    /   \                                /   \
   v1---v2                              v2---v1

indices: [0, 1, 2]                   indices: [0, 2, 1]
```

The winding order is evaluated **after projection to screen space**. A triangle that is CCW in world space becomes CW when viewed from behind. This is the mechanism that makes backface culling work.

### Backface Culling

The GPU discards triangles whose projected vertices appear clockwise on screen (the back face). This is a major performance optimization -- roughly half of all triangles in a closed mesh face away from the camera and can be skipped entirely.

**When backface culling matters for terrain:**

- Terrain surface triangles should be CCW when viewed from above (camera looking down)
- Cliff wall quads need careful winding -- the outward-facing side must be CCW from the viewer's perspective
- If you mirror or negate one axis of geometry, all winding orders flip and backface culling inverts (everything disappears or shows inside-out)

**Disabling backface culling**: For double-sided geometry (e.g., thin planes, foliage), set `cull_mode: None` on the material. This costs more GPU time since both sides are rasterized.

### Normal Calculation from Cross Product

The face normal direction depends on winding order. For CCW winding (default front face):

```
normal = normalize(cross(v1 - v0, v2 - v0))
```

This gives a normal pointing "toward the viewer" for front-facing triangles. Reversing the cross product operands (`cross(v2 - v0, v1 - v0)`) flips the normal to point inward.

**Per-vertex normals for smooth shading**: Average the face normals of all triangles sharing that vertex, then normalize. This makes curved surfaces appear smooth instead of faceted.

**Terrain shortcut**: For a mostly-flat terrain grid, vertex normals can be approximated from the height gradient using finite differences:

```rust
// Finite-difference normal from height grid
let dh_dx = (height[row][col+1] - height[row][col-1]) / (2.0 * cell_width);
let dh_dz = (height[row+1][col] - height[row-1][col]) / (2.0 * cell_depth);
let normal = normalize([-dh_dx, 1.0, -dh_dz]);
```

## Grid-Based Terrain Meshes

### From 2D Grid to 3D Mesh

A terrain heightmap is a 2D grid of height values. Each grid intersection becomes a vertex. Each grid cell (4 corners) becomes 2 triangles.

```
Grid layout (rows x cols):

  row 0:  v[0]---v[1]---v[2]---v[3]
           | \    | \    | \    |
           |  \   |  \   |  \   |
           |   \  |   \  |   \  |
  row 1:  v[4]---v[5]---v[6]---v[7]
           | \    | \    | \    |
           |  \   |  \   |  \   |
           |   \  |   \  |   \  |
  row 2:  v[8]---v[9]---v[10]--v[11]
```

### Cell Indexing

The vertex at grid position `(row, col)` has index:

```rust
let idx = row * cols + col;
```

This is the fundamental mapping between 2D grid coordinates and 1D buffer indices. The reverse mapping:

```rust
let row = idx / cols;
let col = idx % cols;
```

For a grid with `rows` rows and `cols` columns:
- Total vertices: `rows * cols`
- Total cells: `(rows - 1) * (cols - 1)`
- Total triangles: `2 * (rows - 1) * (cols - 1)`

### Cell Corners

A cell at position `(row, col)` has four corner vertices:

```rust
let top_left     = row * cols + col;          // (row, col)
let top_right    = row * cols + col + 1;      // (row, col+1)
let bottom_left  = (row + 1) * cols + col;    // (row+1, col)
let bottom_right = (row + 1) * cols + col + 1; // (row+1, col+1)
```

Each cell splits into two triangles. The diagonal direction matters for terrain quality:

```rust
// Diagonal: top-left to bottom-right (common convention)
// Triangle 1 (CCW from above): top-left, bottom-left, bottom-right
indices.push(top_left as u32);
indices.push(bottom_left as u32);
indices.push(bottom_right as u32);
// Triangle 2 (CCW from above): top-left, bottom-right, top-right
indices.push(top_left as u32);
indices.push(bottom_right as u32);
indices.push(top_right as u32);
```

### Neighbor Lookup (4-connected)

Finding the four direct neighbors of a vertex at `(row, col)`:

```rust
let idx = row * cols + col;
let neighbors = [
    if col > 0        { Some(idx - 1) }    else { None },  // left
    if col < cols - 1 { Some(idx + 1) }    else { None },  // right
    if row > 0        { Some(idx - cols) }  else { None },  // up
    if row < rows - 1 { Some(idx + cols) }  else { None },  // down
];
```

This pattern is used extensively in BFS operations (beach factor propagation, coastal distance mask, taper zones).

### Neighbor Lookup (8-connected)

For operations that need diagonal neighbors too:

```rust
let neighbors_8 = [
    // Cardinals
    if col > 0        { Some(idx - 1) }    else { None },
    if col < cols - 1 { Some(idx + 1) }    else { None },
    if row > 0        { Some(idx - cols) }  else { None },
    if row < rows - 1 { Some(idx + cols) }  else { None },
    // Diagonals
    if row > 0 && col > 0               { Some(idx - cols - 1) } else { None },
    if row > 0 && col < cols - 1         { Some(idx - cols + 1) } else { None },
    if row < rows - 1 && col > 0         { Some(idx + cols - 1) } else { None },
    if row < rows - 1 && col < cols - 1  { Some(idx + cols + 1) } else { None },
];
```

## Boundary Detection

### Land/Ocean Classification

Each vertex is classified as land or ocean based on whether it falls inside any country polygon:

```rust
let is_land = |idx: usize| country[idx] != NO_COUNTRY;
```

A cell is classified by its four corner vertices. A cell where all four corners are land is a "land cell." A cell where all four are ocean is an "ocean cell." Anything else is a "mixed cell."

### Finding Boundary Edges

A boundary edge exists between two adjacent vertices where the cells on either side differ in land/ocean status. There are two orientations of boundary edges on a grid:

**Horizontal boundary edges** run along rows. A horizontal edge between vertices `(row, col)` and `(row, col+1)` is a boundary if the cell above (row-1) and the cell below (row) differ in land/ocean status:

```rust
// Horizontal boundary edges
for row in 0..rows {
    for col in 0..(cols - 1) {
        let cell_above = cell_has_land(row as isize - 1, col as isize);
        let cell_below = cell_has_land(row as isize, col as isize);
        if cell_above == cell_below {
            continue; // Not a boundary
        }
        let v0 = row * cols + col;
        let v1 = row * cols + col + 1;
        // This edge is a land/ocean boundary -- emit cliff wall here
    }
}
```

**Vertical boundary edges** run along columns. A vertical edge between vertices `(row, col)` and `(row+1, col)` is a boundary if the cell to the left (col-1) and the cell to the right (col) differ:

```rust
// Vertical boundary edges
for row in 0..(rows - 1) {
    for col in 0..cols {
        let cell_left  = cell_has_land(row as isize, col as isize - 1);
        let cell_right = cell_has_land(row as isize, col as isize);
        if cell_left == cell_right {
            continue; // Not a boundary
        }
        let v0 = row * cols + col;
        let v1 = (row + 1) * cols + col;
        // This edge is a land/ocean boundary -- emit cliff wall here
    }
}
```

Note the iteration bounds differ: horizontal edges iterate `col` to `cols - 1` (edges between adjacent columns), vertical edges iterate `row` to `rows - 1` (edges between adjacent rows).

### Cliff Wall Extrusion

Each boundary edge generates a vertical quad (2 triangles) extruded downward from the terrain surface to `CLIFF_BASE_Y`. The quad connects the top edge (at terrain height) to a bottom edge (at cliff base):

```
terrain surface
  v0_top ---- v1_top      <- at heights[v0], heights[v1]
  |          / |
  |        /   |
  |      /     |
  v0_bot ---- v1_bot      <- at CLIFF_BASE_Y (-0.2)
```

Winding order of the two triangles must face outward (toward the ocean side). The `cell_below` or `cell_right` boolean determines which side is land, which controls whether to emit `[top0, bot0, bot1, top0, bot1, top1]` or the reverse order.

## Mixed Cells

### The Problem

A "mixed cell" contains both land and ocean vertices among its four corners. When the cell's two triangles are emitted, one or both triangles will span from a high land vertex down to a low ocean vertex, creating a sloped face that may pierce the water surface.

```
Land vertex (height 0.5)
    *---------* Ocean vertex (height 0.0)
    |\        |
    | \  This triangle slopes from 0.5 to 0.0,
    |  \ piercing the ocean surface at y=-0.25
    |   \     |
    *---------*
```

These triangles are visible as spikes, teeth, or ridges poking through the ocean surface. The artifact is most visible in beach zones where cliff walls have been removed (since cliff walls normally hide these triangles).

### Cell Classification

```rust
let v_tl_land = is_land(top_left);
let v_tr_land = is_land(top_right);
let v_bl_land = is_land(bottom_left);
let v_br_land = is_land(bottom_right);

let all_land  = v_tl_land && v_tr_land && v_bl_land && v_br_land;
let all_ocean = !v_tl_land && !v_tr_land && !v_bl_land && !v_br_land;
let mixed     = !all_land && !all_ocean;
```

### Solutions

1. **Skip mixed-cell triangles entirely**: If any vertex in the cell is in a beach zone, do not emit that cell's triangles. The ocean surface plane covers the gap.

```rust
if mixed && any_vertex_is_beach {
    continue; // Skip -- ocean surface covers this area
}
```

2. **Force all vertices below ocean surface**: In beach zones, slope all cell vertices below the ocean Y so nothing pokes through. Requires `BEACH_BASE_Y < ocean_Y`.

3. **Cliff walls hide the gap**: In non-beach coastlines, vertical cliff walls cover the mixed-cell triangles. The cliff wall geometry is opaque and blocks the view of the ugly terrain triangles behind it.

### Why It Matters

Removing cliff walls (for beach zones) without also handling mixed-cell triangles ALWAYS exposes spike artifacts. These are two sides of the same coin -- cliff walls exist specifically to hide the ugly land/ocean boundary triangles.

## Degenerate Geometry

### Zero-Area (Degenerate) Triangles

A triangle with all three vertices collinear (on the same line) or with two or more vertices at the same position has zero area. Effects:

- The normal is undefined (cross product yields a zero vector)
- Rasterizer may produce no pixels, partial pixels, or flickering pixels
- Can cause NaN propagation in shaders if the normal is used for lighting calculations
- Wastes index buffer space and GPU cycles for zero visual contribution

```rust
// Check for degenerate triangle before emitting
let edge1 = [v1[0]-v0[0], v1[1]-v0[1], v1[2]-v0[2]];
let edge2 = [v2[0]-v0[0], v2[1]-v0[1], v2[2]-v0[2]];
let cross = [
    edge1[1]*edge2[2] - edge1[2]*edge2[1],
    edge1[2]*edge2[0] - edge1[0]*edge2[2],
    edge1[0]*edge2[1] - edge1[1]*edge2[0],
];
let area_sq = cross[0]*cross[0] + cross[1]*cross[1] + cross[2]*cross[2];
if area_sq < 1e-12 {
    // Degenerate -- skip this triangle
}
```

Common causes in terrain generation:
- Flattening terrain to sea level creates collinear vertices along the waterline
- Cliff walls with zero height (top and bottom at same Y)
- Grid cells where all four vertices have identical height (both triangles are valid but very thin diagonals can appear)

### T-Junctions

A T-junction occurs when a vertex lies on the edge of an adjacent triangle but is not shared by that triangle's index list. The two triangles meet geometrically but are topologically disconnected at that point.

```
Correct (shared vertex):        T-junction (crack risk):

   A---B---C                       A-------C
   |  /|  /|                       |      /|
   | / | / |                       |    /  |
   |/  |/  |                       |  / B  |    <- B sits on edge AC
   D---E---F                       | / / \ |       but AC's triangle
                                   |//    \|       does not reference B
                                   D-------F
```

**Why T-junctions cause cracks**: Floating-point rounding means the GPU may not rasterize triangle ACD's edge through point B at exactly the same pixels as the triangles that use B as a vertex. This creates single-pixel gaps (cracks) visible as flickering dark lines, especially noticeable at polygon boundaries or LOD transitions.

**Prevention**: Always share vertices at coincident positions. When subdividing one triangle but not its neighbor, insert the new vertex into both triangles' index lists.

### Terrain Grid T-Junctions

In a regular grid, T-junctions do not occur naturally because all vertices are shared via the index buffer. They appear when:

- Different mesh chunks meet at different LOD levels (one chunk has 2x the resolution of its neighbor)
- A grid is selectively subdivided (adaptive resolution near coastlines)
- Two separately-generated meshes share a geometric boundary (e.g., terrain surface + cliff walls)

In this project, cliff wall top vertices must be synced back to terrain boundary vertex positions after any smoothing pass to prevent gaps between the cliff top and terrain edge:

```rust
// Sync cliff-top positions back to terrain boundary after smoothing
for &(terrain_vidx, cliff_top_vidx) in cliff_pair.values() {
    positions[cliff_top_vidx as usize] = positions[terrain_vidx as usize];
}
```

## Bevy Mesh Construction Pattern

The standard pattern for building a mesh in this project:

```rust
use bevy::prelude::*;
use bevy::render::mesh::Indices;
use bevy::render::render_resource::PrimitiveTopology;

fn build_terrain_mesh(
    positions: Vec<[f32; 3]>,
    normals: Vec<[f32; 3]>,
    uvs: Vec<[f32; 2]>,
    colors: Vec<[f32; 4]>,
    indices: Vec<u32>,
) -> Mesh {
    let mut mesh = Mesh::new(
        PrimitiveTopology::TriangleList,
        default(),
    );
    mesh.insert_attribute(Mesh::ATTRIBUTE_POSITION, positions);
    mesh.insert_attribute(Mesh::ATTRIBUTE_NORMAL, normals);
    mesh.insert_attribute(Mesh::ATTRIBUTE_UV_0, uvs);
    mesh.insert_attribute(Mesh::ATTRIBUTE_COLOR, colors);
    mesh.insert_indices(Indices::U32(indices));
    mesh
}
```

All four attribute arrays must have the same length (one entry per vertex). The indices array length must be a multiple of 3 (three indices per triangle).

## Common Pitfalls

### 1. Index Overflow

Using `Indices::U16` when vertex count exceeds 65,535 causes indices to silently wrap around, producing garbled triangles that reference wrong vertices. Always use `Indices::U32` unless you are certain the mesh stays small.

### 2. Winding Order Flip on Mirrored Geometry

If you negate one axis (e.g., flip Z for a mirrored copy), all triangle winding orders reverse. Front faces become back faces and get culled -- the mesh becomes invisible. Fix by swapping two indices in each triangle:

```rust
// After mirroring one axis, fix winding:
for tri in indices.chunks_exact_mut(3) {
    tri.swap(1, 2); // Swap second and third index to restore CCW
}
```

### 3. UV Seams Require Vertex Duplication

A vertex at a UV discontinuity (texture seam) must appear twice in the vertex buffer with different UV coordinates. Sharing a single vertex means one UV value "wins," causing texture distortion on the other triangle.

```rust
// At a UV seam, same position needs two vertex entries:
positions.push([x, y, z]); // vertex A (left side of seam)
uvs.push([1.0, v]);        // UV at right edge of texture
positions.push([x, y, z]); // vertex B (same world position)
uvs.push([0.0, v]);        // UV at left edge of texture
// Triangles on each side reference different vertex indices
```

### 4. Mismatched Attribute Array Lengths

All vertex attribute arrays must have exactly the same length. If `positions` has 1000 entries but `normals` has 999, Bevy will panic at mesh creation. Always push all attributes together in the same loop iteration:

```rust
// Always push all attributes as a unit:
positions.push(pos);
normals.push(nrm);
uvs.push(uv);
colors.push(color);
// Never push one attribute without the others
```

### 5. Off-By-One in Grid Boundary Loops

- **Vertex iteration**: `0..rows`, `0..cols` (visits every vertex)
- **Cell iteration**: `0..(rows-1)`, `0..(cols-1)` (cells sit between vertices)
- **Horizontal edges**: row range `0..rows`, col range `0..(cols-1)`
- **Vertical edges**: row range `0..(rows-1)`, col range `0..cols`

Mixing up vertex bounds and cell bounds is a common source of out-of-bounds panics or missing geometry at grid edges.

### 6. Ocean Vertex Color Defaults

Never leave ocean vertices at `[1.0, 1.0, 1.0, 1.0]` (pure satellite texture pass-through). In mixed-cell triangles, GPU interpolation between a cliff-colored land vertex (low alpha) and a default-white ocean vertex (alpha 1.0) produces a visible blue gradient because the satellite texture contains blue ocean pixels at the coastline. Ocean vertices should be given the same vertex color as their nearest land neighbor style (cliff or beach).

### 7. Forgetting to Update All Three Geometry Layers

Coastline rendering involves three overlapping layers:

1. **Terrain surface mesh** -- grid triangles, some land, some ocean
2. **Cliff wall mesh** -- vertical quads extruded from boundary edges
3. **Ocean surface mesh** -- flat plane at y=-0.25 with wave shader

Changes to one layer (e.g., removing cliff walls for beach zones) expose the raw state of the other layers. Always consider all three when modifying coastline geometry.

## BFS Distance Propagation Pattern

When propagating distance-based attributes across the grid (beach factor, coastal mask, taper zones), use a BFS queue with distance tracking:

```rust
use std::collections::VecDeque;

let mut queue: VecDeque<(usize, u32)> = VecDeque::new();
let mut visited = vec![false; rows * cols];
let mut distance = vec![u32::MAX; rows * cols];

// Seed with boundary vertices at distance 0
for seed_idx in boundary_vertices {
    queue.push_back((seed_idx, 0));
    visited[seed_idx] = true;
    distance[seed_idx] = 0;
}

while let Some((idx, dist)) = queue.pop_front() {
    if dist >= MAX_DISTANCE {
        continue;
    }
    let row = idx / cols;
    let col = idx % cols;
    let neighbors = [
        if col > 0        { Some(idx - 1) }    else { None },
        if col < cols - 1 { Some(idx + 1) }    else { None },
        if row > 0        { Some(idx - cols) }  else { None },
        if row < rows - 1 { Some(idx + cols) }  else { None },
    ];
    for n in neighbors.into_iter().flatten() {
        if !visited[n] && is_land(n) {
            visited[n] = true;
            distance[n] = dist + 1;
            queue.push_back((n, dist + 1));
        }
    }
}
```

This pattern is used for:
- **Coastal distance masking** (4 cells deep) -- graduated vertex color tint to hide satellite/polygon misalignment
- **Beach factor propagation** -- BFS from ocean-adjacent land vertices within beach rectangles
- **Beach taper zones** -- 6-cell decay beyond beach rectangle edges for smooth beach-to-cliff transitions

## Sources

- [Vulkan Tutorial - Index Buffer](https://vulkan-tutorial.com/Vertex_buffers/Index_buffer)
- [LearnOpenGL - Face Culling](https://learnopengl.com/Advanced-OpenGL/Face-culling)
- [Back-face culling - Wikipedia](https://en.wikipedia.org/wiki/Back-face_culling)
- [OpenGL Wiki - Vertex Specification](https://www.khronos.org/opengl/wiki/Vertex_Specification)
- [UV mapping - Wikipedia](https://en.wikipedia.org/wiki/UV_mapping)
- [T-Junctions, degenerate triangles & pixel artifacts - GameDev.net](https://www.gamedev.net/forums/topic/437850-t-junctions-degenerate-triangles--pixel-artifacts/)
- [Unity Manual - Mesh vertex data](https://docs.unity3d.com/6000.3/Documentation/Manual/mesh-vertex-data.html)
- [RB Whitaker - Index And Vertex Buffers](http://rbwhitaker.wikidot.com/index-and-vertex-buffers)
- [OpenGL Wiki - Face Culling](https://www.khronos.org/opengl/wiki/Face_Culling)
