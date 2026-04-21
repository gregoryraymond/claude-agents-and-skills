---
name: dual-contouring
description: Comprehensive reference for Dual Contouring algorithm — terrain mesh generation with sharp cliff edges, QEF vertex placement, octree LOD, and Rust implementation considerations.
user-invocable: false
---

# Dual Contouring for Terrain Mesh Generation

## Algorithm Overview

Dual Contouring (DC) generates a polygon mesh from an implicit surface (scalar field) by placing **one vertex per cell** and connecting vertices across edges that exhibit a **sign change** (where the surface crosses the edge). It was introduced by Ju, Losasso, Schaefer, and Warren in "Dual Contouring of Hermite Data" (SIGGRAPH 2002).

### Core Principle: Dual of the Grid

In Marching Cubes (MC), vertices are placed **on grid edges** where the surface crosses. In DC, vertices are placed **inside grid cells** that contain part of the surface. The mesh is the "dual" of the MC mesh — where MC creates triangles from edge intersections, DC creates quads (or triangles) by connecting cell-interior vertices.

### Algorithm Steps (3D)

1. **Sample the scalar field** at every grid vertex. Record the sign (inside/outside) at each corner.

2. **Find sign-change edges.** For every edge in the grid, check if the two endpoints have different signs. If so, the surface crosses this edge.

3. **Compute Hermite data** for each sign-change edge:
   - The **intersection point** where the surface crosses the edge (via root-finding, e.g., bisection or analytic solution).
   - The **surface normal** at that intersection point (gradient of the scalar field).

4. **Solve for one vertex per cell.** For each cell that contains at least one sign-change edge, collect all the Hermite data (intersection points + normals) from its edges. Solve the **QEF** (Quadratic Error Function) to find the optimal vertex position inside the cell.

5. **Connect vertices into faces.** For each sign-change edge in 3D, there are exactly 4 cells sharing that edge. Connect the 4 cell vertices into a quad face. (In 2D, each sign-change edge has 2 adjacent cells, producing a line segment.)

6. **Output the mesh.** The result is a quad mesh (optionally triangulated) that approximates the isosurface.

### 2D Analogy

In 2D, the grid is squares. Each square with a sign change gets one vertex. For each grid edge with a sign change, the two squares sharing that edge have their vertices connected by a line segment. The result is a polygon approximating the contour.

---

## Hermite Data: Sign Changes + Surface Normals

Hermite data is what distinguishes DC from simpler methods. Each sign-change edge stores:

| Field | Type | Description |
|---|---|---|
| `intersection` | `Vec3` | The point on the edge where the surface crosses (between the two grid vertices) |
| `normal` | `Vec3` | The surface normal at the intersection point (gradient of the scalar field, normalized) |

### Why Normals Matter

The normal defines a **tangent plane** at each intersection:

```
plane_i: n_i . (x - p_i) = 0
```

where `n_i` is the normal and `p_i` is the intersection point. The QEF solver finds the point `x` that best fits ALL tangent planes from a cell's sign-change edges simultaneously. This is what enables sharp feature detection — when tangent planes from different edges intersect at a sharp angle, the QEF solution naturally falls on the sharp edge or corner.

### Computing Hermite Data

**Intersection point:** For an edge from vertex A (value `f_A`) to vertex B (value `f_B`) with opposite signs, the simplest approach is linear interpolation:

```
t = f_A / (f_A - f_B)
intersection = A + t * (B - A)
```

For higher accuracy, use bisection search or Newton's method along the edge.

**Normal:** Evaluate the gradient of the scalar field at the intersection point:

```
normal = normalize(gradient(field, intersection))
```

The gradient can be computed analytically (if the field has a known derivative) or via central differences:

```
grad.x = (field(p + dx) - field(p - dx)) / (2 * h)
grad.y = (field(p + dy) - field(p - dy)) / (2 * h)
grad.z = (field(p + dz) - field(p - dz)) / (2 * h)
```

---

## QEF: Quadratic Error Function

The QEF is the mathematical core that gives DC its sharp-feature ability. It finds the point inside a cell that best fits all the tangent-plane constraints from that cell's Hermite data.

### Mathematical Formulation

Given `k` intersection points `p_i` with normals `n_i`, find the point `x` that minimizes:

```
E(x) = SUM_i [ (n_i . (x - p_i))^2 ]
```

This is the sum of squared distances from `x` to each tangent plane. It is quadratic in `x`, so it has a unique minimum (or a degenerate line/plane of minima for rank-deficient cases).

### Matrix Form

Rewrite as a least-squares problem `||Ax - b||^2`:

```
A = [ n_1^T ]       b = [ n_1 . p_1 ]
    [ n_2^T ]           [ n_2 . p_2 ]
    [ ...   ]           [ ...        ]
    [ n_k^T ]           [ n_k . p_k ]
```

Where each row of A is a normal vector (transposed), and each element of b is the dot product of the normal with its intersection point.

The normal equations give: `A^T A x = A^T b`

### Compact Representation (ATA / ATb / BTb)

Instead of storing the full A and b matrices (which grow with the number of intersections), store only:

```
ATA = SUM_i (n_i * n_i^T)         // 3x3 symmetric matrix (6 unique values)
ATb = SUM_i (n_i * (n_i . p_i))   // 3-vector
BTb = SUM_i ((n_i . p_i)^2)       // scalar
```

**Total storage: 10 floats per cell** (6 for symmetric ATA + 3 for ATb + 1 for BTb).

This compact form has a critical property: **QEFs are additive.** To merge two cells (e.g., during octree simplification), simply add their ATA, ATb, and BTb values. The merged QEF represents the combined constraint set.

### Solving with SVD

Direct inversion `x = (A^T A)^{-1} A^T b` fails when the system is rank-deficient (e.g., all normals are parallel — the surface is locally flat). Use SVD instead:

1. Compute SVD of `A^T A = U S V^T` where S is diagonal with eigenvalues.
2. Pseudo-invert S: for each eigenvalue `s_i`, set `s_i' = 1/s_i` if `s_i > threshold`, else `s_i' = 0`.
3. Compute `x = V S'^{-1} U^T (A^T b)`.

The SVD threshold controls how aggressively degenerate directions are clamped. A common threshold is `1e-6 * max_eigenvalue`.

### The Out-of-Cell Problem and Bias

**Problem:** The QEF solution can fall **outside** the cell, especially for large flat surfaces where the tangent planes barely constrain position along the surface. An out-of-cell vertex creates self-intersecting or inverted mesh faces.

**Solution — Mass Point Bias:** Add a regularization term that biases the solution toward the cell center (or the centroid of intersection points):

```
E_biased(x) = E(x) + lambda * ||x - c||^2
```

where `c` is the cell center or mass point (average of intersection points) and `lambda` is a small weight (e.g., 0.01 to 0.1).

In matrix form, this adds `lambda * I` to `A^T A` and `lambda * c` to `A^T b`. This is equivalent to adding a "virtual" plane intersection at the center with a weak normal in each axis direction. The bias:
- Guarantees the solution stays near the cell center
- Acts as Tikhonov regularization for numerical stability
- With small `lambda`, barely affects sharp features (the real constraints dominate)

**Alternative — Clamping:** After solving, clamp the vertex to the cell bounds. Simpler but can degrade sharp features at cell boundaries.

### Implementation Pseudocode

```
struct QEF {
    ata: Mat3,   // 3x3 symmetric (store as 6 floats)
    atb: Vec3,
    btb: f32,
    mass_point: Vec3,
    num_points: u32,
}

impl QEF {
    fn add(&mut self, point: Vec3, normal: Vec3) {
        self.ata += outer_product(normal, normal);
        let d = normal.dot(point);
        self.atb += normal * d;
        self.btb += d * d;
        self.mass_point += point;
        self.num_points += 1;
    }

    fn solve(&self, bias: f32) -> Vec3 {
        let mp = self.mass_point / self.num_points as f32;

        // Add bias toward mass point
        let ata = self.ata + Mat3::IDENTITY * bias;
        let atb = self.atb + mp * bias;

        // SVD solve
        let (u, s, v) = svd(ata);
        let threshold = s.max_element() * 1e-6;
        let s_inv = s.map(|si| if si > threshold { 1.0 / si } else { 0.0 });

        let x = v * diag(s_inv) * u.transpose() * atb;

        // Optional: clamp to cell bounds
        x.clamp(cell_min, cell_max)
    }

    fn merge(a: &QEF, b: &QEF) -> QEF {
        QEF {
            ata: a.ata + b.ata,
            atb: a.atb + b.atb,
            btb: a.btb + b.btb,
            mass_point: a.mass_point + b.mass_point,
            num_points: a.num_points + b.num_points,
        }
    }

    fn error(&self, x: Vec3) -> f32 {
        // E(x) = x^T ATA x - 2 x^T ATb + BTb
        x.dot(self.ata * x) - 2.0 * x.dot(self.atb) + self.btb
    }
}
```

---

## Sharp Feature Preservation

### Why DC Keeps Cliffs Sharp While MC Rounds Them

**Marching Cubes** places vertices on grid edges by interpolating between corner values. Every vertex lies ON an edge of the grid. For a sharp 90-degree edge, MC vertices straddle both sides of the edge, and the resulting triangles always "round off" the corner because no vertex can be placed AT the corner (which is inside a cell, not on an edge).

**Dual Contouring** places vertices INSIDE cells. The QEF solver naturally positions vertices at the intersection of tangent planes. When two surfaces meet at a sharp edge, their normals point in different directions, and the QEF solution falls exactly on the edge where the planes intersect. When three or more surfaces meet at a corner, the QEF solution falls at the corner point.

### Geometric Intuition

Consider a 2D right-angle corner:
- **MC:** Places points on grid edges near the corner, then connects them. The corner is always "cut" — you get a beveled/chamfered edge.
- **DC:** The cell containing the corner has Hermite data from two perpendicular surfaces. The QEF finds the point where the two tangent lines intersect = the exact corner. Sharp feature preserved.

### Feature Detection Through QEF Eigenvalues

The eigenvalues of the QEF's `A^T A` matrix reveal the local surface geometry:

| Eigenvalue Pattern | Surface Type | Feature |
|---|---|---|
| One large, two small | Flat surface | No feature (vertex slides along surface) |
| Two large, one small | Sharp edge | Feature edge (vertex constrained to a line) |
| Three large | Corner | Feature point (vertex fully constrained) |

This can be used for adaptive behavior:
- On flat surfaces: use mass-point bias more aggressively (prevents drift)
- On edges: constrain solution to the edge line
- On corners: trust the QEF solution fully (it is well-determined)

### Application to Terrain Cliff Edges

For a terrain with a sharp cliff (steep drop from a plateau to a lower area):

1. The scalar field has a rapid transition at the cliff edge.
2. Grid cells along the cliff top have Hermite data with normals pointing both UP (plateau surface) and OUT (cliff face).
3. The QEF places the vertex exactly at the cliff lip where the plateau meets the vertical face.
4. The result is a sharp, well-defined cliff edge — not a rounded slope.

This is exactly what is needed for European coastal cliffs where the land drops sharply into the sea.

---

## Comparison with Marching Cubes

| Aspect | Marching Cubes | Dual Contouring |
|---|---|---|
| **Vertex placement** | On grid edges (interpolated) | Inside grid cells (QEF-optimized) |
| **Input data** | Scalar field values only | Scalar values + gradients/normals (Hermite data) |
| **Sharp features** | Cannot reproduce (always rounds) | Naturally preserved via QEF |
| **Output topology** | Triangles (from lookup table) | Quads (optionally triangulated) |
| **Manifold guarantee** | Always 2-manifold | Can produce non-manifold (see below) |
| **Lookup table** | 256 cases (15 unique) | No lookup table needed |
| **Cell independence** | Each cell processed independently | Must find adjacent cells for each sign-change edge |
| **Adaptive (octree)** | Cracks at LOD boundaries (needs patching) | No cracks between different-sized cells |
| **Implementation complexity** | Simple (lookup table + interpolation) | Moderate (QEF solver + adjacency queries) |
| **Memory per cell** | ~1 byte (case index) | ~40 bytes (QEF: 10 floats) |
| **Parallelization** | Trivially parallel | Requires adjacency information |

### When to Use Which

- **Marching Cubes:** When sharp features do not matter, when implementation simplicity is paramount, when guaranteed manifold output is required, or when the scalar field gradient is unavailable.
- **Dual Contouring:** When sharp features (cliffs, building edges, geological formations) must be preserved, when adaptive resolution is needed (octree), or when a higher-quality mesh is worth the implementation cost.

### Hybrid Approaches

- **Dual Marching Cubes (DMC):** Uses MC's lookup table but places vertices inside cells. Gets some sharp-feature benefit without full QEF.
- **Surface Nets:** Relaxation-based vertex placement inside cells. Smoother than MC but no sharp features.
- **Cubical Marching Squares:** A 2D-slice-based approach that can reproduce sharp features with less complexity.

---

## Octree-Based DC for Adaptive Resolution

### Motivation

Uniform-grid DC wastes triangles in flat areas and lacks resolution at detail areas. An octree subdivides space adaptively — smaller cells where detail is needed (coastlines, cliff edges), larger cells in smooth areas (open ocean, flat inland).

### Octree Structure for DC

```
struct OctreeNode {
    children: Option<[Box<OctreeNode>; 8]>,  // None = leaf
    vertex: Option<Vec3>,                     // QEF solution (leaves only)
    qef: QEF,                                // Compact QEF data
    corners: [Sign; 8],                      // Sign at each corner
    hermite_data: Vec<HermiteEdge>,           // Sign-change edges
}
```

### Subdivision Criteria

Subdivide a cell if:
1. **Surface detail:** The QEF error exceeds a threshold (the surface is poorly approximated by one vertex).
2. **Feature detection:** The QEF eigenvalue analysis detects a sharp feature that would be lost at this resolution.
3. **Distance-based:** The cell is near the camera or a region of interest (e.g., coastline).
4. **Curvature-based:** The normals within the cell vary significantly (high curvature).

For terrain:
- Subdivide heavily along coastlines and cliff edges
- Keep large cells for flat inland areas and deep ocean
- Use distance from the coast as a proxy for subdivision priority

### Face Generation with Mixed-Size Cells

When generating faces across a sign-change edge with different-sized neighboring cells, the algorithm must find all leaf cells adjacent to that edge. In a uniform grid, each edge in 3D has exactly 4 adjacent cells. In an octree, a large cell might neighbor multiple small cells along one face.

The recursive face/edge procedure:
1. For each face between two octree nodes, recurse until both sides are leaves.
2. For each edge shared by four octree nodes, recurse until all four are leaves.
3. At leaf level, if the edge has a sign change, emit a quad connecting the 4 leaf vertices.

When cells differ in size, the quad connects leaves at different octree depths. This naturally handles LOD transitions without cracks because:
- The large cell has one vertex (its QEF solution)
- The small cells each have one vertex
- The connecting quad smoothly bridges the resolution gap

---

## LOD with DC: Seam Stitching Between Octree Levels

### The Seam Problem

When the world is divided into chunks (each chunk is an octree), neighboring chunks at different LOD levels have mismatched vertices at their shared boundary. This creates visible cracks or T-junctions.

### Solution: Seam Nodes

The approach from Nick Gildea's implementation:

1. **Identify seam nodes.** For each chunk, collect all leaf nodes that touch the chunk boundary.
2. **Gather neighbor seam nodes.** For each neighboring chunk, collect their boundary-touching leaf nodes.
3. **Build a seam octree.** Construct a temporary octree from all collected seam nodes (from both chunks). This octree bridges the resolution gap.
4. **Generate seam mesh.** Run the standard DC face-generation on the seam octree. The resulting mesh fills the gap between chunks.

### Octree Simplification for LOD

To create coarser LOD levels:
1. Start from the finest octree.
2. For each parent node, **merge** the QEFs of its 8 children (by adding their ATA/ATb/BTb).
3. Solve the merged QEF to get the parent's vertex position.
4. If the error of the merged QEF is below a threshold, collapse the children into the parent (reduce detail).
5. Repeat up the octree to desired coarseness.

The QEF error at the merged vertex tells you how much geometric accuracy is lost by the simplification. This gives a principled way to control LOD quality.

### Crack-Free Property

DC on an octree is inherently crack-free between different cell sizes **within a single octree** because face generation always connects leaf vertices regardless of depth. Cracks only appear at **chunk boundaries** where separate octrees meet — hence the seam stitching.

---

## Implementation Considerations in Rust

### Crate Dependencies

```toml
[dependencies]
nalgebra = "0.33"        # Linear algebra, SVD solver
glam = "0.29"            # Fast Vec3/Mat3 for game math (Bevy-compatible)
```

`nalgebra` provides a robust SVD implementation. `glam` is Bevy's native math library. Use `nalgebra` for the QEF solver (it handles rank-deficient SVD properly) and `glam` for everything else.

### Core Data Structures

```rust
use glam::{Vec3, Mat3};

/// Sign at a grid vertex
#[derive(Clone, Copy, PartialEq, Eq)]
enum Sign { Inside, Outside }

/// Hermite data for one sign-change edge
struct HermiteEdge {
    intersection: Vec3,  // Where surface crosses the edge
    normal: Vec3,        // Surface normal at intersection
}

/// Compact QEF representation (10 floats + mass point tracking)
struct Qef {
    ata_xx: f32, ata_xy: f32, ata_xz: f32,
    ata_yy: f32, ata_yz: f32, ata_zz: f32,
    atb: Vec3,
    btb: f32,
    mass_point_sum: Vec3,
    num_points: u32,
}

/// A cell in the grid or octree
struct Cell {
    min: Vec3,           // Cell minimum corner
    size: f32,           // Cell side length
    qef: Qef,
    vertex: Option<Vec3>, // Solved vertex position
    signs: [Sign; 8],    // Corner signs
}

/// Edge index: which axis (X=0, Y=1, Z=2) + grid position
struct EdgeIndex {
    axis: u8,
    x: u32, y: u32, z: u32,
}
```

### QEF Solver in Rust with nalgebra

```rust
use nalgebra::{Matrix3, Vector3, SymmetricEigen};

impl Qef {
    fn new() -> Self {
        Self {
            ata_xx: 0.0, ata_xy: 0.0, ata_xz: 0.0,
            ata_yy: 0.0, ata_yz: 0.0, ata_zz: 0.0,
            atb: Vec3::ZERO,
            btb: 0.0,
            mass_point_sum: Vec3::ZERO,
            num_points: 0,
        }
    }

    fn add(&mut self, point: Vec3, normal: Vec3) {
        // Accumulate outer product n * n^T into symmetric ATA
        self.ata_xx += normal.x * normal.x;
        self.ata_xy += normal.x * normal.y;
        self.ata_xz += normal.x * normal.z;
        self.ata_yy += normal.y * normal.y;
        self.ata_yz += normal.y * normal.z;
        self.ata_zz += normal.z * normal.z;

        // Accumulate ATb
        let d = normal.dot(point);
        self.atb += normal * d;

        // Accumulate BTb
        self.btb += d * d;

        // Track mass point
        self.mass_point_sum += point;
        self.num_points += 1;
    }

    fn solve(&self, cell_min: Vec3, cell_max: Vec3, bias: f32) -> (Vec3, f32) {
        let mp = self.mass_point_sum / self.num_points as f32;

        // Build ATA as nalgebra symmetric matrix
        let ata = Matrix3::new(
            self.ata_xx + bias, self.ata_xy,        self.ata_xz,
            self.ata_xy,        self.ata_yy + bias, self.ata_yz,
            self.ata_xz,        self.ata_yz,        self.ata_zz + bias,
        );

        // Build ATb with bias toward mass point
        let atb = Vector3::new(
            self.atb.x + mp.x * bias,
            self.atb.y + mp.y * bias,
            self.atb.z + mp.z * bias,
        );

        // Eigen decomposition of symmetric matrix
        let eigen = SymmetricEigen::new(ata);
        let threshold = eigen.eigenvalues.max() * 1e-6;

        // Pseudo-inverse solve
        let mut result = Vector3::zeros();
        for i in 0..3 {
            let ev = eigen.eigenvalues[i];
            if ev > threshold {
                let col = eigen.eigenvectors.column(i);
                result += col * (col.dot(&atb) / ev);
            }
        }

        let vertex = Vec3::new(result.x, result.y, result.z);

        // Clamp to cell bounds
        let clamped = vertex.clamp(cell_min, cell_max);

        // Compute error
        let error = self.error(clamped);

        (clamped, error)
    }

    fn error(&self, x: Vec3) -> f32 {
        let xn = Vector3::new(x.x, x.y, x.z);
        let ata = Matrix3::new(
            self.ata_xx, self.ata_xy, self.ata_xz,
            self.ata_xy, self.ata_yy, self.ata_yz,
            self.ata_xz, self.ata_yz, self.ata_zz,
        );
        let atb = Vector3::new(self.atb.x, self.atb.y, self.atb.z);
        (xn.transpose() * ata * xn)[0] - 2.0 * xn.dot(&atb) + self.btb
    }

    fn merge(&self, other: &Qef) -> Qef {
        Qef {
            ata_xx: self.ata_xx + other.ata_xx,
            ata_xy: self.ata_xy + other.ata_xy,
            ata_xz: self.ata_xz + other.ata_xz,
            ata_yy: self.ata_yy + other.ata_yy,
            ata_yz: self.ata_yz + other.ata_yz,
            ata_zz: self.ata_zz + other.ata_zz,
            atb: self.atb + other.atb,
            btb: self.btb + other.btb,
            mass_point_sum: self.mass_point_sum + other.mass_point_sum,
            num_points: self.num_points + other.num_points,
        }
    }
}
```

### Performance Considerations

- **SIMD:** The QEF accumulation (outer products, dot products) maps well to SIMD. Use `glam`'s SIMD-backed Vec3 for the inner loop.
- **Memory layout:** For uniform grids, store QEFs in a flat `Vec<Qef>` indexed by `(x, y, z)`. For octrees, use arena allocation to avoid per-node heap allocation.
- **Parallelism:** QEF solving is per-cell and embarrassingly parallel. Face generation requires adjacency lookups but can be parallelized by axis (X-faces, Y-faces, Z-faces independently).
- **Arena allocator:** For octree nodes, use a bump allocator (`bumpalo` crate) to avoid allocation overhead. Octree construction and destruction happen in bulk.

---

## Sharp Cliffs AND Smooth Beaches from the Same Scalar Field

### The Design Challenge

European coastlines need two very different surface behaviors from the same mesh:
- **Cliffs:** Sharp, well-defined lip where the plateau drops to the sea. The edge must be crisp, not rounded.
- **Beaches:** Smooth, gradual slope from land to water. The transition must be gentle, not stepped.

### Scalar Field Design

Define a 3D scalar field `f(x, y, z)` where:
- `f > 0` = solid terrain
- `f < 0` = air/water
- `f = 0` = the terrain surface

**For cliffs:** The scalar field has a sharp gradient change at the cliff lip. The field transitions rapidly from positive (plateau) to negative (air below cliff) over a short distance. The QEF naturally places vertices at the sharp transition.

**For beaches:** The scalar field transitions gradually from positive (land above water) to negative (below waterline) over a long horizontal distance. The gentle gradient produces gentle QEF solutions — no sharp edge detected.

### Controlling Sharpness via the Field

```rust
fn terrain_field(pos: Vec3, heightmap: &Heightmap, coastal_data: &CoastalData) -> f32 {
    let ground_height = heightmap.sample(pos.x, pos.z);
    let base_field = pos.y - ground_height;  // Positive above ground

    // Check if this is a beach or cliff zone
    let beach_factor = coastal_data.beach_factor(pos.x, pos.z);

    if beach_factor > 0.0 {
        // Beach: smooth the field transition over a wide band
        // This makes the gradient gentle -> QEF produces smooth vertex placement
        let smoothing = beach_factor * 5.0; // Wider transition
        base_field / (1.0 + smoothing)
    } else {
        // Cliff: keep the field sharp
        // Steep gradient -> QEF detects the feature edge
        base_field
    }
}
```

### Gradient (Normal) Control

The surface normal is even more important than the field value for sharp features. At cliffs, normals change direction abruptly (pointing UP on the plateau, pointing OUT on the cliff face). At beaches, normals rotate smoothly from UP to slightly tilted.

```rust
fn terrain_gradient(pos: Vec3, heightmap: &Heightmap, coastal_data: &CoastalData) -> Vec3 {
    let beach_factor = coastal_data.beach_factor(pos.x, pos.z);

    if beach_factor > 0.0 {
        // Beach: smooth normal transition
        // Blend between vertical and terrain-following
        let terrain_normal = heightmap.normal(pos.x, pos.z);
        terrain_normal.normalize()
    } else {
        // Cliff: allow sharp normal discontinuity
        // The QEF will detect the feature from the normal difference
        central_difference_gradient(pos)
    }
}
```

### Adaptive Resolution at Coastlines

Use the octree to place more cells at the coastline:

```rust
fn should_subdivide(cell: &OctreeCell, coastal_data: &CoastalData) -> bool {
    let center = cell.center();
    let dist_to_coast = coastal_data.distance_to_coastline(center.x, center.z);

    // High resolution within 2km of coast
    if dist_to_coast < 2.0 && cell.size > 0.1 {
        return true;
    }

    // Medium resolution within 10km
    if dist_to_coast < 10.0 && cell.size > 0.5 {
        return true;
    }

    // Coarse resolution inland/offshore
    cell.size > 2.0
}
```

---

## Non-Manifold Topology Risks and Solutions

### What Is Non-Manifold Geometry?

A 2-manifold mesh means every edge is shared by exactly 2 faces, and every vertex has a disk-like neighborhood. Non-manifold violations include:
- **T-junctions:** An edge shared by 3+ faces
- **Pinch vertices:** A vertex where two separate surface sheets meet at a point
- **Self-intersections:** Faces that overlap or cross each other

### Why DC Produces Non-Manifold Output

DC can create non-manifold geometry in several situations:

1. **Vertex outside cell:** When the QEF solution falls outside the cell and is clamped, the clamped position can cause face inversions or self-intersections with neighboring cells.

2. **Thin features:** When the surface passes through a cell twice (enters and exits on different sides), a single vertex cannot represent both intersection regions. The resulting faces can create T-junctions.

3. **Octree adaptivity:** When a large cell neighbors multiple small cells, the face connecting one large-cell vertex to multiple small-cell vertices can create non-manifold configurations if the surface topology is complex in that region.

4. **Ambiguous configurations:** Some cell configurations have multiple valid topologies (like MC's ambiguous cases). DC with one vertex per cell always picks one interpretation, which may not match the neighboring cell's choice.

### Solutions

**1. Manifold Dual Contouring (MDC)** — Schaefer, Ju, Warren (2007)

MDC allows **multiple vertices per cell** (up to 4 in 3D). When a cell has a complex topology (surface enters and exits multiple times), each connected component of the surface within the cell gets its own vertex. This guarantees 2-manifold output.

The cost: more complex implementation, more vertices, and the need for a topology analysis per cell.

**2. Vertex clamping with intersection testing**

After solving QEFs and generating faces, test for self-intersections and fix them:
- Re-clamp offending vertices
- Split non-manifold vertices
- Remove degenerate faces (zero area)

**3. Limiting octree adaptivity**

Restrict the octree so neighboring cells differ by at most 1 level. This prevents the extreme size mismatches that cause most non-manifold issues. This is the "restricted octree" or "balanced octree" constraint.

**4. Post-processing cleanup**

For terrain rendering (as opposed to 3D printing or boolean operations), non-manifold vertices are often visually harmless. A pragmatic approach:
- Generate the DC mesh allowing non-manifold output
- Remove degenerate faces (area < epsilon)
- Optionally split non-manifold vertices for correct normal interpolation
- Accept minor T-junctions as they are usually invisible at terrain scale

### For This Project

For European terrain with cliffs and beaches, non-manifold risks are LOW because:
- The terrain is a heightmap (2.5D), not a full 3D volume with caves/overhangs
- The surface passes through each cell at most once (no thin features)
- Octree depth differences are bounded (coastline vs inland, not extreme)

The main risk is out-of-cell vertices at cliff edges. Use mass-point bias (lambda = 0.01-0.1) and cell clamping to prevent this. If non-manifold issues appear, the restricted octree constraint is the simplest fix.

---

## References

### Primary Papers
- Ju, Losasso, Schaefer, Warren. "Dual Contouring of Hermite Data." SIGGRAPH 2002. — The foundational paper.
- Schaefer, Ju, Warren. "Manifold Dual Contouring." IEEE TVCG 2007. — Fixes non-manifold issues.
- Schaefer, Warren. "Dual Contouring: The Secret Sauce." — Accessible explanation of QEF and sharp features.

### Tutorials and Implementations
- Boris the Brave: [Dual Contouring Tutorial](https://www.boristhebrave.com/2018/04/15/dual-contouring-tutorial/) — Clear walkthrough with 2D/3D examples.
- Matt Keeter: [QEF Explainer](https://www.mattkeeter.com/projects/qef/) — Detailed QEF math and compact representation.
- Nick Gildea: [Implementing Dual Contouring](http://ngildea.blogspot.com/2014/11/implementing-dual-contouring.html) — Practical implementation details.
- Nick Gildea: [Seams and LOD for Chunked Terrain](http://ngildea.blogspot.com/2014/09/dual-contouring-chunked-terrain.html) — Octree LOD and seam stitching.
- [Interactive Explanation of MC and DC](https://wordsandbuttons.online/interactive_explanation_of_marching_cubes_and_dual_contouring.html) — Visual interactive comparison.

### Code References
- [nickgildea/fast_dual_contouring](https://github.com/nickgildea/fast_dual_contouring) — C++ implementation without octree.
- [nickgildea/qef](https://github.com/nickgildea/qef) — QEF solver implementations (CPU and GPU/GLSL).
- [Tuntenfisch/Voxels](https://github.com/Tuntenfisch/Voxels) — GPU-based DC in Unity.
