---
name: geometry-terrain-architecture
description: Terrain rendering architecture reference for the Europe Zone Control game. Covers the 3-layer mesh system, GLB generation pipeline, chunk splitting, LOD system, territory overlay, render ordering, and critical constants that must stay in sync.
user-invocable: true
allowed-tools: Read, Grep, Bash
---

# Terrain Rendering Architecture

This document describes the terrain rendering pipeline for the Europe Zone Control game. It covers offline mesh generation, runtime loading, chunk splitting for frustum culling, LOD switching, and the layering of terrain, cliff, ocean, and overlay meshes.

## The 3-Layer System

The coastline is rendered by three overlapping geometry layers that work together:

### Layer 1: Terrain Surface Mesh
- **Source**: `gen_cliff_glb.rs` (offline tool)
- **Runtime file**: `coastline_lod0.glb`, `coastline_lod1.glb`
- **Description**: A grid of triangles covering all land and near-coast ocean cells. Grid vertices are placed at geographic lon/lat positions (x=lon, z=-lat) with Y from the heightmap. Only cells with at least one land vertex are emitted.
- **Vertex colors**: Encode blend weights for the terrain shader. Alpha channel controls material blending: `1.0` = satellite texture, `~0.5` = cliff rock texture, `0.0` = beach sand texture. RGB carries warm tint to mask satellite blue bleeding near coasts.
- **Material**: `TerrainMaterial` (custom shader) blends satellite imagery, cliff rock texture, and beach sand texture based on vertex color alpha via `smoothstep`.

### Layer 2: Cliff Wall Mesh
- **Source**: `gen_cliff_glb.rs` (baked into same GLB as terrain surface)
- **Description**: Vertical quads extruded downward from boundary edges where land meets ocean. Each boundary edge (land vertex adjacent to ocean/void) generates a quad from the terrain height down to `CLIFF_BASE_Y` (-0.2). Cliff walls are the primary visual feature that hides the ugly land/ocean boundary.
- **Beach zones**: Cliff walls are SKIPPED in beach zones (controlled by `beach_skip[]` array). Instead, the terrain surface slopes smoothly below the ocean surface so water covers the transition.
- **Vertex colors**: Low alpha (~0.45) so the terrain shader renders cliff rock texture instead of satellite imagery.

### Layer 3: Ocean Surface Mesh
- **Source**: `sea.rs` `build_ocean_plane()` + `spawn_sea()`
- **Description**: A subdivided 384x384 plane centered at `(SEA_CX=15.0, -0.25, SEA_CZ=-53.0)` covering the entire map. Half-extents: 160.0 x 120.0 world units.
- **Material**: `OceanMaterial` (custom WGSL shader) with Gerstner wave vertex displacement, Beer-Lambert depth coloring, Fresnel reflections, subsurface scattering, Jacobian whitecaps, and shore foam.
- **Rendering**: `AlphaMode::Opaque`. The ocean plane sits at Y=-0.25, below most terrain but above beach slopes.

### How the Layers Interact

**Cliffed coastlines** (most of the map):
- Layer 2 (cliff walls) drops from terrain height to Y=-0.2, hiding the raw land/ocean boundary
- Layer 3 (ocean) at Y=-0.25 sits just below the cliff base, visible behind/below the cliff
- Layer 1 terrain triangles in mixed land/ocean cells are mostly hidden by cliff walls

**Beach coastlines** (defined by `BEACH_REGIONS` in `sea.rs`):
- Layer 2 is removed (no cliff walls in beach zones)
- Layer 1 terrain slopes smoothly from land height down to `BEACH_BASE_Y` (-0.35), well below the ocean at Y=-0.25
- Layer 3 ocean surface covers the beach-to-ocean transition
- Mixed land/ocean cell triangles with any beach vertex are skipped entirely to prevent spike artifacts

## Critical Constants That Must Stay In Sync

| Constant | File | Current Value | Purpose |
|----------|------|---------------|---------|
| `CLIFF_BASE_Y` | `gen_cliff_glb.rs:30` | `-0.2` | Bottom of cliff wall quads. Can be at or above ocean Y since cliff walls render in front of ocean. |
| `BEACH_BASE_Y` | `gen_cliff_glb.rs:33` | `-0.35` | Lowest point of beach terrain slope. **MUST be below ocean Y** so beach edges are submerged. |
| Ocean Y | `sea.rs:926` | `-0.25` | Y position of ocean surface plane (`Transform::from_xyz(SEA_CX, -0.25, SEA_CZ)`). |
| `MIN_LAND_H` | `gen_cliff_glb.rs:35` | `0.03` | Minimum height for land vertices so flat coasts have visible cliff edges. **Skipped for beach vertices** (beach_factor > 0.01). |
| `OVERLAY_Y_OFFSET` | `territory_overlay.rs:44` | `0.015` | Territory overlay sits this far above terrain surface vertices. |
| `MIN_OVERLAY_Y` | `territory_overlay.rs:55` | `-0.05` | Overlay vertices below this Y are excluded (near/under ocean). |
| `MIN_SURFACE_ALPHA` | `territory_overlay.rs:51` | `0.70` | Overlay excludes terrain vertices with vertex color alpha below this (cliff faces, beach transitions). |
| `COASTAL_MASK_CELLS` | `gen_cliff_glb.rs` | `4` | BFS distance for graduated coastal vertex color tinting to mask satellite blue bleeding. |
| `BEACH_TAPER_CELLS_BASE` | `gen_cliff_glb.rs:39` | `6` | Cells beyond beach rectangle edge where beach_factor tapers to zero. Scaled by LOD. |
| Fog Y | `sea.rs:940` | `0.5` | Fog overlay plane sits at Y=0.5, above everything. |

### What Breaks If Changed Independently

- **Raise `BEACH_BASE_Y` above ocean Y (-0.25)**: Beach terrain pokes above ocean surface, visible as spikes/teeth along all beach coastlines.
- **Lower ocean Y below `BEACH_BASE_Y`**: Beach terrain exposed above water where it should be submerged.
- **Change `MIN_LAND_H` without excluding beach vertices**: Beach slopes get forced back up to MIN_LAND_H, creating bumps at cliff tops.
- **Change `MIN_SURFACE_ALPHA` too low**: Territory overlay extends onto cliff faces, creating colored patches on vertical surfaces.
- **Change `MIN_OVERLAY_Y` too low**: Territory overlay vertices appear underwater, poking through the ocean surface.
- **Change grid bounds (GRID_LON_MIN/MAX, GRID_LAT_MIN/MAX) in map.rs**: Terrain mesh, chunk splitting, territory overlay, and country map all use these bounds. All must agree.

## GLB Generation Pipeline

The offline tool `gen_cliff_glb.rs` (run via `cargo run --bin gen-cliff-glb`) generates the terrain mesh:

```
HeightmapData (heightmap.rs)
    + Country polygons (countries.rs, geo/*.rs)
    + Beach zone rectangles (sea.rs::BEACH_REGIONS)
            |
            v
    gen_cliff_glb.rs::generate_lod()
            |
            +-- Step 1: Classify each grid vertex as land/ocean via point_in_polygon
            +-- Step 2: Remove micro-islands (< 20 cells)
            +-- Step 3: Compute beach_factor via BFS from BEACH_REGIONS + taper
            +-- Step 4: Compute coastal distance BFS for blue-bleeding mask
            +-- Step 5: Assign vertex heights (heightmap + beach slope + MIN_LAND_H)
            +-- Step 6: Assign vertex colors (satellite blend alpha, coastal tint)
            +-- Step 7: Emit terrain surface triangles (skip mixed beach cells)
            +-- Step 8: Find boundary edges, emit cliff wall quads (skip beach zones)
            +-- Step 9: Compute normals
            +-- Step 10: Write .glb file + country map .bin file
            |
            v
    coastline_lod0.glb (2048x1560 grid)
    coastline_lod1.glb (4096x3120 grid)
    coastline_map_lod0.bin (per-vertex country index)
    coastline_map_lod1.bin
```

### Output Files

- **`coastline_lodN.glb`**: Single-primitive GLTF binary containing all terrain surface triangles + cliff wall quads. Attributes: position, normal, UV, vertex color (RGBA).
- **`coastline_map_lodN.bin`**: Flat array of `u16` values, one per vertex, mapping each vertex to a country index. Used at runtime for hover detection and territory overlay.
- Files are gzip-compressed (`.gz`) in the repo. `ensure_decompressed()` in `map.rs` extracts them on first load (native only; WASM loads uncompressed).

## Runtime Loading and Chunk Splitting

### Loading Sequence (in `spawn_map`)

1. Decompress `.gz` files if needed (native only)
2. Load `coastline_map_lod0.bin` into `TerrainCountryMap` resource
3. Load `coastline_lod0.glb#Mesh0/Primitive0` as mesh handle
4. Store in `TerrainLodMeshes` resource (LOD 1 = None, loaded lazily)
5. Create `TerrainMaterial` with satellite texture, cliff texture, beach texture
6. Spawn single `UnifiedTerrain` entity with `TerrainLod(0)`, `Visibility::Visible`

### Chunk Splitting (`split_terrain_into_chunks`)

Runs once per LOD level when an unchunked `UnifiedTerrain` entity is detected (no `TerrainChunk` component).

**Grid**: `CHUNK_COLS=8` x `CHUNK_ROWS=6` = 48 chunks total.

**Algorithm**:
1. Extract all vertex attributes (position, normal, UV, color) and indices from the unified mesh
2. Assign each vertex to a chunk based on its world XZ position mapped to the chunk grid
3. Build per-chunk vertex and index arrays
4. For triangles spanning chunk boundaries: duplicate vertices into the first vertex's chunk
5. Spawn each non-empty chunk as a separate entity with its own mesh, tagged `TerrainChunk(i)` + `UnifiedTerrain` + `TerrainLod(N)`
6. Despawn the original unchunked entity

**Purpose**: Bevy's frustum culling operates per-entity. Without chunking, the entire terrain is one entity that is always visible. With 48 chunks, only chunks in the camera frustum are rendered.

**Normals**: Chunk meshes use octahedral-encoded `Snorm16x2` normals (`ATTRIBUTE_OCT_NORMAL`) instead of `Float32x3`, saving 8 bytes per vertex. The terrain shader decodes these.

## LOD System

Two detail levels exist for the terrain mesh:

| Property | LOD 0 (Low Detail) | LOD 1 (High Detail) |
|----------|--------------------|--------------------|
| Grid resolution | 2048 x 1560 | 4096 x 3120 |
| Cell size | ~0.05 degrees (~5.5 km) | ~0.025 degrees (~2.75 km) |
| Use case | Zoomed out, full map view | Zoomed in, close-up coastlines |
| Loading | Immediate at startup | Lazy on first zoom-in |
| GPU memory | ~90 MB | ~360 MB |

### Switching Logic (`terrain_lod_system`)

Uses hysteresis to prevent flicker at the threshold:

- **Switch to LOD 1** (zoom in): when `camera.distance < LOD_ZOOM_IN (32.0)` and currently on LOD 0
- **Switch to LOD 0** (zoom out): when `camera.distance > LOD_ZOOM_OUT (38.0)` and currently on LOD 1
- Dead zone between 32-38 prevents rapid toggling

### Lazy Loading Flow

1. Camera crosses LOD_ZOOM_IN threshold
2. `terrain_lod_system` triggers `asset_server.load("models/coastline_lod1.glb#Mesh0/Primitive0")`
3. Sets `lod1_loading = true`, stays on LOD 0
4. Next frames: polls `meshes.get(handle)` until loaded
5. When loaded: spawns hidden `UnifiedTerrain` entity with `TerrainLod(1)`
6. `split_terrain_into_chunks` detects it, splits into 48 chunks
7. `terrain_lod_system` verifies LOD 1 chunks exist, then switches visibility:
   - All `TerrainLod(0)` chunks -> `Visibility::Hidden`
   - All `TerrainLod(1)` chunks -> `Visibility::Visible`

## Territory Overlay

A separate semi-transparent mesh layer that tints territories by ownership.

### Architecture
- **Source file**: `territory_overlay.rs`
- **Built from**: Terrain surface vertices (read from chunk meshes after splitting)
- **Material**: `StandardMaterial` with `alpha_mode: AlphaMode::Blend`, `depth_bias: 2.0`, `unlit: true`
- **Y position**: Each vertex is offset `OVERLAY_Y_OFFSET (0.015)` above the corresponding terrain vertex

### Vertex Filtering

Not all terrain vertices get an overlay vertex. Excluded:
- Vertices with vertex color alpha < `MIN_SURFACE_ALPHA (0.70)` -- these are cliff faces and beach transitions
- Vertices with Y < `MIN_OVERLAY_Y (-0.05)` -- these are near/under the ocean surface
- Vertices not assigned to any country in `TerrainCountryMap`

### Chunk Structure

The overlay uses the same `CHUNK_COLS x CHUNK_ROWS` grid as the terrain for frustum culling. Each overlay chunk entity has `TerritoryOverlay` + `TerrainChunk(i)` components.

### Color Updates

`update_overlay_colors` system runs when `GameState` or `MapColorMode` changes. It iterates `OverlayVertexMap` (grid cell -> overlay chunk vertex indices) and sets RGBA vertex colors:
- Owned territory: player color with `OVERLAY_ALPHA (0.38)` alpha
- Enemy territory: `ENEMY_COLOR` (dark red) with overlay alpha
- Unowned: transparent (alpha 0)
- Draft preview / selection: highlighted colors

## Render Order (Bottom to Top)

| Layer | Y Position | Alpha Mode | Depth Bias | Description |
|-------|-----------|------------|------------|-------------|
| Ocean plane | -0.25 | Opaque | 0 | Gerstner waves, Beer-Lambert depth, foam |
| Terrain surface | 0.0+ (from heightmap) | Opaque | 0 | Satellite + cliff + beach textures |
| Cliff walls | CLIFF_BASE_Y (-0.2) to terrain height | Opaque | 0 | Vertical quads at land/ocean boundary |
| Territory overlay | terrain Y + 0.015 | Blend | 2.0 | Semi-transparent country color tint |
| Fog overlay | 0.5 | Blend | 0 | Edge fade to fog color at map borders |

### Depth and Blending Notes

- The ocean is opaque and renders first (lowest Y). Terrain and cliffs render on top via normal depth testing.
- The territory overlay uses `depth_bias: 2.0` to ensure it renders on top of terrain without z-fighting, despite being only 0.015 units above.
- The fog overlay at Y=0.5 is above all terrain and uses alpha blending to fade edges to a fog color matching the deep ocean `ClearColor`.
- `ClearColor` is set to `LinearRgba(0.04, 0.07, 0.18)` (deep ocean blue), filling any area where no mesh renders.

## Key Data Structures

| Resource/Component | File | Purpose |
|-------------------|------|---------|
| `TerrainLodMeshes` | `map.rs` | Holds mesh handles for LOD 0 and optional LOD 1 |
| `TerrainCountryMap` | `map.rs` | Per-vertex country index array (from `.bin` file) |
| `TerrainLod(usize)` | `map.rs` | Component tagging which LOD a terrain entity belongs to |
| `TerrainChunk(usize)` | `map.rs` | Component tagging chunk index after splitting |
| `UnifiedTerrain` | `components.rs` | Marker for terrain entities (both pre- and post-split) |
| `OverlayBuilt` | `territory_overlay.rs` | Tracks whether overlay has been constructed |
| `OverlayVertexMap` | `territory_overlay.rs` | Maps grid cell index to overlay chunk vertex locations |
| `TerritoryOverlay` | `territory_overlay.rs` | Marker for overlay chunk entities |

## The `beach_skip` Array

The canonical way to decide if a vertex/edge/cell should be treated as beach (no cliff walls, terrain slopes below ocean). Computed once in `generate_lod` after the taper BFS. Includes core beach vertices AND the first 2 taper rings.

**Rule**: Do NOT add new ad-hoc checks against `beach_factor` or `is_beach_zone()`. Always use `beach_skip[]`.

## Coordinate System

- **World X** = longitude (west to east, -20 to 82)
- **World Z** = negative latitude (north is negative Z: z = -lat)
- **World Y** = height (0 = sea level, positive = above, negative = below)
- **UV mapping**: Terrain UVs map to satellite texture bounds (`TEX_LON_MIN/MAX`, `TEX_LAT_MIN/MAX`)
- **Grid indexing**: `row * cols + col`, row 0 = GRID_LAT_MIN (southernmost), col 0 = GRID_LON_MIN (westernmost)
