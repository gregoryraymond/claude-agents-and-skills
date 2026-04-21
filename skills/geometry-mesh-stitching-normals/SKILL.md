---
name: geometry-mesh-stitching-normals
description: Reference for mesh stitching, seam prevention, normal recalculation, and LOD transitions in chunked terrain rendering. Covers vertex welding, skirts, geomorphing, weighted normals, octahedral encoding, and CSG operations.
user-invocable: false
---

# Mesh Stitching, Seam Prevention, and Normal Recalculation

Comprehensive reference for handling chunk boundaries, LOD transitions, normal computation, and mesh boolean operations in terrain rendering systems. Includes project-specific patterns from `gen_cliff_glb.rs` and `map.rs`.

---

## 1. Chunk Boundary Problems

When a terrain mesh is split into chunks for frustum culling or streaming, three categories of artifacts appear at chunk boundaries:

### 1.1 Cracks from Non-Shared Vertices

**Cause:** Two adjacent chunks each have their own copy of a boundary vertex. Due to floating-point rounding, the positions may differ by sub-pixel amounts, or the chunks may use different triangle winding along the shared edge, leaving hairline gaps (T-junctions).

**Symptoms:**
- 1-pixel black lines between chunks, visible at glancing angles
- Lines that appear and disappear as the camera moves (view-dependent)
- Worse at chunk corners where 4 chunks meet

**Prevention rules:**
1. Boundary vertices must be **bit-identical** across chunks -- same float bits for position, UV, and normal
2. Never recompute boundary vertex positions independently per chunk; copy them from a shared source
3. Avoid T-junctions: if chunk A has vertices [V0, V1] along an edge and chunk B has [V0, Vmid, V1], the edge in chunk A must also include Vmid

### 1.2 LOD Mismatches

**Cause:** Adjacent chunks at different LOD levels have different vertex counts along their shared edge. The high-LOD chunk has intermediate vertices that the low-LOD chunk lacks, creating gaps.

**Example:** LOD 0 has edge vertices at x = {0, 1, 2, 3, 4}. LOD 1 has edge vertices at x = {0, 2, 4}. At x=1 and x=3, the high-LOD mesh has geometry but the low-LOD mesh interpolates linearly, creating a mismatch if the terrain is not flat.

**Solutions (see sections 3, 4, 5):**
- Vertex welding: force high-LOD boundary vertices to match the low-LOD linear interpolation
- Skirts: hide the gap with vertical geometry
- Geomorphing: smoothly blend between LOD levels

### 1.3 Normal Discontinuities

**Cause:** Smooth normals at chunk boundaries depend on faces from BOTH chunks. If each chunk computes normals independently, boundary vertices get different normals in each chunk, causing a visible lighting seam.

**Prevention:**
1. Compute normals on the **unified mesh** before splitting into chunks
2. Or: after splitting, gather 1-ring neighbor faces across chunk boundaries for boundary vertex normals
3. Or: use a global normal map / heightmap-derived normals instead of per-vertex normals

---

## 2. Vertex Sharing and Welding

### 2.1 Ensuring Bit-Identical Boundary Vertices

The safest approach is to compute ALL vertex attributes (position, UV, normal, color) on a single unified mesh, then split into chunks while preserving the exact attribute values.

**Pattern used in this project** (`map.rs:split_terrain_into_chunks`):

```rust
// 1. Extract all attributes from the unified mesh
let positions: Vec<[f32; 3]> = /* from unified mesh */;
let normals: Vec<[f32; 3]> = /* from unified mesh */;
let uvs: Vec<[f32; 2]> = /* from unified mesh */;
let colors: Vec<[f32; 4]> = /* from unified mesh */;

// 2. Assign each vertex to a chunk by XZ position
let vertex_chunk: Vec<usize> = positions.iter().map(|p| {
    let cc = ((p[0] - LON_MIN) / chunk_w).floor() as usize;
    let cr = ((-p[2] - LAT_MIN) / chunk_h).floor() as usize;
    cr * CHUNK_COLS + cc
}).collect();

// 3. For cross-boundary triangles, DUPLICATE the vertex into the
//    target chunk with the SAME attribute values (bit-identical copy)
if vertex_chunk[vi] != target_chunk {
    // Duplicate: push positions[vi], normals[vi], etc.
    // The duplicated vertex has identical data to the original
}
```

**Key insight:** Because the vertex data is copied by value from the unified arrays, both the "home" chunk vertex and the duplicated vertex have bit-identical attributes. No recomputation occurs.

### 2.2 Cross-Boundary Vertex Duplication Cost

Duplicating boundary vertices increases total vertex count. In this project, the overhead is acceptable because:
- Terrain is a regular grid, so boundary vertices are a small fraction of total
- The duplication happens once at load time, not per frame
- Octahedral normal encoding (4 bytes vs 12 bytes per vertex) offsets the cost

### 2.3 Vertex Welding for Merged Meshes

When combining meshes from different sources (e.g., terrain surface + cliff walls), vertices at shared positions must be welded:

1. Build a spatial hash of vertex positions (quantize to grid, e.g., round to 4 decimal places)
2. For each vertex, look up the hash bucket; if a matching position exists, reuse its index
3. Average normals at welded vertices (or choose the dominant normal)

**Caution:** Do not weld vertices that should have a hard edge (e.g., cliff top vs. cliff face). Use a normal-angle threshold: only weld if the angle between normals is less than a smoothing threshold (typically 30-80 degrees).

---

## 3. Skirt Technique

### 3.1 Concept

A **skirt** (also called a "flange" or "apron") is a vertical strip of triangles extruded downward from the boundary edges of each chunk. The strip hangs below the terrain surface, filling any cracks between adjacent chunks.

```
   Chunk A surface          Chunk B surface
   ___________              ___________
              |    crack   |
              |  |----->|  |
              |__|       |__|
              skirt A    skirt B
```

### 3.2 Construction

For each boundary edge (top, bottom, left, right) of a chunk:

```
for each boundary vertex V[i]:
    V_bottom[i] = V[i] - (0, skirt_depth, 0)

for each consecutive pair (V[i], V[i+1]):
    emit quad:
        V[i], V[i+1], V_bottom[i+1], V_bottom[i]
```

**Skirt depth** should be large enough to cover the maximum possible crack height. For LOD transitions where vertex height differences are bounded, `skirt_depth = max_height_delta * 2` is sufficient.

### 3.3 Attributes for Skirt Vertices

- **Position:** Same XZ as the boundary vertex, Y offset downward
- **Normal:** Same as the boundary vertex (for lighting continuity)
- **UV:** Same as the boundary vertex (for texture continuity)
- **Color:** Same as the boundary vertex

### 3.4 Pros and Cons

| Advantage | Disadvantage |
|-----------|--------------|
| Simple to implement | Adds triangle count (2 tris per boundary edge segment) |
| Works for any LOD combination | Can cause z-fighting where skirts overlap |
| No dependency between adjacent chunks | Skirt faces visible at extreme angles |
| Hides other modeling errors too | Not needed if vertex welding or geomorphing is used |

### 3.5 Project Analog: Cliff Walls

This project uses cliff walls (`gen_cliff_glb.rs`) as a form of skirt at the land-ocean boundary. Cliff walls are vertical quads extruded downward from coastal edges to `CLIFF_BASE_Y = -0.2`, hiding the terrain-to-ocean transition. This is conceptually identical to the skirt technique applied at coastline boundaries rather than chunk boundaries.

---

## 4. Geomorphing

### 4.1 Concept

**Geomorphing** (geometry morphing) smoothly transitions between LOD levels by interpolating vertex positions over time or distance, preventing the "popping" artifact that occurs when vertices are suddenly added or removed.

### 4.2 How It Works

Each vertex in a higher-detail LOD stores two heights:
- Its **true height** at the current LOD
- Its **parent height** -- the height it would have at the next coarser LOD (typically the average of its two neighbors on the coarser grid)

A **morph factor** (0.0 to 1.0) is computed per chunk based on camera distance:

```
morph_factor = smoothstep(lod_near, lod_far, distance_to_camera)
```

In the vertex shader:

```wgsl
let morphed_y = mix(vertex.true_height, vertex.parent_height, morph_factor);
```

When `morph_factor = 0`, the vertex is at full detail. When `morph_factor = 1`, it has collapsed to its parent position and can be seamlessly replaced by the coarser LOD.

### 4.3 Encoding in Vertex Data

A common approach stores the morph target as an extra vertex attribute:

```rust
// Per-vertex: [position.x, position.y, position.z, parent_y, morph_lod]
// morph_lod = the LOD level at which this vertex first appears
```

The vertex shader computes:

```wgsl
// lod_value = 2.46 means 46% morph from LOD 2 toward LOD 3
let frac = fract(lod_value);
if vertex.morph_lod == u32(lod_value) {
    position.y = mix(vertex.position.y, vertex.parent_y, frac);
}
```

### 4.4 Boundary Constraints

At chunk boundaries, both adjacent chunks must agree on the morph factor for shared vertices. The standard rule: **the coarser chunk dictates boundary vertex positions.** The finer chunk morphs its boundary vertices to match the coarser neighbor.

### 4.5 Project LOD System

This project uses a simpler LOD approach (`terrain_lod_system` in `map.rs`):
- Two discrete LOD levels (LOD 0 = 2048x1560, LOD 1 = 4096x3120)
- Visibility toggling based on camera zoom distance
- No per-vertex geomorphing (instant LOD switch)
- Both LODs share the same chunk grid and vertex duplication strategy

Geomorphing could be added by storing the LOD 0 height as a vertex attribute in LOD 1 meshes and blending in the terrain vertex shader based on zoom distance.

---

## 5. Normal Recalculation

### 5.1 Flat Normals (Per-Face)

Each triangle gets a single normal equal to the face normal. Every vertex of the triangle uses this normal. This produces faceted shading where individual triangles are visible.

```rust
let edge1 = v1 - v0;
let edge2 = v2 - v0;
let face_normal = edge1.cross(edge2).normalize();
// All three vertices of this triangle get face_normal
```

**Use case:** Hard-edged geometry like cliff faces, building walls, low-poly art style.

### 5.2 Smooth Normals (Per-Vertex Average)

Each vertex normal is the average of the face normals of all triangles sharing that vertex. This produces smooth Phong/Gouraud shading.

**Unweighted average** (simplest):

```rust
let mut accum = vec![Vec3::ZERO; vertex_count];
for tri in triangles {
    let face_normal = compute_face_normal(tri);
    accum[tri.v0] += face_normal;
    accum[tri.v1] += face_normal;
    accum[tri.v2] += face_normal;
}
for n in &mut accum {
    *n = n.normalize();
}
```

**This is the method used in `gen_cliff_glb.rs`** (lines 1265-1290). The un-normalized cross product `(b - a).cross(c - a)` is accumulated per vertex, then normalized. Because the cross product magnitude equals twice the triangle area, this is implicitly **area-weighted**.

### 5.3 Weighted Normal Averaging

Different weighting schemes produce different shading quality:

#### Area Weighting (implicit in cross product accumulation)

Weight = triangle area. Larger triangles contribute more to the vertex normal. This is the most common approach and what you get "for free" when accumulating un-normalized cross products.

```rust
// Cross product magnitude = 2 * triangle_area
// Accumulating without normalizing = area weighting
let n = (b - a).cross(c - a);  // NOT normalized
accum[vi] += n;
```

**Pros:** Natural, cheap (no extra computation), prevents tiny degenerate triangles from dominating.
**Cons:** Large triangles may over-influence normals at shared vertices.

#### Angle Weighting

Weight = the interior angle of the triangle at that vertex. Triangles that subtend a larger angle at the vertex contribute more.

```rust
fn angle_at_vertex(v: Vec3, a: Vec3, b: Vec3) -> f32 {
    let d1 = (a - v).normalize();
    let d2 = (b - v).normalize();
    d1.dot(d2).clamp(-1.0, 1.0).acos()
}

for tri in triangles {
    let face_normal = compute_face_normal(tri).normalize();
    accum[tri.v0] += face_normal * angle_at_vertex(positions[tri.v0], positions[tri.v1], positions[tri.v2]);
    accum[tri.v1] += face_normal * angle_at_vertex(positions[tri.v1], positions[tri.v0], positions[tri.v2]);
    accum[tri.v2] += face_normal * angle_at_vertex(positions[tri.v2], positions[tri.v0], positions[tri.v1]);
}
```

**Pros:** More mathematically correct for approximating smooth surfaces. Preferred by Blender.
**Cons:** More expensive (acos per vertex per triangle).

#### Combined Area + Angle Weighting

Multiply area weight by angle weight for each vertex-triangle pair:

```rust
let weight = triangle_area * angle_at_vertex;
accum[vi] += face_normal.normalize() * weight;
```

This is considered the highest quality but is the most expensive.

#### Smoothing Angle Threshold

Adjacent faces with a dihedral angle greater than the threshold get separate normals (hard edge). Faces within the threshold share smoothed normals.

```rust
const SMOOTH_ANGLE: f32 = 80.0_f32.to_radians();

// When building adjacency:
if dihedral_angle(face_a, face_b) > SMOOTH_ANGLE {
    // Don't share normals across this edge -- duplicate the vertex
}
```

**Use case:** Automatic smooth/flat detection. Cliff tops vs. cliff faces naturally get different normals because the angle between horizontal terrain and vertical cliff exceeds the threshold.

---

## 6. Normal Maps from Heightmaps

### 6.1 Finite Differences (Central Difference)

The simplest method. Sample the heightmap at neighboring texels and compute partial derivatives:

```rust
fn normal_from_heightmap(hmap: &[f32], x: usize, y: usize, w: usize, h: usize, strength: f32) -> Vec3 {
    let left  = hmap[y * w + (x.saturating_sub(1))];
    let right = hmap[y * w + (x + 1).min(w - 1)];
    let up    = hmap[y.saturating_sub(1) * w + x];
    let down  = hmap[(y + 1).min(h - 1) * w + x];

    let dx = (right - left) * strength;
    let dy = (down - up) * strength;

    Vec3::new(-dx, 1.0, -dy).normalize()
}
```

**Encoding to RGB:** `normal_rgb = (normal * 0.5 + 0.5) * 255`

### 6.2 Sobel Filter

A 3x3 convolution that includes diagonal neighbors for smoother derivatives:

```
Sobel X kernel:        Sobel Y kernel:
[-1  0  1]             [-1 -2 -1]
[-2  0  2]             [ 0  0  0]
[-1  0  1]             [ 1  2  1]
```

```rust
fn sobel_normal(hmap: &[f32], x: usize, y: usize, w: usize, strength: f32) -> Vec3 {
    // Sample 3x3 neighborhood
    let tl = sample(hmap, x-1, y-1, w);
    let tc = sample(hmap, x,   y-1, w);
    let tr = sample(hmap, x+1, y-1, w);
    let ml = sample(hmap, x-1, y,   w);
    let mr = sample(hmap, x+1, y,   w);
    let bl = sample(hmap, x-1, y+1, w);
    let bc = sample(hmap, x,   y+1, w);
    let br = sample(hmap, x+1, y+1, w);

    let dx = (tr + 2.0*mr + br) - (tl + 2.0*ml + bl);
    let dy = (bl + 2.0*bc + br) - (tl + 2.0*tc + tr);

    Vec3::new(-dx * strength, 1.0, -dy * strength).normalize()
}
```

**Sobel vs. finite differences:** Sobel is smoother (incorporates diagonal neighbors) but slightly more expensive. For terrain, the quality difference is minimal.

### 6.3 Tangent-Space Encoding

Normal maps store normals in **tangent space** -- a coordinate system local to the surface:
- **T** (tangent) = surface direction along U texture coordinate
- **B** (bitangent) = surface direction along V texture coordinate
- **N** (normal) = surface normal

A flat surface has tangent-space normal `(0, 0, 1)` -- encoded as RGB `(128, 128, 255)` (the characteristic blue color).

At runtime, the TBN matrix transforms the tangent-space normal to world space:

```wgsl
let world_normal = TBN * tangent_space_normal;
// where TBN = mat3x3(tangent, bitangent, normal)
```

### 6.4 Object-Space vs. Tangent-Space for Terrain

For terrain (non-deforming, non-tiling), **object-space normal maps** are simpler:
- No TBN matrix needed at runtime
- Normal map stores world-up-relative normals directly
- Cannot be reused on different meshes (but terrain is unique anyway)

---

## 7. Octahedral Normal Encoding

### 7.1 Concept

Octahedral encoding maps a unit-sphere normal vector to a 2D square `[-1, 1]^2` by projecting onto an octahedron and unfolding it. This compresses 3 floats (12 bytes) to 2 components that can be quantized to Snorm16x2 (4 bytes) or Snorm8x2 (2 bytes).

### 7.2 Encoding Algorithm

1. **Project onto octahedron:** Divide by L1 norm (`|x| + |y| + |z|`)
2. **Unfold lower hemisphere:** Reflect the bottom half to fill the square

```rust
fn encode_oct_normal(n: [f32; 3]) -> [i16; 2] {
    let abs_sum = n[0].abs() + n[1].abs() + n[2].abs();
    let mut ox = n[0] / abs_sum;
    let mut oy = n[1] / abs_sum;
    // Reflect lower hemisphere
    if n[2] < 0.0 {
        let new_ox = (1.0 - oy.abs()) * if ox >= 0.0 { 1.0 } else { -1.0 };
        let new_oy = (1.0 - ox.abs()) * if oy >= 0.0 { 1.0 } else { -1.0 };
        ox = new_ox;
        oy = new_oy;
    }
    [
        (ox.clamp(-1.0, 1.0) * 32767.0) as i16,
        (oy.clamp(-1.0, 1.0) * 32767.0) as i16,
    ]
}
```

### 7.3 Decoding Algorithm (WGSL)

```wgsl
fn decode_oct_normal(oct: vec2<f32>) -> vec3<f32> {
    var n = vec3<f32>(oct.x, oct.y, 1.0 - abs(oct.x) - abs(oct.y));
    if n.z < 0.0 {
        let sign_x = select(-1.0, 1.0, n.x >= 0.0);
        let sign_y = select(-1.0, 1.0, n.y >= 0.0);
        let old_x = n.x;
        n = vec3<f32>(
            (1.0 - abs(n.y)) * sign_x,
            (1.0 - abs(old_x)) * sign_y,
            n.z
        );
    }
    return normalize(n);
}
```

### 7.4 Quality at Different Bit Depths

| Format | Bytes | Max Angular Error | Use Case |
|--------|-------|-------------------|----------|
| Snorm8x2 | 2 | ~1.5 degrees | Low-quality, mobile |
| Snorm16x2 | 4 | ~0.005 degrees | Production quality (this project) |
| Float16x2 | 4 | ~0.001 degrees | Overkill for normals |
| Float32x2 | 8 | Negligible | Debugging only |

### 7.5 Properties

- **Near-uniform mapping:** Error distribution is approximately uniform across the sphere
- **Fast encode/decode:** Only 1 `rcp` (reciprocal) instruction each way; no trigonometry
- **Hardware-friendly:** Snorm16x2 is a native vertex format in all modern GPUs
- **Interpolation caveat:** Linear interpolation in octahedral space is NOT the same as spherical interpolation. For vertex attributes interpolated by the rasterizer, decode in the fragment shader after interpolation, or accept the minor error

---

## 8. How This Project Handles Normals

### 8.1 Normal Computation in `gen_cliff_glb.rs`

Normals are computed on the unified terrain+cliff mesh using **area-weighted smooth normals** (implicit from un-normalized cross product accumulation):

```rust
// gen_cliff_glb.rs lines 1265-1290
let mut normals_accum = vec![[0.0f32; 3]; vertex_count];
for tri in indices.chunks_exact(3) {
    let (i0, i1, i2) = (tri[0] as usize, tri[1] as usize, tri[2] as usize);
    let a = Vec3::from(positions[i0]);
    let b = Vec3::from(positions[i1]);
    let c = Vec3::from(positions[i2]);
    let n = (b - a).cross(c - a);  // magnitude = 2 * area (area weighting)
    for &vi in &[i0, i1, i2] {
        normals_accum[vi][0] += n.x;
        normals_accum[vi][1] += n.y;
        normals_accum[vi][2] += n.z;
    }
}
// Normalize; fallback to (0, 1, 0) for degenerate vertices
let normals: Vec<[f32; 3]> = normals_accum.iter().map(|n| {
    let v = Vec3::from(*n).normalize_or_zero();
    if v == Vec3::ZERO { [0.0, 1.0, 0.0] } else { v.into() }
}).collect();
```

**Important:** This runs on the full unified mesh (terrain grid + cliff walls together), so terrain vertices adjacent to cliff walls get normals influenced by the cliff geometry. This is intentional -- it creates a smooth transition at cliff tops.

### 8.2 Octahedral Encoding in `map.rs`

After chunk splitting, normals are re-encoded from Float32x3 to Snorm16x2:

```rust
// map.rs: Custom vertex attribute declaration
pub const ATTRIBUTE_OCT_NORMAL: MeshVertexAttribute =
    MeshVertexAttribute::new("OctNormal", 988540917, VertexFormat::Snorm16x2);

// During chunk mesh construction:
let cn_oct: Vec<[i16; 2]> = cv.iter()
    .map(|&vi| encode_oct_normal(normals[vi]))
    .collect();
chunk_mesh.insert_attribute(ATTRIBUTE_OCT_NORMAL,
    VertexAttributeValues::Snorm16x2(cn_oct));
```

The terrain shader (`terrain_material.wgsl`) decodes in the vertex shader:

```wgsl
let local_normal = decode_oct_normal(vertex_no_morph.packed_normal);
out.world_normal = mesh_functions::mesh_normal_local_to_world(
    local_normal, vertex_no_morph.instance_index
);
```

### 8.3 Why No Seam Artifacts

This project avoids chunk boundary normal seams because:
1. Normals are computed on the unified mesh BEFORE splitting
2. Split vertices are copied by value (bit-identical)
3. Octahedral encoding is applied per-vertex (deterministic, no chunk-dependent state)

---

## 9. How This Project Handles Chunks

### 9.1 `split_terrain_into_chunks` Architecture

Located in `map.rs` (lines 820-1013). Runs once per unified terrain entity.

**Input:** A single unified mesh (loaded from `coastline_lod0.glb` or `coastline_lod1.glb`)

**Output:** `CHUNK_COLS * CHUNK_ROWS` separate entities, each with its own mesh

**Algorithm:**

1. **Extract vertex data** from the unified mesh (positions, normals, UVs, colors, indices)
2. **Assign each vertex to a chunk** based on its XZ position mapped to a grid:
   ```
   chunk_col = floor((lon - LON_MIN) / chunk_width)
   chunk_row = floor((lat - LAT_MIN) / chunk_height)
   chunk_index = row * CHUNK_COLS + col
   ```
3. **Build per-chunk vertex arrays** with local index remapping
4. **Handle cross-boundary triangles:** A triangle is assigned to the chunk of its first vertex (`vertex_chunk[i0]`). If vertices `i1` or `i2` belong to different chunks, they are **duplicated** into the target chunk with identical attribute values
5. **Encode normals** as octahedral Snorm16x2 during chunk mesh construction
6. **Spawn chunk entities** with `TerrainChunk(index)` component
7. **Despawn the original** unified entity

### 9.2 Cross-Boundary Duplication Detail

```rust
let get_local = |vi, chunk, extras, verts| -> u32 {
    if vertex_chunk[vi] == chunk {
        chunk_remap[vi].unwrap().1  // Already in this chunk
    } else {
        // Duplicate: push the original vertex index into this chunk's list
        let local = verts.len() as u32;
        verts.push(vi);   // vi indexes into the UNIFIED arrays
        extras.push(vi);
        local
    }
};
```

When the chunk mesh is constructed, `positions[vi]`, `normals[vi]`, etc. are read from the unified arrays using the original index `vi`, guaranteeing bit-identical data.

### 9.3 LOD System

- **LOD 0:** 2048x1560 grid (~3.2M vertices), always loaded
- **LOD 1:** 4096x3120 grid (~12.8M vertices), lazy-loaded on first zoom-in
- `terrain_lod_system` toggles visibility based on camera zoom distance
- Both LODs use the same chunk splitting logic
- No geomorphing between LODs (instant switch)

---

## 10. CSG / Boolean Operations for Terrain

### 10.1 Overview

Constructive Solid Geometry (CSG) combines volumes using boolean set operations:

| Operation | Result | Terrain Use Case |
|-----------|--------|------------------|
| **Union (A + B)** | Combined volume of both | Merging terrain patches, adding geological features |
| **Difference (A - B)** | A with B carved out | Carving caves, river channels, road cuts |
| **Intersection (A * B)** | Volume shared by both | Extracting terrain within a boundary polygon |

### 10.2 CSG on Heightmap Terrain

For 2.5D heightmap terrain (single height per XY), CSG simplifies to per-texel operations:

```rust
// Union: take the higher point (terrain rise)
height_union[x][y] = max(terrain_a[x][y], terrain_b[x][y]);

// Difference: carve B from A (lower where B is high)
height_diff[x][y] = min(terrain_a[x][y], -terrain_b[x][y]);

// Intersection: take the lower point (terrain cut)
height_intersect[x][y] = min(terrain_a[x][y], terrain_b[x][y]);
```

This is fast (O(width * height)) but only works for heightmap terrain, not true volumetric meshes.

### 10.3 CSG on Triangle Meshes

For full 3D mesh boolean operations (caves, overhangs, volumetric features):

1. **Both meshes must be watertight** (manifold, no open edges)
2. **Compute intersection edges** where the two meshes' surfaces cross
3. **Re-triangulate** the intersected faces
4. **Classify** each resulting triangle as inside/outside each volume
5. **Select** triangles based on the boolean operation

**Libraries:**
- CGAL (C++) -- robust, exact arithmetic, production-grade
- libigl (C++) -- simpler API, uses CGAL internally
- CSG.js (JavaScript) -- simple BSP-tree approach, good for prototyping
- Manifold (C++/WASM) -- modern, fast, GPU-accelerated

### 10.4 CSG Relevance to This Project

This project does not currently use CSG operations. The terrain is a single heightmap-based grid with cliff walls extruded at coastlines. However, CSG concepts apply to potential features:

- **River channels:** Difference operation on the heightmap to carve river beds
- **Tunnel/bridge geometry:** Would require volumetric mesh CSG, not heightmap ops
- **Procedural terrain modification:** Union of base heightmap with local feature heightmaps (mountain ranges, craters)

For heightmap-based modifications, the simpler per-texel min/max approach (section 10.2) is preferred over full mesh CSG.

---

## 11. Quick Reference: When to Use Which Technique

| Problem | Recommended Solution |
|---------|---------------------|
| Cracks between same-LOD chunks | Vertex sharing (compute unified, split after) |
| Cracks between different-LOD chunks | Skirts or constrained boundary vertices |
| LOD pop-in | Geomorphing |
| Faceted shading on smooth terrain | Smooth normals (area-weighted) |
| Hard edges at cliffs/buildings | Smoothing angle threshold or flat normals |
| Memory/bandwidth for normals | Octahedral Snorm16x2 encoding |
| Normal seams at chunk boundaries | Compute normals before splitting |
| Heightmap-to-normal-map | Sobel filter or central differences |
| Carving terrain features | Heightmap min/max (2.5D) or mesh CSG (3D) |

---

## 12. References

- [Terrain LOD: Dealing with Seams](https://blog.nostatic.org/2010/07/terrain-level-of-detail-dealing-with.html)
- [Voxels and Seamless LOD Transitions](https://dexyfex.com/2016/07/14/voxels-and-seamless-lod-transitions/)
- [Terrain Geomorphing in the Vertex Shader (Shader-X 2)](https://www.ims.tuwien.ac.at/publications/tuw-138077.pdf)
- [Smooth View-Dependent LOD Control (Hoppe)](https://hhoppe.com/svdlod.pdf)
- [Generating Complex Procedural Terrains Using the GPU (GPU Gems 3)](https://developer.nvidia.com/gpugems/gpugems3/part-i-geometry/chapter-1-generating-complex-procedural-terrains-using-gpu)
- [Octahedron Normal Vector Encoding (Narkowicz)](https://knarkowicz.wordpress.com/2014/04/16/octahedron-normal-vector-encoding/)
- [Compact Normal Storage for small G-Buffers (Aras P.)](https://aras-p.info/texts/CompactNormalStorage.html)
- [Analyzing Octahedral Encoded Normals](https://liamtyler.github.io/posts/octahedral_analysis/)
- [Weighted Vertex Normals](http://www.bytehazard.com/articles/vertnorm.html)
- [Computing Smooth-by-Angle Normals Like Blender](https://cprimozic.net/blog/computing-auto-smooth-shaded-normals-like-blender/)
- [Planetary Terrain (ralith.com)](https://ralith.com/blog/planetary-terrain/)
- [Emancipation from the Skirt (Procworld)](http://procworld.blogspot.com/2013/07/emancipation-from-skirt.html)
- [Dual Contouring: Seams & LOD for Chunked Terrain](http://ngildea.blogspot.com/2014/09/dual-contouring-chunked-terrain.html)
- [Vertex Normal (Wikipedia)](https://en.wikipedia.org/wiki/Vertex_normal)
- [Constructive Solid Geometry (Wikipedia)](https://en.wikipedia.org/wiki/Constructive_solid_geometry)
