---
name: geometry-debugging
description: Mesh debugging techniques for terrain/cliff/beach geometry — diagnostic output interpretation, runtime overlays, VRAM profiling, grid math, and change detection pitfalls
globs:
  - crates/europe-zone-control/src/bin/gen_cliff_glb.rs
  - crates/europe-zone-control/src/game/map.rs
  - crates/europe-zone-control/src/camera.rs
  - crates/europe-zone-control/src/bin/vram_bench.rs
  - crates/europe-zone-control/src/game/territory_overlay.rs
  - crates/europe-zone-control/src/sea.rs
---

# Geometry Debugging Skill

Reference for diagnosing mesh geometry issues, interpreting build-time diagnostic output, using runtime debug overlays, profiling VRAM, and avoiding Bevy change detection pitfalls.

---

## 1. gen_cliff_glb Diagnostic Output

The offline mesh generator (`src/bin/gen_cliff_glb.rs`) prints diagnostic lines to stderr during the build. Run it with:

```bash
cargo run -p europe-zone-control --bin gen-cliff-glb
```

### Log Lines and Expected Values

| Log line pattern | Expected (LOD0, 2048x1560) | What it means |
|---|---|---|
| `Building terrain+cliff mesh (2048x1560) -> coastline_lod0.glb...` | Always printed first | Grid dimensions and output file name |
| `Micro-island filter: removed N islands < K cells` | ~27 islands removed | BFS found small disconnected land blobs and reclassified them as ocean. If N increases significantly, a coastline polygon may have shrunk or a new polygon introduced tiny slivers. |
| `Beach taper: N vertices outside rectangle boundaries` | Varies by beach config | Taper BFS extended beach_factor beyond BEACH_REGIONS rectangles. Higher N = wider feathered transition. |
| `Island protection: N islands (M vertices) exempted from beach` | Low single digits | Islands where beach slope would submerge >50% of land area are exempted. If N increases, check BEACH_REGIONS overlap with small islands. |
| `Beach factor smoothed (K Laplacian passes)` | K=10 | Laplacian smoothing of beach_factor for gradual slope transitions. |
| `Coastal mask: N land vertices within K cells of ocean` | K=4, N in thousands | BFS distance mask for blue-satellite-bleed fix. N depends on total coastline length. |
| `Beach subdivision: N cells subdivided (4 tris each vs 2)` | Varies | Beach-zone cells split into 4 triangles (vs 2) for smoother slope. More subdivisions = smoother beach but more geometry. |
| `Terrain: N vertices` | ~1.99M at LOD0 | Total terrain surface vertices (land + ocean grid + beach subdivisions). |
| `Terrain: N triangles` | ~3.95M at LOD0 | Total terrain surface triangles. |
| `Beach zone: N/M cliff edges skipped` | ~1066/27976 at LOD0 | N cliff edges in beach zones were not extruded. M is total boundary edges. If N drops, beach zones may have shrunk. |
| `Cliff walls: N vertices, M triangles` | ~53800 verts at LOD0 | Cliff wall geometry extruded downward from land-ocean boundary edges. |
| `Smoothed cliff vertices (30 passes, synced to terrain)` | Always printed | Laplacian smoothing of cliff wall positions for smoother appearance. |
| `Total: N vertices, M triangles` | ~2.04M verts, ~3.98M tris | Combined terrain + cliff. This is the final mesh size. |
| `Wrote coastline_lod0.glb` | File output confirmation | |
| `Gzipped ... -> ... (X -> Y bytes)` | GLB and sidecar .bin | Compression ratio. LOD0 GLB is typically 30-50MB uncompressed. |

### How to Interpret Changes

- **Vertex count increased by thousands**: New geometry was added. Check if beach subdivision expanded (more beach cells) or cliff walls grew (fewer edges skipped).
- **Vertex count decreased**: Beach regions expanded (more cliff edges skipped, fewer cliff wall verts) or micro-island filter removed more islands.
- **"Cliff edges skipped" ratio changed**: BEACH_REGIONS rectangles were modified, or beach_factor thresholds changed. A lower skip count means more cliff walls are being emitted in beach zones (potential spike artifacts).
- **"Micro-island filter" count changed significantly**: Country polygon geometry changed, or the minimum island cell threshold was adjusted.
- **Terrain triangles changed but vertices didn't**: Index buffer changed (cell skip logic modified) without adding/removing vertices.

### Adding Your Own Diagnostic Counters

Pattern for counting boundary vertices, skip decisions, or height ranges:

```rust
// Count how many vertices fall in a specific height range
let mut low_verts = 0usize;
let mut high_verts = 0usize;
for idx in 0..total_verts {
    if is_land[idx] {
        if heights[idx] < 0.05 {
            low_verts += 1;
        } else if heights[idx] > 2.0 {
            high_verts += 1;
        }
    }
}
eprintln!("  Height distribution: {low_verts} below 0.05, {high_verts} above 2.0");

// Count skip decisions at a boundary
let mut skipped = 0usize;
let mut emitted = 0usize;
for edge in &boundary_edges {
    if should_skip(edge) {
        skipped += 1;
    } else {
        emitted += 1;
    }
}
eprintln!("  Boundary edges: {emitted} emitted, {skipped} skipped");
```

Always use `eprintln!` (not `println!`) so diagnostics go to stderr and don't interfere with piped output.

---

## 2. Runtime Debug Overlays

### F1 -- Terrain Diagnostics Overlay

**File**: `src/game/map.rs`, function `terrain_diagnostics`

Press **F1** to toggle an on-screen overlay showing:

```
F1 Terrain | LOD 1 | 12/45 chunks | 487.2K verts | 965.1K tris | cam 25
```

| Field | Meaning |
|---|---|
| LOD N | Active terrain LOD level (0 = far/coarse, 1 = near/detailed) |
| N/M chunks | Visible/total terrain chunks (frustum culled) |
| X.XK verts | Visible vertex count (summed across visible chunks) |
| X.XK tris | Visible triangle count |
| cam N | Camera distance (zoom level) |

Also logs to `info!` every 3 seconds for headless/CI diagnostics.

**What to look for**:
- If visible chunks is always equal to total chunks, frustum culling may be broken
- If vertex count drops to 0, terrain mesh failed to load or split
- LOD should switch at the `LOD_ZOOM_IN` threshold (check camera distance)

### F3 -- Wireframe Mode

**File**: `src/camera.rs`, function `toggle_wireframe`

Press **F3** to toggle global wireframe rendering. Reveals:
- Mesh topology (triangle edges visible)
- Degenerate triangles (long thin slivers, zero-area faces)
- T-junctions where edges meet but vertices don't align
- Beach subdivision boundaries (4-tri cells vs 2-tri cells)
- Cliff wall quad subdivision patterns

Combine with F4 (ocean off) to see terrain wireframe under the water surface.

### F4 -- Ocean/Fog Toggle

**File**: `src/camera.rs`, function `toggle_ocean`

Press **F4** to hide/show ocean and fog meshes. Essential for:
- Seeing terrain geometry that's normally underwater
- Verifying beach slope goes below ocean surface (y = -0.25)
- Checking cliff wall base extends deep enough
- Identifying mixed land/ocean cells that poke above water ("spike" artifacts)

### Camera Coordinate Overlay

**File**: `src/camera.rs`, `CameraCoordText` component

Always-visible overlay in bottom-left:
```
Cam: (5.2, 42.1) d=30.0
```

Shows longitude, latitude, and zoom distance. Use for:
- Precise location reporting when filing geometry bugs
- Correlating visual artifacts to grid coordinates
- Verifying camera clamp bounds

### F2 -- Screenshot

Press **F2** to save a timestamped screenshot to `e2e/screenshots/live_<timestamp>.png`. Auto-screenshots every 30 seconds to `e2e/screenshots/auto_<N>.png` (ring buffer of 10).

---

## 3. VRAM Bench Tool

**File**: `src/bin/vram_bench.rs`

Isolates GPU memory usage per rendering subsystem.

```bash
cargo run -p europe-zone-control --bin vram-bench -- --layer N --duration S --interval I
```

### Layers

| Layer | What's enabled | Typical VRAM delta |
|---|---|---|
| 0 | Bare Bevy + window | Baseline (~200-400 MB) |
| 1 | + test cube (basic 3D) | +5-10 MB |
| 2 | + full game (terrain, sea, camera) | +200-500 MB |
| 3 | + node rendering | +20-50 MB |
| 4 | + troops | +50-100 MB |

### Environment Variables

| Var | Purpose |
|---|---|
| `BENCH_CUBES=N` | Spawn N cubes to test draw call scaling |
| `BENCH_BIG_MESH=N` | Create a single mesh with N vertices |
| `BENCH_LOAD_GLB=1` | Load terrain GLB in isolation |

### Reading AMD VRAM

```bash
# Instant reading
cat /sys/class/drm/card1/device/mem_info_vram_used

# Watch live (MB)
watch -n 1 'echo "VRAM: $(( $(cat /sys/class/drm/card1/device/mem_info_vram_used) / 1048576 )) MB"'

# All GPU memory counters
for f in /sys/class/drm/card1/device/mem_info_*; do echo "$(basename $f): $(cat $f)"; done
```

Key counters:
- `mem_info_vram_used` -- main VRAM (on integrated GPU, carved from system RAM)
- `mem_info_gtt_used` -- Graphics Translation Table (system RAM for GPU)
- `mem_info_vis_vram_used` -- CPU-visible VRAM

### Interpreting Results

The bench runs for `--duration` seconds, sampling every `--interval` seconds, then prints:
- Per-sample VRAM readings
- Linear regression slope (MB/s) -- should be ~0 for stable rendering
- If slope > 0.5 MB/s, there is likely a per-frame GPU re-upload leak

---

## 4. Grid Coordinate Math

The terrain is a regular grid with these constants (defined in `src/game/map.rs`):

```
GRID_COLS = 2048    GRID_ROWS = 1560
GRID_LON_MIN = -20.0   GRID_LON_MAX = 82.0
GRID_LAT_MIN = -2.0    GRID_LAT_MAX = 76.0
```

### Index Conversions

```rust
// Grid index <-> row/col
let idx = row * cols + col;
let row = idx / cols;
let col = idx % cols;

// Grid index <-> lon/lat
let lon = GRID_LON_MIN + (col as f32 / (cols - 1) as f32) * (GRID_LON_MAX - GRID_LON_MIN);
let lat = GRID_LAT_MIN + (row as f32 / (rows - 1) as f32) * (GRID_LAT_MAX - GRID_LAT_MIN);

// Lon/lat -> approximate grid col/row
let col = ((lon - GRID_LON_MIN) / (GRID_LON_MAX - GRID_LON_MIN) * (cols - 1) as f32) as usize;
let row = ((lat - GRID_LAT_MIN) / (GRID_LAT_MAX - GRID_LAT_MIN) * (rows - 1) as f32) as usize;
```

### Grid Cell Geometry

Each grid cell (row, col) to (row+1, col+1) is split into 2 triangles (or 4 in beach-subdivided cells). The four corner vertices are:

```
top-left:     idx = row * cols + col
top-right:    idx = row * cols + col + 1
bottom-left:  idx = (row + 1) * cols + col
bottom-right: idx = (row + 1) * cols + col + 1
```

### Neighbor Iteration (4-connected)

```rust
let neighbors = [
    (row.wrapping_sub(1), col),     // north
    (row + 1, col),                  // south
    (row, col.wrapping_sub(1)),     // west
    (row, col + 1),                  // east
];
for (nr, nc) in neighbors {
    if nr < rows && nc < cols {
        let nidx = nr * cols + nc;
        // ... use neighbor
    }
}
```

---

## 5. Common Diagnostic Patterns

### "Why did vertex count change?"

1. Run `gen-cliff-glb` before and after your change, diff the stderr output
2. Compare terrain verts vs cliff verts separately -- they are logged independently
3. If terrain verts changed: beach subdivision count changed, or cell skip logic modified
4. If cliff verts changed: cliff edges skipped count changed (beach zone boundaries moved)

### "Where is this visual artifact?"

1. Use camera coordinate overlay to note (lon, lat) of the artifact
2. Convert to grid coordinates using the formulas above
3. Add a targeted `eprintln!` in gen_cliff_glb at that grid location:
   ```rust
   if (row == target_row) && (col == target_col) {
       eprintln!("DEBUG vertex ({row},{col}): h={:.4}, beach_factor={:.4}, is_land={}, coastal_dist={}",
           heights[idx], beach_factor[idx], is_land[idx], coastal_distance[idx]);
   }
   ```

### "Is this triangle degenerate?"

Enable wireframe (F3) + hide ocean (F4). Degenerate triangles appear as:
- Very long thin slivers (high aspect ratio)
- Near-zero area (two edges nearly parallel)
- Triangles that cross the water surface (one vertex above, one below y=-0.25)

### "Did my change cause a regression?"

Use the screenshot harness for before/after comparison:
```bash
# Before change
cargo run -p europe-zone-control -- --view --screenshot before.png \
  --camera-x 5 --camera-z -50 --camera-distance 25

# After change (rebuild gen-cliff-glb first if geometry changed)
cargo run -p europe-zone-control -- --view --screenshot after.png \
  --camera-x 5 --camera-z -50 --camera-distance 25
```

### Comparing Mesh Builds (CLI)

```bash
# Save diagnostic output before and after
cargo run -p europe-zone-control --bin gen-cliff-glb 2> before.log
# ... make changes ...
cargo run -p europe-zone-control --bin gen-cliff-glb 2> after.log
diff before.log after.log
```

---

## 6. Bevy Change Detection Pitfalls

### The Core Rule: DerefMut = Changed

In Bevy 0.15, ANY `DerefMut` access on `ResMut<T>`, `Mut<T>`, or `Assets<T>::get_mut()` marks the resource as changed, **even if the data is identical or the operation is a no-op**.

### Dangerous Patterns (cause false change detection)

```rust
// LEAKS: .retain() on empty vec triggers DerefMut
game_state.disconnected_slots.retain(|s| ...);

// LEAKS: assigning same value triggers DerefMut
game_state.status_message = "same".into();

// LEAKS: iter_mut marks ALL materials as changed
materials.iter_mut();

// LEAKS: get_mut marks that specific mesh as changed
meshes.get_mut(&handle);
```

### Safe Patterns (no false change detection)

```rust
// Guard mutable access with immutable check
if game_state.disconnected_slots.is_empty() {
    return;  // No DerefMut, no change
}
game_state.disconnected_slots.retain(|s| ...);

// Read-only check before write
if *current_text != new_text {
    *current_text = new_text;
}

// Read-only material check before get_mut
let current_color = materials.get(&handle).map(|m| m.base_color);
if current_color != Some(new_color) {
    if let Some(mat) = materials.get_mut(&handle) {
        mat.base_color = new_color;
    }
}
```

### GPU Impact of False Change Detection

When `resource_changed::<GameState>` fires every frame:
1. `update_territory_overlay` rebuilds all 45 overlay chunk vertex colors
2. Each `mesh.insert_attribute()` triggers full GPU vertex buffer re-upload
3. 45 chunks x ~50KB x 30fps = ~1.8 GB/s of GPU memory churn
4. On AMD RADV (Mesa Vulkan), old GPU buffers are not reclaimed instantly
5. Result: unbounded VRAM growth

### How to Detect False Change Detection

1. Add a temporary system that logs when resources are marked changed:
   ```rust
   fn debug_change_detection(game_state: Res<GameState>) {
       if game_state.is_changed() {
           eprintln!("[change-detect] GameState changed this frame");
       }
   }
   ```
2. If the log fires every frame when no user input is happening, something is triggering DerefMut spuriously.
3. Use `vram-bench` to confirm: a positive MB/s slope in layer 2+ indicates per-frame re-uploads.

---

## 7. Checking for NaN/Inf and Height Anomalies

### Validation Pass After Vertex Generation

```rust
for (i, pos) in positions.iter().enumerate() {
    if pos.iter().any(|v| v.is_nan() || v.is_infinite()) {
        eprintln!("BAD VERTEX {i}: {:?} (row={}, col={})", pos, i / cols, i % cols);
    }
}
```

### Height Range Audit

```rust
let mut min_h = f32::MAX;
let mut max_h = f32::MIN;
let mut below_ocean = 0usize;
for idx in 0..total_verts {
    if is_land[idx] {
        min_h = min_h.min(heights[idx]);
        max_h = max_h.max(heights[idx]);
        if heights[idx] < -0.25 {
            below_ocean += 1;
        }
    }
}
eprintln!("  Land height range: [{min_h:.4}, {max_h:.4}], {below_ocean} below ocean surface");
```

### Identifying Heightmap Artifacts

Common artifacts and their diagnostic signatures:
- **Flat plateaus**: Many consecutive vertices with identical height -- check heightmap sampling resolution
- **Sharp ridges at cell boundaries**: Adjacent vertices with large height delta -- check interpolation between heightmap samples
- **Circular depressions**: Heightmap has local minima from data artifacts -- add minimum height clamping
- **Staircase stepping on slopes**: Heightmap quantization -- increase precision or add dithering

---

## 8. Key File Locations

| File | Purpose |
|---|---|
| `src/bin/gen_cliff_glb.rs` | Offline mesh generator (terrain + cliff walls) |
| `src/bin/vram_bench.rs` | VRAM leak profiling tool |
| `src/game/map.rs` | Runtime terrain loading, F1 overlay, chunk splitting, grid constants |
| `src/camera.rs` | F2 screenshot, F3 wireframe, F4 ocean toggle, camera coord overlay |
| `src/game/territory_overlay.rs` | Territory color overlay (major change detection consumer) |
| `src/sea.rs` | Ocean/sea mesh, BEACH_REGIONS, spawn_sea (ocean Y position) |
| `src/game/network.rs` | Source of the original VRAM leak (DerefMut on empty retain) |
