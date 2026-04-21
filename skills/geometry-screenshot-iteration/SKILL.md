---
name: geometry-screenshot-iteration
description: Visual debugging protocol for terrain, coastline, cliff, and beach rendering. Covers screenshot capture with camera positioning, artifact identification, GLB regeneration, and the full change-compile-screenshot-assess iteration loop.
user-invocable: true
allowed-tools: Read, Grep, Bash, Edit, Write, Glob
---

# Screenshot-Driven Iteration Guide

Use this skill when debugging or developing any visual/rendering feature -- terrain meshes, cliff walls, beach slopes, ocean shaders, territory overlays, or coastal transitions. The core loop is: **change code -> check compile -> regenerate GLB -> take screenshot -> read screenshot -> assess artifacts -> repeat**.

---

## Screenshot Command

### From SSH (headless session)

The machine runs GNOME on Wayland with Xwayland. Bevy connects via Xwayland, so you must set `DISPLAY` and `XAUTHORITY`:

```bash
XAUTHORITY=$(ls /run/user/1000/.mutter-Xwaylandauth.* | head -1) DISPLAY=:0 \
  cargo run -p europe-zone-control -- --view --screenshot /path/to/output.png \
  --camera-x X --camera-z Z --camera-distance D
```

The `XAUTHORITY` path changes on reboot. Find it with: `ls /run/user/1000/.mutter-Xwaylandauth.*`

### From a local terminal (display already available)

```bash
cargo run -p europe-zone-control -- --view --screenshot /path/to/output.png \
  --camera-x X --camera-z Z --camera-distance D
```

If Vulkan fails, prefix with `WGPU_BACKEND=gl`. Do NOT use `WGPU_BACKEND=gl` for integration tests.

### Quick-start mode (for HUD/gameplay screenshots)

```bash
cargo run -p europe-zone-control -- --quick-start --screenshot /path/to/output.png
```

This skips the lobby and enters gameplay immediately. Use `--view` for map-only screenshots without UI.

---

## Coordinate System

The game world uses a geographic coordinate mapping:

| Axis | Meaning | Example |
|------|---------|---------|
| `--camera-x` | Longitude (degrees East) | `-4` = 4 degrees West (Spain) |
| `--camera-z` | Negative latitude | `-38` = 38 degrees North |
| `--camera-distance` | Zoom level (orbital distance) | `3` = very close, `40` = full map |

The conversion rule: **x = longitude, z = -latitude**. So `camera-z -36.5` means latitude 36.5 degrees North.

The camera coordinate overlay (bottom-right of screen) shows `Cam: (x, lat) d=distance` where `lat` is the positive latitude (i.e., `-z`).

### Camera limits

- Longitude clamped to `[-11, 55]`
- Latitude clamped to `[35, 72]` (so `--camera-z` range is `[-72, -35]`)
- Distance clamped to `[3.0, 55.0]`

---

## Key Locations for Testing

These coordinates target coastlines and terrain features useful for visual debugging:

| Location | `--camera-x` | `--camera-z` | `--camera-distance` | What to check |
|----------|--------------|--------------|---------------------|---------------|
| Spain south coast (Costa del Sol) | `-4` | `-36.5` | `5` | Beach slopes, cliff-to-beach transition |
| Portugal west coast | `-8` | `-37` | `5` | Cliff walls, ocean edge |
| Southern Italy | `14` | `-38` | `5` | Cliff geometry, coastal tint |
| Netherlands / Low Countries | `5` | `-53` | `8` | Flat terrain, sea level transitions |
| Normandy coast | `-1` | `-48.5` | `5` | Beach zones, channel rendering |
| Norway fjords | `7` | `-61` | `8` | Complex coastline, cliff detail |
| Scotland | `-4` | `-57` | `8` | Islands, sea crossings |
| Greece / Aegean | `24` | `-38` | `8` | Islands, multiple coastlines |
| Brittany peninsula | `-3` | `-48` | `5` | Peninsula tip, narrow land |
| Full Europe overview | `15` | `-50` | `40` | Overall map, LOD transitions |

### Multi-angle verification

For thorough checks, take 3 screenshots at each location:
1. Close-up (`distance=3-5`) -- see individual triangles, texture detail
2. Medium (`distance=8-12`) -- see transitions between zones
3. Overview (`distance=20-30`) -- see overall coastline shape, LOD behavior

---

## Artifact Identification Guide

When reading a screenshot, look for these specific artifacts:

### Geometry Artifacts

| Artifact | Visual Description | Likely Cause | Where to Fix |
|----------|--------------------|--------------|--------------|
| **Staircase/zigzag coastline** | Coastline follows a visible grid pattern with 90-degree steps | Grid resolution limit; mesh triangles aligned to lon/lat grid | Inherent at current resolution. Can soften with shader SDF or higher subdivision in `gen_cliff_glb.rs` |
| **Teeth/spikes at cliff bottom** | Sharp triangular protrusions poking through the ocean surface along cliff edges | Height mismatch between adjacent cliff vertices; mixed land/ocean cell triangles not skipped | `gen_cliff_glb.rs` -- check `BEACH_BASE_Y` vs ocean Y, check mixed-cell triangle skip logic, check `MIN_LAND_H` override on beach vertices |
| **White gaps/holes in terrain** | Missing terrain patches, ocean visible through land | `cell_in_beach_zone` or `beach_skip` skipping too many cells; terrain triangles not emitted for cells that should be land | `gen_cliff_glb.rs` -- check `beach_skip[]` array bounds, check cell skip conditions |
| **Floating geometry** | Terrain or cliff pieces visibly hovering above or detached from the surface | Wrong Y offset; `CLIFF_BASE_Y` or `BEACH_BASE_Y` not matching ocean surface | `gen_cliff_glb.rs` constants; check `CLIFF_BASE_Y`, `BEACH_BASE_Y`, ocean Y in `sea.rs` `spawn_sea` |
| **Wireframe lines visible** | Thin lines visible on terrain surface even without wireframe mode | Degenerate zero-area triangles creating hairline artifacts | `gen_cliff_glb.rs` -- check for triangles with collinear vertices or zero-area faces |
| **Ridge/bump at beach-cliff boundary** | Raised line or bump where beach zone meets cliff zone | Taper BFS not smoothing the transition; `beach_skip` boundary too sharp | `gen_cliff_glb.rs` -- check taper ring count, check `beach_factor` interpolation at boundary |

### Texture/Color Artifacts

| Artifact | Visual Description | Likely Cause | Where to Fix |
|----------|--------------------|--------------|--------------|
| **Blue bleeding on land** | Blue/ocean-colored triangles visible on land near the coast | Satellite texture misalignment at coast; coastal vertex color mask not wide enough | `gen_cliff_glb.rs` -- increase `COASTAL_MASK_CELLS`, adjust alpha values at each BFS distance ring |
| **Brown/warm band too wide** | Overly prominent brown tint band visible inland from coast | Coastal tint BFS spreading too far; alpha ramp too aggressive | `gen_cliff_glb.rs` -- reduce `COASTAL_MASK_CELLS` or adjust RGB tint values at outer rings |
| **Visible texture tiling** | Repeating grid pattern on cliff faces or terrain | Texture UV repetition without variation | Shader files (`coast_material.wgsl`, `sea_material.wgsl`) -- add tri-planar mapping or texture bombing |
| **Blue fringe at cliff tops** | Thin blue line along the top edge of cliff walls | Ocean vertices in mixed cells have pure satellite color (blue); GPU interpolates blue into cliff face | `gen_cliff_glb.rs` -- ensure ocean vertex colors match adjacent cliff colors, not default `[1,1,1,1]` |
| **Ocean shader on cliff face** | Water/wave pattern rendering on the vertical cliff surface above waterline | Ocean material incorrectly applied to cliff geometry; or cliff UVs sampling ocean shader | `sea_material.wgsl` / `coast_material.wgsl` -- check material assignment boundaries |
| **Hard binary land/water edge** | No transition zone between land texture and water; sharp color boundary | Missing beach slope, missing coastal strip mesh, or coastal alpha blending disabled | Multiple files -- check `sea.rs` coastal strip generation, `gen_cliff_glb.rs` beach factor logic |

### Border/Overlay Artifacts

| Artifact | Visual Description | Likely Cause | Where to Fix |
|----------|--------------------|--------------|--------------|
| **Nation borders crossing coast** | Dark border lines drawn over cliff faces or beach zones | Border mesh includes coastline edges | `map.rs` `make_border_mesh` -- coastline edge classification, skip coastline edges |
| **Territory overlay bleeding** | Colored territory overlay visible on ocean or cliff faces | Overlay mesh includes ocean-side or cliff vertices | `territory_overlay.rs` -- check vertex filtering |

---

## Iteration Protocol

### Full cycle (geometry changes)

1. **Edit code** in `gen_cliff_glb.rs`, `sea.rs`, `map.rs`, `heightmap.rs`, or shader files
2. **Check compilation**:
   ```bash
   cargo check -p europe-zone-control
   ```
3. **Regenerate GLB** (required for any change to `gen_cliff_glb.rs`):
   ```bash
   cd /home/user/repos/bevy && \
     ln -sf crates/europe-zone-control/assets/models models && \
     cargo run -p europe-zone-control --bin gen-cliff-glb && \
     rm models
   ```
   This regenerates `coastline_lod0.glb` and `coastline_lod1.glb` in `crates/europe-zone-control/assets/models/`. Takes 30-90 seconds.
4. **Take screenshot**:
   ```bash
   XAUTHORITY=$(ls /run/user/1000/.mutter-Xwaylandauth.* | head -1) DISPLAY=:0 \
     cargo run -p europe-zone-control -- --view --screenshot /tmp/test_output.png \
     --camera-x -4 --camera-z -36.5 --camera-distance 5
   ```
5. **Read and assess** the screenshot (Claude Code can read images directly)
6. **Repeat** from step 1 if artifacts remain

### Shader-only cycle (no GLB regeneration needed)

Shaders hot-reload on save. For rapid shader iteration:

1. **Start the game in view-only mode**:
   ```bash
   XAUTHORITY=$(ls /run/user/1000/.mutter-Xwaylandauth.* | head -1) DISPLAY=:0 \
     cargo run -p europe-zone-control -- --view
   ```
2. **Edit shader files** in `crates/europe-zone-control/assets/shaders/` -- changes appear live (wiggle mouse to trigger frame update)
3. **Press F2** to capture a timestamped screenshot to `e2e/screenshots/live_<timestamp>.png`
4. **Read the screenshot** and assess

### Code-only cycle (no GLB, no shader)

For changes to `map.rs`, `sea.rs` (non-geometry parts), `territory_overlay.rs`, or any runtime Rust code that does not affect the offline GLB:

1. **Edit code**
2. **Check compilation**: `cargo check -p europe-zone-control`
3. **Take screenshot** (step 4 from full cycle above)
4. **Assess and repeat**

---

## Keyboard Shortcuts (In-Game)

| Key | Action |
|-----|--------|
| **F2** | Save timestamped screenshot to `e2e/screenshots/live_<timestamp>.png` |
| **F3** | Toggle wireframe rendering (global) |
| **F4** | Toggle ocean/fog visibility (useful for seeing raw terrain underneath) |

Auto-screenshots are saved every 30 seconds to `e2e/screenshots/auto_<N>.jpg` (ring buffer of 10 files).

---

## GLB Regeneration Details

The offline tool `gen-cliff-glb` generates the unified terrain + cliff wall mesh:

```bash
cd /home/user/repos/bevy && \
  ln -sf crates/europe-zone-control/assets/models models && \
  cargo run -p europe-zone-control --bin gen-cliff-glb && \
  rm models
```

**Why the symlink?** The binary writes output to `models/coastline_lod0.glb` etc., but runs from the workspace root. The symlink ensures it writes into the correct assets directory.

**Output files:**
- `crates/europe-zone-control/assets/models/coastline_lod0.glb` -- high-detail mesh
- `crates/europe-zone-control/assets/models/coastline_lod1.glb` -- low-detail mesh (LOD 1)
- `crates/europe-zone-control/assets/models/coastline_map_lod0.bin` -- terrain country map (LOD 0)
- `crates/europe-zone-control/assets/models/coastline_map_lod1.bin` -- terrain country map (LOD 1)

Compressed `.gz` variants are also generated.

**When to regenerate:**
- Any change to `src/bin/gen_cliff_glb.rs`
- Any change to constants used by `gen_cliff_glb` (beach regions, cliff heights, coastal mask parameters)
- Changes to `heightmap.rs` functions called by the generator
- Changes to `countries.rs` polygon data

**When GLB regeneration is NOT needed:**
- Shader changes (hot-reload)
- Runtime Rust code changes (`map.rs` loading, `sea.rs` coastal strip, `territory_overlay.rs`)
- UI changes

---

## Constants That Must Stay in Sync

These constants interact across files. Changing one without updating the others causes visual artifacts:

| Constant | File | Current Value | Constraint |
|----------|------|---------------|------------|
| `BEACH_BASE_Y` | `gen_cliff_glb.rs` | `-0.35` | Must be BELOW ocean surface Y |
| Ocean surface Y | `sea.rs` (`spawn_sea`) | `-0.25` | Water plane height; beach must slope below this |
| `CLIFF_BASE_Y` | `gen_cliff_glb.rs` | `-0.2` | Cliff wall bottom; can be at or above ocean Y |
| `BEACH_REGIONS` | `sea.rs` | Rectangle list | Must cover actual coastline coordinates with 0.5-1.0 degree margin |
| `COASTAL_MASK_CELLS` | `gen_cliff_glb.rs` | `4` | BFS distance for coastal vertex tinting; increase if blue bleeding reappears |
| `MIN_LAND_H` | `gen_cliff_glb.rs` | `0.03` | Minimum land height; skipped for beach vertices (`beach_factor > 0.01`) |

---

## Comparison Workflow

When making before/after comparisons:

1. **Before changing code**, take a baseline screenshot:
   ```bash
   XAUTHORITY=$(ls /run/user/1000/.mutter-Xwaylandauth.* | head -1) DISPLAY=:0 \
     cargo run -p europe-zone-control -- --view --screenshot /tmp/before.png \
     --camera-x -4 --camera-z -36.5 --camera-distance 5
   ```

2. **Make changes**, regenerate GLB if needed, take a new screenshot:
   ```bash
   XAUTHORITY=$(ls /run/user/1000/.mutter-Xwaylandauth.* | head -1) DISPLAY=:0 \
     cargo run -p europe-zone-control -- --view --screenshot /tmp/after.png \
     --camera-x -4 --camera-z -36.5 --camera-distance 5
   ```

3. **Read both screenshots** to compare. Use identical camera parameters for valid comparison.

4. For pixel-level analysis, use Python/Pillow:
   ```python
   from PIL import Image
   img = Image.open("/tmp/after.png")
   crop = img.crop((x1, y1, x2, y2))
   crop = crop.resize((crop.width * 3, crop.height * 3), Image.NEAREST)
   crop.save("/tmp/zoomed.png")
   ```

---

## Reference Images

- **Good references**: `/home/user/repos/bevy/references/good-*` -- target quality for coastlines
- **Bad references**: `/home/user/repos/bevy/references/incorrect-*` -- known artifact examples
- **External references**: `/home/user/repos/bevy/references/external-good-*` -- real-world or other-game examples
- **Screenshot history**: `/home/user/repos/bevy/spain_beach_test/` -- versioned iteration history (v15 through v18+)

When assessing a screenshot, compare against the good references for the same region. The "Key Lessons" sections in `CLAUDE.md` document what went wrong in previous iterations and why.

---

## Troubleshooting

### Screenshot comes out black or fails

- Check `XAUTHORITY` path: `ls /run/user/1000/.mutter-Xwaylandauth.*` (changes on reboot)
- Check `DISPLAY` is set to `:0`
- Try `WGPU_BACKEND=gl` if Vulkan surface creation fails
- Ensure the game window is not obscured by other windows on the Xwayland display

### GLB regeneration produces no output

- Verify the symlink: `ls -la /home/user/repos/bevy/models` should point to `crates/europe-zone-control/assets/models`
- Check for compilation errors: `cargo check -p europe-zone-control --bin gen-cliff-glb`
- The binary prints progress to stderr; run without output redirection to see status

### Wireframe mode shows nothing

- F3 toggles global wireframe. If terrain is invisible, F4 may have hidden the ocean/fog layer. Press F4 again to restore.
- Wireframe requires the `WireframePlugin` which is registered in the camera plugin.

### Camera position does not match expected location

- Remember: `--camera-z` is NEGATIVE latitude. Latitude 38N = `--camera-z -38`.
- The overlay text shows `Cam: (lon, lat) d=distance` where lat is positive (already negated from z).
- Camera may clamp to bounds if the requested position is outside `[-11, 55]` longitude or `[35, 72]` latitude.
