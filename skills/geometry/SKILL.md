---
name: geometry
description: Guide for terrain mesh generation, coastline/cliff/beach geometry, ocean planes, country polygons, territory overlays, and the offline GLB generation tool. Apply when modifying any terrain, coastal, heightmap, triangulation, or map geometry code.
user-invocable: true
allowed-tools: Read, Grep, Bash, Edit, Write, Agent, Glob
---

# Terrain & Geometry Generation Guide

This skill covers ALL geometry generation in the project: terrain meshes, cliff walls, beach slopes, ocean planes, country polygons, border meshes, territory overlays, and the offline GLB generation tool. **Load this skill before making any changes to these systems.**

---

## File Inventory

### Core Geometry Files

| File | Purpose |
|------|---------|
| `src/game/map.rs` | Terrain mesh loading, LOD switching, chunk splitting, border meshes, terrain country map, grid constants |
| `src/sea.rs` | Coastal strip mesh, cliff geometry generation, ocean plane, beach zone definitions, material structs |
| `src/heightmap.rs` | Heightmap loading, bilinear sampling, fog boundary fade |
| `src/triangulate.rs` | Ear-clipping polygon triangulation, adaptive edge subdivision |
| `src/game/territory_overlay.rs` | Territory ownership overlay mesh (built from terrain surface vertices) |
| `src/bin/gen_cliff_glb.rs` | **Offline tool**: generates unified terrain + cliff GLB files for LOD 0 and LOD 1 |

### Polygon Data

| File | Contents |
|------|----------|
| `src/geo/europe.rs` | 18 playable European nation polygons |
| `src/geo/europe_bg.rs` | 27 background European country polygons |
| `src/geo/middle_east.rs` | 8 Middle East country polygons |
| `src/geo/north_africa.rs` | 8 North African country polygons |
| `src/geo/caucasus.rs` | 3 Caucasus region polygons |
| `src/geo/central_asia.rs` | 4 Central Asian / Caspian region polygons |
| `src/geo/arabian_peninsula.rs` | 4 Arabian Peninsula polygons |
| `src/geo/south_asia.rs` | 4 South/Central Asian polygons |
| `src/geo/horn_of_africa.rs` | 2 Horn of Africa polygons |
| `src/geo/west_africa.rs` | 3 West/Central African polygons |

### Generated Assets

| Asset | Source | Format |
|-------|--------|--------|
| `assets/models/coastline_lod0.glb(.gz)` | `gen_cliff_glb.rs` | GLB mesh (2048x1560 grid + cliffs) |
| `assets/models/coastline_lod1.glb(.gz)` | `gen_cliff_glb.rs` | GLB mesh (4096x3120 grid + cliffs) |
| `assets/models/coastline_map_lod0.bin(.gz)` | `gen_cliff_glb.rs` | Binary (grid -> country index mapping) |
| `assets/models/coastline_map_lod1.bin(.gz)` | `gen_cliff_glb.rs` | Binary (grid -> country index mapping) |
| `assets/heightmap.bin` | External (embedded at compile time) | u8 grid (512x320) |
| `assets/terrain_native_v2.jpg` | External | 8192x8192 satellite imagery |

### Shader Files (geometry-relevant)

| Shader | Geometry Role |
|--------|---------------|
| `assets/shaders/terrain_material.wgsl` | Decodes oct-normals, blends terrain/cliff/beach by vertex alpha |
| `assets/shaders/ocean_material.wgsl` | Gerstner wave vertex displacement on ocean plane |
| `assets/shaders/coast_material.wgsl` | Coastal strip sand/rock blending by slope |
| `assets/shaders/sea_material.wgsl` | Animated sea surface for coastal strip |
| `assets/shaders/fog_material.wgsl` | Edge fog overlay |

---

## Critical Constants (MUST Stay in Sync)

These constants span multiple files. Changing one without updating the others **will** create visual artifacts.

### World Grid Bounds

| Constant | Value | File | Used By |
|----------|-------|------|---------|
| `GRID_LON_MIN` | -20.0 | `map.rs` | `territory_overlay.rs`, `gen_cliff_glb.rs`, `sea.rs` |
| `GRID_LON_MAX` | 82.0 | `map.rs` | Same |
| `GRID_LAT_MIN` | -2.0 | `map.rs` | Same |
| `GRID_LAT_MAX` | 76.0 | `map.rs` | Same |

### Grid Resolution (per LOD)

| LOD | Cols | Rows | File |
|-----|------|------|------|
| 0 | 2048 | 1560 | `map.rs` (`GRID_COLS/ROWS`), `gen_cliff_glb.rs` |
| 1 | 4096 | 3120 | `gen_cliff_glb.rs` |

### Chunk Grid

| Constant | Value | File | Used By |
|----------|-------|------|---------|
| `CHUNK_COLS` | 8 | `map.rs` | `territory_overlay.rs` |
| `CHUNK_ROWS` | 6 | `map.rs` | `territory_overlay.rs` |

### Height / Y-Level Constants (CRITICAL SYNC)

| Constant | Value | File | Constraint |
|----------|-------|------|------------|
| `BEACH_BASE_Y` | -0.35 | `gen_cliff_glb.rs` | Must be < Ocean Y (-0.25) |
| Ocean surface Y | -0.25 | `sea.rs` (`spawn_sea` Transform) | Water surface level |
| `CLIFF_BASE_Y` | -0.2 | `gen_cliff_glb.rs` | Cliff wall bottom |
| `CLIFF_WATER_Y` | -0.12 | `sea.rs` | Cliff base in runtime strip |
| `MIN_LAND_H` | 0.03 | `gen_cliff_glb.rs` | Min land vertex height (skipped for beach) |
| `MAX_TERRAIN_HEIGHT` | 0.4 | `heightmap.rs` | Max displacement |
| `OVERLAY_Y_OFFSET` | 0.015 | `territory_overlay.rs` | Above terrain (z-fighting) |

**Rule: `BEACH_BASE_Y` < Ocean Y < `CLIFF_BASE_Y` < `MIN_LAND_H` < `MAX_TERRAIN_HEIGHT`**

### LOD Switching Thresholds

| Constant | Value | File |
|----------|-------|------|
| `LOD_ZOOM_IN` | 32.0 | `map.rs` |
| `LOD_ZOOM_OUT` | 38.0 | `map.rs` |

### Vertex Color Encoding

Vertex color alpha controls material blending in `terrain_material.wgsl`:

| Alpha | Material | Source |
|-------|----------|--------|
| 1.0 | Pure satellite texture | Inland land vertices |
| 0.75-0.92 | Coastal blend (graduated by BFS distance) | `gen_cliff_glb.rs` coastal mask |
| 0.45-0.60 | Cliff texture dominant | `gen_cliff_glb.rs` coast edge |
| 0.0 | Pure beach sand | `gen_cliff_glb.rs` beach vertices |

### Beach Zone Rectangles

Defined in `sea.rs` as `BEACH_REGIONS: &[(lon_min, lon_max, lat_min, lat_max)]`. Each rectangle must **actually cover the coastline geometry** (not just the named geographic area). Add 0.5-1.0 degree margin.

---

## Architecture: Three Overlapping Geometry Layers

The coastline rendering involves THREE overlapping geometry layers. Understanding this is essential for any coastal work:

1. **Terrain surface mesh** -- Grid of triangles, some land, some ocean. Heights from heightmap + beach slope. Generated by `gen_cliff_glb.rs`.
2. **Cliff wall mesh** -- Vertical quads extruded downward from boundary edges (land->ocean transitions). Also in `gen_cliff_glb.rs`.
3. **Ocean surface mesh** -- Flat plane at y=-0.25 with wave shader. Generated by `sea.rs::spawn_sea()`.

**Non-beach coastlines**: Layer 2 (cliff walls) hides the ugly boundary between layers 1 and 3.

**Beach coastlines**: Layer 2 is removed. Layer 1 must slope smoothly BELOW layer 3 so the ocean covers the transition. Any terrain triangle poking above y=-0.25 will be visible as a spike.

---

## The `beach_skip` Array (Canonical Beach Decision Source)

In `gen_cliff_glb.rs`, the `beach_skip` array is the **single source of truth** for "should this vertex/edge/cell be treated as beach?" It is computed once after the taper BFS and used everywhere. Do NOT add new ad-hoc checks against `beach_factor` or `is_beach_zone()` -- use `beach_skip[]` instead.

---

## Coastal Distance BFS (Blue Satellite Bleeding Fix)

A BFS from ALL ocean-adjacent land vertices propagates distance inland up to `COASTAL_MASK_CELLS = 4` cells. Each distance ring gets progressively weaker warm tint and higher alpha:

| Distance | Alpha | Cliff Blend % | Purpose |
|----------|-------|---------------|---------|
| 0 (coast edge) | 0.45 | ~88% | Strong mask, hides all blue |
| 1 | 0.60 | ~56% | Moderate transition |
| 2 | 0.78 | ~12% | Mild tint, mostly satellite |
| 3 | 0.92 | ~0% | Subtle warm tint only |
| 4+ | 1.0 | 0% | Pure satellite texture |

These alphas are tuned relative to `terrain_material.wgsl`'s `smoothstep(0.85, 0.45, alpha)`. If the shader blend curve changes, these must be re-tuned.

---

## Ocean Vertex Color Override

Ocean vertices in mixed land/ocean cell triangles must NOT use default `[1.0, 1.0, 1.0, 1.0]` (pure satellite = blue ocean). They get cliff-like or beach colors to prevent blue fringe at cliff tops via GPU interpolation.

---

## Offline GLB Generation

```bash
cargo run --bin gen-cliff-glb
```

Generates both LOD levels. Output:
- `assets/models/coastline_lod0.glb` + `coastline_map_lod0.bin`
- `assets/models/coastline_lod1.glb` + `coastline_map_lod1.bin`

The sidecar binary format:
```
[u32] terrain_vertex_count
[u32] cols, rows
[u32 x cols*rows] grid_to_vert (mesh index or u32::MAX)
[u16 x cols*rows] vertex_country (country index per grid cell)
```

**After regenerating GLBs, you must test in-game** to verify no visual regressions (blue bleeding, cliff spikes, beach gaps).

---

## Runtime Mesh Pipeline

### Startup Order
1. `heightmap::init_heightmap()` -- Load HeightmapData resource
2. `map::spawn_map()` -- Load terrain textures, GLB models, spawn country entities, borders
3. `sea::spawn_sea()` -- Spawn ocean plane + fog overlay
4. `territory_overlay::build_territory_overlay()` -- Build overlay from terrain vertices (after mesh loads)
5. `map::split_terrain_into_chunks()` -- Split unified terrain into frustum-culled chunks

### LOD Switching
- `terrain_lod_system()` runs every frame
- LOD 1 is lazy-loaded on first zoom-in (camera distance < `LOD_ZOOM_IN`)
- Hysteresis: zoom in at 32, zoom out at 38 (prevents oscillation)
- Both LODs persist in memory (visibility toggled, not despawned)

### Territory Overlay
- Built once from terrain surface vertices (filters out cliff/beach by alpha < 0.70 and Y < -0.05)
- Same chunk grid as terrain for frustum culling
- Vertex colors updated in-place on game state changes (NOT on mouse hover -- see VRAM leak fix)

---

## Performance Rules

1. **Never re-upload mesh data on mouse hover.** The `HoveredCountry` resource is separate from `GameState` to prevent `resource_changed::<GameState>` cascades that trigger expensive GPU re-uploads of overlay meshes.

2. **Both LOD levels persist in VRAM.** Hidden LOD chunks have `Visibility::Hidden` but their GPU buffers remain allocated. Total: ~950K vertices across both LODs.

3. **`RenderAssetUsages::default()`** keeps both CPU and GPU copies. For read-only meshes, consider `RENDER_WORLD` only to halve memory.

4. **Octahedral normal encoding** (`ATTRIBUTE_OCT_NORMAL`, Snorm16x2) saves 8 bytes/vertex vs Float32x3 normals on terrain chunks.

5. **All coastal strip mesh is merged into a single draw call** via `build_merged_coastal_strip()`.

---

## DO NOT Rules

1. **Do NOT smooth terrain surface vertices in XZ.** Grid positions must stay locked to geographic lon/lat. Smoothness must come from shaders, higher mesh resolution, or cliff wall geometry.

2. **Do NOT remove cliff walls from beach zones without also handling the exposed terrain triangles.** Skip mixed land/ocean cells or ensure all vertices are below ocean surface.

3. **Do NOT change `BEACH_BASE_Y` without checking it stays below ocean Y** (-0.25 in `spawn_sea`).

4. **Do NOT add new ad-hoc checks against `beach_factor` or `is_beach_zone()`.** Use the `beach_skip[]` array.

5. **Do NOT change the terrain shader's `smoothstep` blend thresholds without re-tuning the coastal distance BFS alpha values** in `gen_cliff_glb.rs`.

6. **Do NOT store frequently-changing state in `GameState`** if it triggers `resource_changed` cascades. Use a separate resource (see `HoveredCountry` pattern).

---

## Checklist Before Submitting Geometry Changes

- [ ] Constants in sync across `map.rs`, `sea.rs`, `gen_cliff_glb.rs`, `territory_overlay.rs`
- [ ] `BEACH_BASE_Y` < Ocean Y (-0.25) < `CLIFF_BASE_Y`
- [ ] Beach zone rectangles cover actual coastline geometry with margin
- [ ] No blue satellite bleeding at coastlines (check close-up at Spain, Norway, Italy)
- [ ] No cliff spikes at beach zone boundaries
- [ ] No terrain triangles poking above ocean in beach zones
- [ ] No visible texture tiling on cliff faces
- [ ] Overlay doesn't z-fight with terrain
- [ ] Both LODs render correctly (zoom in and out)
- [ ] Run `cargo test -p europe-zone-control --lib` -- all pass
