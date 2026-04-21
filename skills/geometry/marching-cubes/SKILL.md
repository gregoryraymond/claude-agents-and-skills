---
name: marching-cubes-isosurface
description: Comprehensive reference for the Marching Cubes algorithm and its variants (TransVoxel, Dual Contouring) for terrain/coastline mesh generation. Covers the 256-case lookup table, implementation in Rust, application to heightmap-based terrain, advantages and limitations, and how it could replace grid-based coastline geometry to eliminate staircase artifacts.
user-invocable: false
---

# Marching Cubes for Terrain and Coastline Mesh Generation

## Algorithm Overview

Marching Cubes (Lorensen & Cline, SIGGRAPH 1987) extracts a polygonal mesh representing an **isosurface** from a 3D scalar field. Given a grid of scalar values and a threshold (the **isovalue**), the algorithm produces a triangle mesh that approximates the surface where the scalar field equals the isovalue.

The core idea:
1. Divide space into a regular grid of cubes (voxels)
2. Evaluate the scalar field at each cube's 8 corners
3. Classify each corner as **inside** (below isovalue) or **outside** (above isovalue)
4. Use a precomputed lookup table to determine which edges of the cube the surface crosses
5. Interpolate along those edges to find exact vertex positions
6. Assemble triangles from the lookup table and output them

The algorithm "marches" through each cube in the grid, hence the name.

### Why It Matters for Terrain

For terrain generation, the scalar field is typically a heightmap or signed distance field. The isovalue represents **sea level** (or any contour level). The resulting mesh is the boundary between land and water -- the coastline. Unlike grid-aligned approaches that produce staircase artifacts at diagonal boundaries, Marching Cubes produces smooth, interpolated boundaries that follow the actual contour of the scalar field.

## The 256-Case Lookup Table

### Corner Classification

A cube has 8 corners. Each corner is either inside or outside the isosurface, giving 2^8 = **256 possible configurations**. These are encoded as an 8-bit index where bit `i` is 1 if corner `i` is inside the surface.

```
Corner numbering (standard convention):

        7-----------6
       /|          /|
      / |         / |
     4-----------5  |
     |  |        |  |
     |  3--------|--2
     | /         | /
     |/          |/
     0-----------1

Bit index: corner 0 = bit 0, corner 1 = bit 1, ..., corner 7 = bit 7
```

### 15 Unique Configurations (Symmetry Reduction)

Although there are 256 entries in the table, rotational symmetry, reflection symmetry, and complement symmetry (swapping inside/outside) reduce these to only **15 topologically unique cases** (sometimes cited as 14, depending on whether the empty case is counted):

| Case | Inside corners | Triangles | Description |
|------|---------------|-----------|-------------|
| 0 | none (or all) | 0 | Entirely inside or outside -- no surface |
| 1 | 1 corner | 1 | Single triangle cutting one corner |
| 2 | 2 adjacent corners (same edge) | 2 | Quadrilateral (2 triangles) |
| 3 | 2 adjacent corners (same face diagonal) | 2 | Two triangles, L-shaped cut |
| 4 | 2 opposite corners (space diagonal) | 2 | Two separate triangles |
| 5 | 3 corners (on one face) | 3 | Pentagon (3 triangles) |
| 6 | 3 corners (L-shape) | 3 | Bent surface |
| 7 | 3 corners (scattered) | 3 | Complex split |
| 8 | 4 corners (one face) | 2 | Flat quad through cube |
| 9 | 4 corners (tetrahedron) | 4 | Saddle-like surface |
| 10 | 4 corners (zigzag) | 2 | Two quads |
| 11 | 4 corners (ring) | 4 | Tunnel through cube |
| 12 | 5 corners | complement of case 5 | Mirror of 3-corner cases |
| 13 | 6 corners | complement of case 2 | Mirror of 2-corner cases |
| 14 | 7 corners | complement of case 1 | Single triangle at remaining corner |

The full 256-entry table is built by applying rotations and reflections of these 15 base cases. Each entry specifies which of the cube's 12 edges are intersected and how to connect the intersection points into triangles.

### The Two Lookup Tables

**Edge Table** (`EDGE_TABLE[256] -> u16`): Maps each cube configuration to a 12-bit mask indicating which edges are intersected. Edge `i` is intersected if bit `i` is set.

```
Edge numbering:

  Edges 0-3:  bottom face (y=0), counterclockwise from edge 0-1
  Edges 4-7:  top face (y=1), counterclockwise from edge 4-5
  Edges 8-11: vertical edges connecting bottom to top
```

**Triangle Table** (`TRI_TABLE[256][16] -> i8`): For each configuration, a list of edge index triplets forming triangles. Each group of 3 consecutive values specifies one triangle (by referencing edge indices 0-11). The list is terminated by -1. Maximum 5 triangles (15 edge indices) per cube.

Example entry for case index 1 (only corner 0 inside):
```
TRI_TABLE[1] = [0, 8, 3, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1]
// One triangle using edges 0, 8, and 3
```

### Edge Interpolation

For each intersected edge, the exact vertex position is found by **linear interpolation** between the two corner positions, weighted by their scalar values relative to the isovalue:

```
t = (isovalue - value_A) / (value_B - value_A)
vertex = position_A + t * (position_B - position_A)
```

This interpolation is what produces smooth boundaries rather than grid-aligned staircase edges.

## Application to Terrain: Heightmap as Scalar Field

### 2D Heightmap to Coastline (Marching Squares)

For a top-down map where terrain height is the scalar field and sea level is the isovalue, the 2D variant **Marching Squares** is often sufficient:

- Grid of height values (heightmap)
- Isovalue = sea level (e.g., 0.0)
- Each grid cell has 4 corners instead of 8
- 2^4 = 16 configurations (4 unique cases after symmetry)
- Output: line segments forming the coastline contour
- These line segments can then be extruded into 3D cliff walls or used to define beach transition zones

### 3D Scalar Field for Full Terrain

For terrain with overhangs, caves, or complex cliff geometry, the full 3D Marching Cubes is needed:

- Scalar field: `f(x, y, z) = terrain_density(x, y, z)`
  - Positive = solid ground
  - Negative = air/water
  - Zero = the terrain surface
- The isovalue is 0.0 (the boundary between solid and void)
- For a heightmap `h(x, z)`, the density function is: `f(x, y, z) = h(x, z) - y`
  - This produces the same surface as the heightmap but as a proper isosurface
  - Below the heightmap surface: positive (solid)
  - Above: negative (air)
  - At the surface: zero

### Coastline-Specific Application

For generating smooth coastlines from a heightmap grid:

1. Define scalar field: `f(x, z) = height(x, z) - sea_level`
2. Run Marching Squares on the 2D grid
3. The output contour IS the smooth coastline
4. Vertices lie on grid cell edges at the exact interpolated position where height = sea level
5. No staircase artifacts because the boundary follows the interpolated height contour, not the grid cell boundaries

**Comparison to current grid-based approach:**
- Current: Land/ocean classification per grid vertex, coastline follows grid cell boundaries -> staircase
- Marching Cubes/Squares: Coastline cuts through grid cells at the interpolated sea-level crossing -> smooth

## Advantages

### Guaranteed Manifold Mesh
The output mesh is always a closed, watertight manifold (no holes, no self-intersections) when the lookup table is correctly constructed. This is important for physics, rendering, and downstream processing.

### Smooth Coastlines (No Staircase)
Because vertices are interpolated along grid edges, the coastline follows the actual height contour rather than snapping to grid cell boundaries. Diagonal coastlines that would appear as zigzag staircases in a grid-based system become smooth lines.

### Well-Understood and Battle-Tested
Published in 1987, Marching Cubes is one of the most widely implemented algorithms in computer graphics. Extensive literature covers edge cases, optimizations, and extensions. Production-quality implementations exist in every major language.

### Parallelizable
Each cube is processed independently. The algorithm is trivially parallelizable across grid cells, making it ideal for GPU compute shaders or Rayon-based parallelism in Rust.

### Simple to Implement
The core algorithm is ~100 lines of code plus the lookup tables. No complex data structures beyond the grid and output triangle list.

### Adaptive Resolution
Can be combined with octree subdivision to use high resolution near the surface and low resolution in empty/solid regions, reducing triangle count by 10-100x while maintaining surface quality.

## Disadvantages

### Cannot Reproduce Sharp Features

This is the most significant limitation for terrain generation. Marching Cubes places vertices **on grid edges** via interpolation. This means:

- **Sharp cliff edges become rounded**: A 90-degree cliff edge gets smoothed into a curve because the algorithm can only place vertices along the 12 edges of each cube, never at arbitrary positions inside the cube.
- **Thin features are lost**: Features thinner than one grid cell cannot be represented.
- **Flat surfaces become slightly bumpy**: Due to the triangulation patterns, large flat areas get unnecessary triangulation with slight variations.

For this project's cliff walls, Marching Cubes would round off the sharp top edge of cliffs, making them look melted rather than crisp. This is unacceptable for the desired visual quality.

### Ambiguous Cases (Topology Errors)

The original 15-case lookup table has **ambiguous configurations** where the same corner classification can produce different valid triangulations:

- **Face ambiguity**: When a face has alternating inside/outside corners (checkerboard pattern on one face), the surface could connect either diagonal pair. Choosing inconsistently between adjacent cubes creates holes in the mesh.
- **Interior ambiguity**: When 4+ corners are inside, multiple valid surface topologies exist (e.g., one connected sheet vs. two separate sheets passing through the cube).

**Solutions:**
- **Marching Cubes 33** (Chernyaev, 1995): Extends to 33 base cases by resolving all ambiguities using the trilinear interpolant's critical points. Guarantees topologically correct output.
- **Asymptotic Decider** (Nielson & Hamann, 1991): Tests the face interpolant to resolve face ambiguities. Simpler than MC33 but does not resolve all interior ambiguities.
- **Consistent orientation rule**: Always choose the same triangulation for ambiguous cases (sacrifices topological correctness for simplicity).

### High Triangle Count

Marching Cubes generates a uniform density of triangles across the entire surface. Flat areas get the same triangle density as curved areas. For terrain, this means:
- Flat ocean floor: many unnecessary triangles
- Flat land plateaus: many unnecessary triangles
- Only coastlines and hills need the resolution

Mitigation: Post-process with mesh simplification (e.g., quadric error decimation) or use adaptive octree refinement.

### Grid-Aligned Artifacts at Low Resolution

At coarse grid resolutions, the triangulations produce visible patterns. Long thin triangles appear along near-axis-aligned surfaces. The 15-case lookup produces characteristic "wedge" shapes that are recognizable as Marching Cubes output.

Mitigation: Use finer grid resolution (increases triangle count) or apply Laplacian smoothing to the output mesh.

## TransVoxel: LOD Stitching Without Cracks

### The Problem

When a terrain system uses chunks at different LOD levels, adjacent chunks with different grid resolutions produce meshes that do not align at their shared boundary. This creates visible **cracks** (gaps between chunks) and **T-junctions** (vertices on one side that do not match vertices on the adjacent side).

### The Solution

The **TransVoxel Algorithm** (Eric Lengyel, 2009) extends Marching Cubes to seamlessly stitch meshes of differing resolutions. It operates on **transition cells** at the boundary between LOD levels.

Key concepts:

1. **Regular cells**: Standard Marching Cubes cells within a chunk's interior. Processed normally.

2. **Transition cells**: Special cells at chunk boundaries where one side has twice the resolution of the other. A transition cell has **9 vertices on the high-res face** and **4 vertices on the low-res face**, for a total of 13 sample points.

3. **512-case lookup table**: The transition cell has 9 sample points on one face, giving 2^9 = 512 possible configurations (compared to 256 for regular Marching Cubes). A dedicated lookup table provides the triangulation for each configuration.

4. **Seamless stitching**: The high-res side of a transition cell exactly matches the regular cells of the high-res chunk, and the low-res side exactly matches the regular cells of the low-res chunk. No cracks, no T-junctions.

### Architecture

```
Chunk LOD 0 (high res)    Transition cells    Chunk LOD 1 (low res)
+---+---+---+---+         +-------+           +-------+-------+
|   |   |   |   |         |      /|           |       |       |
+---+---+---+---+         |    /  |           |       |       |
|   |   |   |   |  <-->   |  /    |   <-->    |       |       |
+---+---+---+---+         |/     /|           +-------+-------+
|   |   |   |   |         |    /  |           |       |       |
+---+---+---+---+         |  /    |           |       |       |
|   |   |   |   |         |/      |           |       |       |
+---+---+---+---+         +-------+           +-------+-------+
```

### Relevance to This Project

If the Europe map terrain were chunked (e.g., for streaming or LOD), TransVoxel would ensure that chunk boundaries remain seamless as the camera zooms. However, since the current terrain is a single mesh generated offline, TransVoxel is not immediately needed but would be relevant if:
- The map were divided into LOD chunks for performance
- Different coastline regions needed different mesh resolution
- The game needed to support zooming from strategic view to tactical detail

## Implementation in Rust

### Core Data Structures

```rust
/// 3D position
type Vec3 = [f32; 3];

/// A single cube in the grid, with 8 corner positions and scalar values
struct GridCell {
    positions: [Vec3; 8],  // World-space positions of the 8 corners
    values: [f32; 8],      // Scalar field values at each corner
}

/// Output triangle (3 vertex positions + optional normals/UVs)
struct Triangle {
    vertices: [Vec3; 3],
    normals: [Vec3; 3],  // Optional: compute from face normal or interpolate
}

/// The marching cubes mesh output
struct McOutput {
    positions: Vec<Vec3>,
    normals: Vec<Vec3>,
    indices: Vec<u32>,       // Triangle indices into positions
    // Optional: UVs, vertex colors, etc.
}
```

### Lookup Tables (Abbreviated)

```rust
/// Edge table: for each of 256 cube configs, which edges are intersected
/// Each entry is a 12-bit mask (edges 0-11)
const EDGE_TABLE: [u16; 256] = [
    0x000, 0x109, 0x203, 0x30a, 0x406, 0x50f, 0x605, 0x70c,
    0x80c, 0x905, 0xa0f, 0xb06, 0xc0a, 0xd03, 0xe09, 0xf00,
    // ... 240 more entries ...
    // Full table available at paulbourke.net/geometry/polygonise/
];

/// Triangle table: for each config, up to 5 triangles (15 edge indices)
/// -1 terminates the list
const TRI_TABLE: [[i8; 16]; 256] = [
    [-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1],  // Case 0: no triangles
    [ 0, 8, 3,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1],  // Case 1: 1 triangle
    [ 0, 1, 9,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1],  // Case 2: 1 triangle
    [ 1, 8, 3, 9, 8, 1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1],  // Case 3: 2 triangles
    // ... 252 more entries ...
    // Full table available at paulbourke.net/geometry/polygonise/
];

/// The 12 edges of a cube, as pairs of corner indices
const EDGE_CORNERS: [[usize; 2]; 12] = [
    [0, 1], [1, 2], [2, 3], [3, 0],  // Bottom face
    [4, 5], [5, 6], [6, 7], [7, 4],  // Top face
    [0, 4], [1, 5], [2, 6], [3, 7],  // Vertical edges
];
```

### Core Algorithm (Pseudocode in Rust Style)

```rust
fn marching_cubes(
    grid: &ScalarGrid,  // 3D grid of scalar values
    isovalue: f32,
) -> McOutput {
    let mut positions = Vec::new();
    let mut indices = Vec::new();
    let (nx, ny, nz) = grid.dimensions();

    // March through each cube in the grid
    for z in 0..nz-1 {
        for y in 0..ny-1 {
            for x in 0..nx-1 {
                // Step 1: Build cube configuration index (8 bits)
                let mut cube_index: u8 = 0;
                for corner in 0..8 {
                    let (cx, cy, cz) = corner_offset(corner);
                    let val = grid.get(x + cx, y + cy, z + cz);
                    if val < isovalue {
                        cube_index |= 1 << corner;
                    }
                }

                // Step 2: Skip if entirely inside or outside
                let edge_mask = EDGE_TABLE[cube_index as usize];
                if edge_mask == 0 { continue; }

                // Step 3: Interpolate vertices on intersected edges
                let mut edge_vertices = [Vec3::ZERO; 12];
                for edge in 0..12 {
                    if edge_mask & (1 << edge) != 0 {
                        let [c0, c1] = EDGE_CORNERS[edge];
                        let p0 = grid.position(x, y, z, c0);
                        let p1 = grid.position(x, y, z, c1);
                        let v0 = grid.value_at_corner(x, y, z, c0);
                        let v1 = grid.value_at_corner(x, y, z, c1);

                        let t = (isovalue - v0) / (v1 - v0);
                        edge_vertices[edge] = lerp(p0, p1, t.clamp(0.0, 1.0));
                    }
                }

                // Step 4: Emit triangles from the triangle table
                let tri_entry = &TRI_TABLE[cube_index as usize];
                let mut i = 0;
                while i < 16 && tri_entry[i] != -1 {
                    let base = positions.len() as u32;
                    positions.push(edge_vertices[tri_entry[i] as usize]);
                    positions.push(edge_vertices[tri_entry[i+1] as usize]);
                    positions.push(edge_vertices[tri_entry[i+2] as usize]);
                    indices.extend_from_slice(&[base, base + 1, base + 2]);
                    i += 3;
                }
            }
        }
    }

    McOutput { positions, normals: compute_normals(&positions, &indices), indices }
}

fn lerp(a: Vec3, b: Vec3, t: f32) -> Vec3 {
    [
        a[0] + t * (b[0] - a[0]),
        a[1] + t * (b[1] - a[1]),
        a[2] + t * (b[2] - a[2]),
    ]
}
```

### 2D Variant: Marching Squares for Coastline Contours

For the specific case of extracting a coastline from a 2D heightmap, Marching Squares is simpler and more appropriate:

```rust
/// Extract coastline contour segments from a 2D heightmap
fn marching_squares_coastline(
    heights: &[f32],     // 2D grid of heights, row-major
    width: usize,
    height_dim: usize,
    sea_level: f32,
) -> Vec<[Vec3; 2]> {    // Line segments
    let mut segments = Vec::new();

    // 16-entry lookup: which of the 4 cell edges are crossed
    // Corners: 0=bottom-left, 1=bottom-right, 2=top-right, 3=top-left
    // Edges: 0=bottom, 1=right, 2=top, 3=left
    const MS_TABLE: [[i8; 4]; 16] = [
        [-1,-1,-1,-1],  // 0000: no crossing
        [ 3, 0,-1,-1],  // 0001: bottom-left inside
        [ 0, 1,-1,-1],  // 0010: bottom-right inside
        [ 3, 1,-1,-1],  // 0011: bottom two inside
        [ 1, 2,-1,-1],  // 0100: top-right inside
        [ 3, 0, 1, 2],  // 0101: AMBIGUOUS (saddle) - diagonal pair
        [ 0, 2,-1,-1],  // 0110: right two inside
        [ 3, 2,-1,-1],  // 0111: three inside
        [ 2, 3,-1,-1],  // 1000: top-left inside
        [ 2, 0,-1,-1],  // 1001: left two inside
        [ 0, 1, 2, 3],  // 1010: AMBIGUOUS (saddle) - other diagonal
        [ 2, 1,-1,-1],  // 1011: three inside
        [ 1, 3,-1,-1],  // 1100: top two inside
        [ 1, 0,-1,-1],  // 1101: three inside
        [ 0, 3,-1,-1],  // 1110: three inside
        [-1,-1,-1,-1],  // 1111: all inside, no crossing
    ];

    for y in 0..height_dim-1 {
        for x in 0..width-1 {
            let v = [
                heights[y * width + x],           // bottom-left
                heights[y * width + x + 1],       // bottom-right
                heights[(y+1) * width + x + 1],   // top-right
                heights[(y+1) * width + x],        // top-left
            ];

            let mut case_idx: u8 = 0;
            for i in 0..4 {
                if v[i] < sea_level { case_idx |= 1 << i; }
            }

            let entry = MS_TABLE[case_idx as usize];
            if entry[0] == -1 { continue; }

            // Interpolate edge crossings and emit line segment(s)
            // ... (interpolation logic similar to 3D case)
        }
    }

    segments
}
```

### Rust Crates Available

| Crate | Description | Notes |
|-------|-------------|-------|
| `marching-cubes` | Basic MC implementation | Simple API, no LOD support |
| `isosurface` | MC + Marching Tetrahedra + Surface Nets | Multiple algorithms, good for comparison |
| `transvoxel` | TransVoxel implementation | LOD stitching, Lengyel's algorithm |
| `splashsurf_lib` | Production MC with spatial hashing | Optimized for particle fluid surfaces |
| `building-blocks` | Voxel toolkit with MC | Full voxel pipeline, chunk management |

## How This Could Replace the Current Grid-Based Coastline

### Current Approach (Grid-Based)

The current `gen_cliff_glb.rs` pipeline:
1. Classifies each grid vertex as land or ocean based on polygon containment
2. Emits terrain triangles for land cells, skips ocean cells
3. Emits cliff wall quads at land-ocean boundaries (vertical extrusion)
4. The coastline follows grid cell boundaries exactly -> **staircase artifacts**

### Proposed Marching Squares Replacement

Replace step 2-3 with Marching Squares to extract the coastline contour:

1. Keep the heightmap grid and land/ocean classification
2. Define a scalar field: `f(x, z) = signed_distance_to_coastline(x, z)` or simply `f(x, z) = height(x, z) - sea_level`
3. Run Marching Squares on the 2D grid to extract coastline contour segments
4. The contour vertices lie on grid EDGES at the interpolated sea-level crossing point
5. Use these smooth contour vertices (not grid vertices) as the cliff wall top edge
6. Terrain triangles on the land side connect to the contour vertices
7. Cliff walls extrude downward from the contour vertices

**Benefits:**
- Coastline follows the actual height contour, not grid cell boundaries
- Diagonal coastlines become smooth lines, not staircases
- Beach zones get smooth organic edges
- Cliff top edge is smooth and natural-looking
- Minimal change to existing pipeline (only the boundary extraction changes)

**Implementation sketch:**

```rust
// In gen_cliff_glb.rs, replace the current boundary detection with:

// 1. Build scalar field from height data
let scalar: Vec<f32> = heights.iter()
    .map(|h| h - SEA_LEVEL)
    .collect();

// 2. Run marching squares to get coastline segments
let coastline_segments = marching_squares(&scalar, grid_width, grid_height);

// 3. Chain segments into polylines
let coastline_polylines = chain_segments(coastline_segments);

// 4. Use polyline vertices as cliff wall top edges (smooth!)
for polyline in &coastline_polylines {
    emit_cliff_wall_strip(polyline, CLIFF_BASE_Y);
}

// 5. Retriangulate land terrain connecting to coastline vertices
// (Constrained Delaunay triangulation with coastline as constraint)
```

### Challenges

1. **Constrained Delaunay triangulation**: After extracting the coastline contour, the land-side terrain must be retriangulated to connect to the new contour vertices. This requires a constrained Delaunay triangulation (CDT) library. Rust options: `spade`, `geo`, `delaunator`.

2. **Vertex attributes**: The new contour vertices need interpolated vertex colors, UVs, and normals. These must be computed from the adjacent grid vertices.

3. **Beach zones**: Beach factor interpolation along the new contour vertices. Since contour vertices lie between grid vertices, beach_factor must be interpolated too.

4. **Multiple contours**: Islands and lakes produce separate closed contours. The algorithm must handle multiple disjoint coastlines.

5. **Interaction with existing systems**: Country borders, territory overlays, and the fog-of-war system all reference the grid-based geometry. These would need updates to work with the new mesh topology.

## When NOT to Use Marching Cubes

### Sharp Cliff Edges Need Dual Contouring

Marching Cubes places vertices **on grid edges only**. This fundamental constraint means it **cannot represent sharp features** -- edges, corners, and creases get rounded off. For this project's cliff walls, where sharp top edges are visually important:

- **Marching Cubes**: Cliff top edge becomes a rounded curve. The vertical cliff face gets sloped. Unacceptable for the desired AAA cliff aesthetic.
- **Dual Contouring**: Places vertices **inside grid cells** at positions that best preserve sharp features (using Hermite data -- position + normal at edge crossings). Can produce 90-degree cliff edges.

### Dual Contouring Overview

Dual Contouring (Ju et al., 2002) is the sharp-feature alternative:

1. Like MC, evaluate the scalar field at grid corners and find edge crossings
2. Unlike MC, also store the **surface normal** at each edge crossing (Hermite data)
3. For each grid cell containing a sign change, place ONE vertex inside the cell
4. The vertex position is computed by solving a **Quadric Error Function (QEF)** that minimizes distance to all the tangent planes defined by the edge crossings + normals
5. Connect vertices of adjacent cells to form quads (not triangles from a lookup table)

**Advantages over MC:**
- Reproduces sharp edges, corners, and creases
- Fewer vertices and faces for the same quality
- Naturally produces quads (good for subdivision surfaces)

**Disadvantages:**
- More complex to implement (QEF solver needed)
- Can produce non-manifold meshes (vertices shared across non-adjacent faces)
- Can produce self-intersecting geometry in degenerate cases
- Requires surface normals in addition to scalar values

### Recommended Hybrid Approach for This Project

Use **Marching Squares for smooth coastline contours** (beach zones, gentle coasts) and keep **extruded cliff walls for sharp cliff edges**:

```
Beach coastlines:  Marching Squares contour -> smooth edge -> gentle slope below ocean
Cliff coastlines:  Grid-based boundary -> cliff wall extrusion -> sharp vertical edge
```

This preserves the sharp cliff aesthetic where needed while eliminating staircase artifacts on beaches and gentle coastlines. The `beach_skip` array already distinguishes beach vs. cliff zones, so the pipeline can use different boundary extraction methods per zone.

### Decision Matrix

| Technique | Smooth coasts | Sharp cliffs | Manifold | Complexity | Best for |
|-----------|:---:|:---:|:---:|:---:|---|
| Grid-based (current) | No (staircase) | Yes | Yes | Low | Quick prototype |
| Marching Cubes/Squares | Yes | No (rounded) | Yes | Low-Medium | Smooth terrain, beaches |
| Dual Contouring | Yes | Yes | No* | High | Sharp features + smooth |
| Hybrid (MC beach + grid cliff) | Yes | Yes | Yes | Medium | This project |

*Dual Contouring can be made manifold with extra processing (Manifold Dual Contouring, Schaefer et al.)

## References

- Lorensen, W. & Cline, H. (1987). "Marching Cubes: A High Resolution 3D Surface Construction Algorithm." SIGGRAPH.
- Lengyel, E. (2010). "Voxel-Based Terrain for Real-Time Virtual Simulations." PhD Dissertation, UC Davis. https://transvoxel.org/
- Ju, T. et al. (2002). "Dual Contouring of Hermite Data." SIGGRAPH.
- Chernyaev, E. (1995). "Marching Cubes 33: Construction of Topologically Correct Isosurfaces."
- Bourke, P. "Polygonising a Scalar Field." https://paulbourke.net/geometry/polygonise/
- Lengyel, E. "The Transvoxel Algorithm." https://transvoxel.org/
- Boris the Brave. "Marching Cubes Tutorial." https://www.boristhebrave.com/2018/04/15/marching-cubes-tutorial/
- Mikola Lysenko. "Smooth Voxel Terrain (Part 2)." https://0fps.net/2012/07/12/smooth-voxel-terrain-part-2/
- Boris the Brave. "Dual Contouring Tutorial." https://www.boristhebrave.com/2018/04/15/dual-contouring-tutorial/
