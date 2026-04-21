---
name: geometry-coastal-transitions
description: Reference for the coastal terrain transition pipeline — beach BFS, taper, island protection, cliff generation, and triangle emission in gen_cliff_glb.rs. Invoke before modifying any beach/cliff/coastline mesh generation code.
globs:
  - crates/europe-zone-control/src/bin/gen_cliff_glb.rs
  - crates/europe-zone-control/src/sea.rs
  - crates/europe-zone-control/src/game/map.rs
  - crates/europe-zone-control/src/game/territory_overlay.rs
---

# Coastal Transition Rules

This skill documents the full pipeline that transforms raw heightmap terrain into beach slopes, cliff walls, and triangle emission decisions. Every system described here lives in `gen_cliff_glb.rs` unless noted otherwise.

## Pipeline Overview (execution order)

```
BEACH_REGIONS (sea.rs)
       |
       v
  Beach BFS         -- find ocean-adjacent land in rectangles, propagate dist_to_ocean
       |
       v
  Taper BFS         -- extend beach_factor beyond rectangle edges (6 cells)
       |
       v
  beach_skip[]      -- boolean: core beach + first 2 taper rings
       |
       v
  Island Protection -- flood-fill connected components, exempt small islands
       |
       v
  Laplacian Smooth  -- smooth beach_factor (6 passes at LOD0) to remove staircase
       |
       v
  Beach Slope       -- lower heights toward BEACH_BASE_Y using smoothstep(beach_factor)
       |
       v
  Coastal Dist BFS  -- separate BFS for ALL coastlines (not just beach), controls vertex color mask
       |
       v
  Vertex Emission   -- positions, UVs, vertex colors for terrain surface
       |
       v
  Triangle Emission -- cell_in_beach_zone skips mixed cells; needs_subdiv adds center fans
       |
       v
  Cliff Emission    -- get_cliff computes top/bot; is_beach_vertex skips beach edges
```

## Critical Constants

| Constant | Value | Location | Purpose |
|---|---|---|---|
| `CLIFF_BASE_Y` | -0.2 | gen_cliff_glb.rs:30 | Bottom of cliff walls |
| `BEACH_BASE_Y` | -0.35 | gen_cliff_glb.rs:33 | Height at ocean-edge beach vertices (below ocean surface) |
| `MIN_LAND_H` | 0.03 | gen_cliff_glb.rs:35 | Minimum cliff-top height for non-beach land |
| `BEACH_TAPER_CELLS_BASE` | 6 | gen_cliff_glb.rs:39 | Taper rings beyond rectangle edge (scaled by lod_scale) |
| `beach_slope_cells` | 16 * lod_scale | gen_cliff_glb.rs:200 | Max BFS propagation distance for beach slope |
| `BEACH_SKIP_TAPER_RINGS` | 2 | gen_cliff_glb.rs:404 | How many taper rings are included in beach_skip |
| `MIN_SURVIVAL_RATIO` | 0.9 | gen_cliff_glb.rs:440 | Island protection threshold (90% cells must survive) |
| `COASTAL_MASK_CELLS` | 4 * lod_scale | gen_cliff_glb.rs:646 | Vertex color mask BFS depth (blue-bleeding fix) |
| Ocean surface Y | -0.25 | sea.rs spawn_sea | Water plane height |

**Sync rules:**
- `BEACH_BASE_Y` (-0.35) MUST be below ocean surface Y (-0.25)
- `CLIFF_BASE_Y` (-0.2) is at or above ocean Y -- cliff walls are always backed by ocean
- If ocean Y changes, both `BEACH_BASE_Y` and `CLIFF_BASE_Y` must be re-evaluated

## BEACH_REGIONS (sea.rs)

12 axis-aligned rectangles defining where beaches exist, as `(lon_min, lon_max, lat_min, lat_max)` tuples in geographic coordinates:

| Region | lon_min | lon_max | lat_min | lat_max |
|---|---|---|---|---|
| Netherlands/Frisian Islands | 3.5 | 7.0 | 52.5 | 53.8 |
| Algarve, Portugal | -9.5 | -7.0 | 36.5 | 37.5 |
| Landes/Aquitaine, France | -1.5 | -0.8 | 43.5 | 45.5 |
| Rimini/Romagna, Italy | 12.2 | 13.0 | 43.8 | 44.5 |
| Costa del Sol, Spain | -6.5 | -2.5 | 35.8 | 37.2 |
| Normandy/Brittany, France | -2.0 | 0.0 | 48.3 | 49.0 |
| Danish west coast | 7.5 | 8.5 | 55.0 | 57.5 |
| Baltic south (Poland/Germany) | 13.0 | 19.0 | 54.0 | 55.0 |
| Sardinia east coast | 9.0 | 9.7 | 39.0 | 41.0 |
| Tunisian coast | 9.0 | 11.0 | 33.5 | 37.5 |
| Eastern Spain (Valencia) | -0.5 | 0.5 | 38.5 | 40.0 |
| Greek islands / Aegean | 23.0 | 26.0 | 35.0 | 38.0 |

`is_beach_zone(lon, lat)` returns true if the point is inside any rectangle.

**Rule:** Rectangles must cover the ACTUAL coastline geometry in the heightmap grid, not just the named region. Add 0.5-1.0 degree margin. The polygon-based coastline may sit at slightly different coordinates than expected.

## Beach BFS (lines 190-272)

**Purpose:** Compute `dist_to_ocean` and `beach_factor` for land vertices inside beach rectangles.

**Algorithm:**
1. Seed: all land vertices where `is_beach_zone(lon, lat)` is true AND at least one 4-neighbor is ocean. These get `dist_to_ocean = 0`.
2. BFS propagates to land neighbors inside the beach rectangle, up to `beach_slope_cells` (16 at LOD0, 32 at LOD1).
3. BFS only crosses into neighbors where `is_land(n)` and `is_beach_zone(nlon, nlat)`.
4. `beach_factor[idx] = 1.0 - (dist_to_ocean / beach_slope_cells)` -- 1.0 at ocean edge, 0.0 at max depth.

**Key constraint:** BFS is confined to vertices inside BEACH_REGIONS rectangles. Vertices outside get `dist_to_ocean = usize::MAX` and `beach_factor = 0.0`.

## Taper System (lines 279-414)

**Purpose:** Extend `beach_factor` beyond the rectangle boundary so beach-to-cliff transition is gradual.

**Algorithm:**
1. Seed: land vertices OUTSIDE the beach rectangle that neighbor a vertex with `dist_to_ocean < beach_slope_cells` (i.e., at the rectangle boundary).
2. BFS propagates outward up to `BEACH_TAPER_CELLS_BASE` (6) cells, staying outside the rectangle and on land.
3. For each taper vertex, `beach_factor = max_neighbor_bf * (1.0 - taper_dist / beach_taper_cells)`. Processed in order of increasing distance so closer vertices are set first.

**beach_skip computation (lines 396-413):**
After taper, `beach_skip[idx]` is set to true for:
- Core beach vertices: `dist_to_ocean < beach_slope_cells`
- First 2 taper rings: `taper_dist <= BEACH_SKIP_TAPER_RINGS` (2)

Only 2 rings are included -- extending to all 6 taper rings removed geometry that was not actually submerged, creating visible holes.

## Island Protection (lines 416-575)

**Purpose:** Prevent beach_skip from destroying small islands where most cells are "mixed" (land + ocean corners).

**Algorithm:**
1. **Connected-component flood fill** on ALL land vertices (4-connected). Each land mass gets a unique `island_id`.
2. **Cell survival count:** For each island, count total cells (any land corner) and surviving cells (all-land cells, or mixed cells where NO corner has `beach_skip`).
3. **Ratio check:** If `surviving / total < MIN_SURVIVAL_RATIO` (0.9), the island is exempt.
4. **Exemption:** Clear `beach_skip`, `beach_factor`, and `dist_to_ocean` for all vertices on exempt islands.

**Why 90%:** Continental coastlines have >99% interior cells. Islands like Crete at LOD0 have ~67% interior cells (82% at LOD1) and would lose too much geometry without protection.

## Laplacian Smoothing (lines 577-624)

**Purpose:** Remove staircase artifacts from grid-aligned land/ocean boundary in the beach_factor field.

**Rules:**
- Only smooth vertices INSIDE the BFS beach zone (`0 < dist < beach_slope_cells`)
- Pin ocean-edge vertices (`dist == 0`) at `beach_factor = 1.0`
- Average only includes neighbors also in the beach zone (prevents inland bf=0 vertices from pulling contour inward)
- 6 passes at LOD0, 12 at LOD1 (scaled by `lod_scale`)
- Blend: `buf[idx] = buf[idx] * 0.5 + avg * 0.5`

## Beach Slope Application (lines 627-637)

Applies the smoothed `beach_factor` to actual vertex heights:
```
smooth_t = t * t * (3.0 - 2.0 * t)   // smoothstep
heights[idx] = heights[idx] * (1.0 - smooth_t) + BEACH_BASE_Y * smooth_t
```
At `beach_factor = 1.0` (ocean edge): height = `BEACH_BASE_Y` (-0.35), well below ocean surface (-0.25).
At `beach_factor = 0.0` (inland edge): height = original heightmap value.

## Ocean Vertex Height (lines ~740-776)

Ocean vertices adjacent to beach land vertices get special height treatment:
- If any land neighbor has `beach_factor > 0.01`, set ocean vertex height to the minimum of neighboring beach heights (clamped to `BEACH_BASE_Y`)
- This continues the beach slope smoothly underwater instead of having a height discontinuity at the land-ocean boundary
- Non-beach ocean vertices use `h.min(0.0)` (at or below sea level)

## cell_in_beach_zone (lines 847-860)

**Purpose:** Decide whether to skip a terrain cell during triangle emission.

**Logic:** A cell (4 grid corners: tl, tr, bl, br) is skipped if:
1. It is "mixed" -- has both land and ocean corners (not all-land, not all-ocean)
2. ANY corner has `beach_skip[c] == true`

**Why:** In beach zones, cliff walls are removed. Mixed cells span from high land to low ocean. Without cliff walls hiding them, these triangles poke through the water surface as visible spikes. Skipping them lets the ocean plane cover the gap.

All-land and all-ocean cells are NEVER skipped by this check.

## Center-Fan Subdivision (lines 862-914)

Cells where any corner has `beach_factor > 0` or `coastal_dist < coastal_mask_cells` get subdivided into 4 triangles (center vertex + 4 fan triangles) instead of the standard 2-triangle split. This provides smoother interpolation of the beach slope and vertex color mask without creating T-junction cracks at cell boundaries.

## is_beach_vertex (lines 1109-1130)

**Purpose:** Decide whether to skip a cliff wall edge.

**Logic:** Returns true if:
- `beach_skip[grid_idx]` is true (land vertex in beach zone), OR
- The vertex is ocean AND any 4-neighbor is a land vertex with `beach_skip`

**Usage:** If EITHER endpoint of a cliff edge is a beach vertex, the entire cliff edge is skipped. This removes cliff walls at the full beach boundary -- both the land side and the ocean side.

## get_cliff (lines 1006-1073)

**Purpose:** Compute or cache the cliff top and bottom vertex pair for a grid vertex.

**Top height:**
- Land vertices: `heights[grid_idx].max(MIN_LAND_H)` -- always at least 0.03 even on flat coasts
- Ocean vertices: `heights[grid_idx].min(0.0)`

**Bottom height:** Always `CLIFF_BASE_Y` (-0.2).

**Degenerate cliff detection:** If `top_y <= bot_y + 0.08` (terrain is within 0.08 of cliff base), the cliff is too short to render. Returns `(u32::MAX, u32::MAX)` sentinel. `emit_cliff_edge` detects this and skips the edge.

**Cliff vertex colors:**
- Top: `[0.45, 0.32, 0.22, 0.35]` -- warm orange-brown rock, alpha=0.35
- Bottom: `[0.28, 0.22, 0.16, 0.35]` -- darker shadow rock, alpha=0.35
- Alpha=0.35 in the terrain shader's `smoothstep(0.85, 0.45, alpha)` produces strong cliff texture blend

## Consequences Table -- What Breaks When You Change Each System

| System | If you change it... | What breaks |
|---|---|---|
| **BEACH_REGIONS** rectangles | Expand too much | Beach slope applied to non-beach coastlines; small islands may lose geometry |
| **BEACH_REGIONS** rectangles | Shrink or remove | Hard cliff-to-ocean edge appears where beach was expected |
| **BEACH_REGIONS** rectangles | Don't cover actual coastline | Cliff walls emitted at real coast despite being "inside" the named region |
| **beach_slope_cells** | Increase | Beach slope extends further inland, more terrain lowered below ocean; may need wider taper |
| **beach_slope_cells** | Decrease | Steeper beach slope, may cause visible staircase at boundary |
| **BEACH_TAPER_CELLS_BASE** | Increase | Softer beach-to-cliff transition but may remove cliff geometry too aggressively |
| **BEACH_TAPER_CELLS_BASE** | Decrease | Harder cutoff at rectangle boundary, visible gap between beach slope and cliff wall |
| **BEACH_SKIP_TAPER_RINGS** | Increase past 2 | Too much geometry removed at rectangle edges, creating white gaps/holes |
| **BEACH_SKIP_TAPER_RINGS** | Decrease to 0 | Cliff walls appear at the rectangle boundary, creating a visible seam |
| **MIN_SURVIVAL_RATIO** | Lower (e.g., 0.5) | Small islands like Crete get beach treatment, losing visible geometry |
| **MIN_SURVIVAL_RATIO** | Raise (e.g., 0.99) | Even large islands exempt from beach, losing sandy coastlines |
| **BEACH_BASE_Y** | Raise above ocean Y (-0.25) | Beach-edge terrain pokes above water as visible spikes/teeth |
| **BEACH_BASE_Y** | Lower much further | Beach slope becomes very steep; underwater terrain visible through shallow water shader |
| **CLIFF_BASE_Y** | Lower | Taller cliff walls, more geometry, cliff walls extend deeper underwater |
| **CLIFF_BASE_Y** | Raise above terrain tops | Degenerate cliffs everywhere (top <= bot + 0.08), all cliffs disappear |
| **MIN_LAND_H** | Increase | Visible ridges at beach/cliff boundary where sloped beach heights get forced up |
| **MIN_LAND_H** | Decrease to 0 | Very flat coasts have no visible cliff edge; terrain blends into ocean |
| **Laplacian smooth passes** | Increase | Beach_factor field over-smoothed, loses variation; slow at high LOD |
| **Laplacian smooth passes** | Decrease or remove | Staircase artifacts in beach slope follow grid-aligned land/ocean boundary |
| **cell_in_beach_zone** | Remove the skip | Spike triangles poke through ocean in every beach zone |
| **cell_in_beach_zone** | Make it skip all-land cells too | Visible holes in terrain behind beach zones |
| **is_beach_vertex** | Remove cliff edge skipping | Cliff walls appear inside beach zones, overlapping the beach slope |
| **is_beach_vertex** | Remove ocean-neighbor check | Cliff walls partially remain at beach-ocean boundary (one side skipped, other not) |
| **get_cliff degenerate threshold** (0.08) | Increase | More cliff edges skipped, gaps appear where short cliffs should be |
| **get_cliff degenerate threshold** (0.08) | Decrease to 0 | Stubby cliff teeth at beach-cliff boundary |
| **Island protection** | Remove entirely | Small islands in beach zones disappear (all geometry skipped) |

## Interaction Diagram

```
sea.rs::BEACH_REGIONS
    |
    |  is_beach_zone(lon,lat)
    v
Beach BFS -----> dist_to_ocean[] -----> beach_factor[]
    |                                        |
    |                                        v
    |                                  Laplacian Smooth
    |                                        |
    |                                        v
    |                                  Beach Slope (heights[])
    |                                        |
    +----> Taper BFS ---+                    |
                        |                    |
                        v                    |
                  beach_skip[] <-------- (core beach from dist_to_ocean)
                        |
            +-----------+-----------+
            |           |           |
            v           v           v
    Island        cell_in_beach   is_beach_vertex
    Protection    _zone closure   closure
            |           |           |
            v           v           v
    Clears       Skips mixed    Skips cliff
    beach_skip   terrain cells  wall edges
    for exempt
    islands

Coastal Dist BFS (independent, all coastlines)
    |
    v
vertex_colors[] ----> terrain shader (blue-bleeding mask)
    |
    v
needs_subdiv ----> center-fan subdivision for smooth beach cells
```

## Three-Layer Coastline Architecture

The coastline rendering involves THREE overlapping geometry layers:

1. **Terrain surface mesh** -- grid of triangles, some land, some ocean, heights from heightmap + beach slope
2. **Cliff wall mesh** -- vertical quads extruded downward from boundary edges (land-to-ocean transitions)
3. **Ocean surface mesh** -- flat plane at y=-0.25 with wave shader

**Non-beach coastlines:** Layer 2 (cliff walls) hides the ugly boundary between layers 1 and 3. The cliff is a vertical wall from terrain height down to -0.2.

**Beach coastlines:** Layer 2 is removed via `is_beach_vertex`. Layer 1 must slope smoothly BELOW layer 3 so the ocean covers the transition. Any terrain triangle that pokes above y=-0.25 will be visible as a spike.

**Critical invariant:** Removing cliff walls from a coastline section ALWAYS exposes the raw terrain triangles underneath. You MUST also handle the terrain triangles (skip mixed cells via `cell_in_beach_zone`, or ensure all vertices in those cells are below the ocean surface).

## File Locations

- Beach regions and `is_beach_zone`: `crates/europe-zone-control/src/sea.rs`
- All mesh generation: `crates/europe-zone-control/src/bin/gen_cliff_glb.rs`
- Grid constants (GRID_LAT/LON_MIN/MAX): `crates/europe-zone-control/src/game/map.rs`
- Ocean surface spawn: `crates/europe-zone-control/src/sea.rs` (spawn_sea function)

---

## Coastal/Beach/Cliff Rendering Reference Analysis

Reference images are in `/home/user/repos/bevy/references/` (good-*, incorrect-*, external-good-*).
Screenshot history is in `/home/user/repos/bevy/spain_beach_test/` (v15_baseline, v15_fix1, v16, v16_debug, v17_before, v17_after, v18).

### What Makes "Good" Coasts (from reference images)

1. **Multi-zone gradual transition** — Land never meets water at a single hard edge. There are always multiple color/material zones: vegetation -> exposed terrain -> dry sand -> wet sand -> shallow water (seabed visible) -> deeper water. Minimum 3 zones, ideally 4-5.
2. **Organic, irregular edges** — The boundary between each zone is irregular and follows natural contours. No straight lines, no geometric stair-stepping, no triangle-mesh artifacts visible.
3. **Seabed visibility through shallow water** — In "good" beach references, you can see the sandy/rocky bottom through clear shallow water. The water TINTS the ground beneath it rather than replacing it with a solid water color. This is the single most important quality marker.
4. **Warm, natural color palette** — Sand is tan/beige/warm-brown (not orange or red-brown). Shallow water is turquoise/cyan. Deep water is rich blue. Smooth color gradient, not discrete color bands.
5. **Foam/surf line** — White foam or surf at the waterline, creating a natural separator that adds depth and realism.
6. **Cliff texture quality** — Sedimentary strata banding visible but not tiling. Texture looks like natural layered rock with subtle wavy horizontal lines. No grid seams. No repetition artifacts.
7. **Consistent width variation** — Beach/transition zone varies in width naturally along the coast — wider in coves, narrower on headlands. Never a constant-width strip.

### What Makes "Incorrect" Coasts (from reference images)

1. **Hard binary edge between land and water** — The most prominent defect. Land material and water material meet at a single geometric edge with zero blending, zero transition zone, and zero intermediate colors.
2. **Stair-step / pixelated edges** — The coastline boundary follows mesh triangle edges, creating a visible zigzag or staircase pattern. This is the hallmark "incorrect coast" look.
3. **Missing beach/sand zone** — No intermediate sand or beach strip between land terrain and water surface.
4. **Visible texture tiling** — Rock/cliff textures show obvious grid-pattern repeat seams, visible as dark grid lines or periodic pattern repetition.
5. **Overly bright/prominent caustics** — Sea surface near coast has overly bright, large-scale caustic patterns that look unrealistic, especially right at the shoreline.
6. **Flat, featureless materials** — Land surface near coast is a flat, uniform brown/green with no texture detail or variation. No wet-sand darkening, no debris, no rock detail.
7. **Nation borders crossing coast zones** — Game borders/lines drawn directly over the coastal transition area, breaking the visual illusion.

### Specific Artifact Table

| Artifact | Description | Seen In |
|---|---|---|
| Stair-stepping | Zigzag/staircase coastline following mesh triangles | incorrect-beach1, incorrectbeach2 |
| Binary land/water edge | Land and water textures butt against each other with no blend | incorrect-beach1, incorrectbeach2 |
| Texture tile grid | Visible rectangular grid from texture repetition on cliffs | incorrect-beach4 |
| Texture bleeding | Ocean shader rendering on cliff face above waterline | ocean-texture-top-of-cliff |
| Missing transition zones | No sand, no wet-sand, no shallow-water zone | incorrect-beach1, incorrectbeach2 |
| Diagonal strata striping | Cliff rock texture with overly prominent/unnatural diagonal lines | incorrect-beach5 |
| Blurry/pixelated terrain | Terrain near coast is an undefined low-res blur | incorrect-beach3 |

### Rules for Correct Rendering (DO NOT VIOLATE)

1. **Always have a multi-zone transition.** From inland to deep water: terrain -> beach/sand -> shallow water -> deep water. Each zone blends into the next.
2. **Never allow hard geometric edges.** Mesh triangle boundaries must never be visible at the coast. Use distance-field, SDF, or alpha-blending to soften the land-water boundary.
3. **Shallow water must show the seabed.** Water opacity increases with depth. Near shore = mostly ground color tinted blue/cyan. Far from shore = solid water color.
4. **Add a foam/surf line at the waterline.** Subtle white or light-colored line at the water's edge. Can be procedural (noise-based).
5. **Beach/sand strip must vary in width.** Use noise or geography data. Coves = wider beach. Headlands = narrow or no beach. Never a constant-width ribbon.
6. **Cliff textures must not tile visibly.** Use texture bombing, tri-planar mapping, or large-scale variation overlays to break up tiling.
7. **Ocean/sea shaders must not bleed onto land.** Sea material must only render below the waterline.
8. **Natural color palette.** Sand = warm tan/beige (not orange). Shallow water = turquoise/cyan. Deep water = medium-to-dark blue. Cliff rock = warm brown with subtle strata.
9. **Nation borders must not cross beach/coast zones.** Stop at inland edge of coastal transition, or render beneath coast materials.
10. **Caustics should be subtle near shore.** Reduce or eliminate bright caustic patterns in very shallow water.

### Key Lessons From Failed v18 Attempt

The v18 attempt applied aggressive Laplacian smoothing (40 passes) to terrain vertices near the coast, which:
- **Moved vertices in XZ** which shifted their world position relative to the satellite texture, causing the terrain to sample wrong parts of the texture (even with UV recalculation, the satellite imagery no longer aligned with geographic features)
- **Made the coastline look blurred/melted** rather than organically smooth — Laplacian smoothing rounds everything into circles, which is not how real coastlines look
- **Destroyed the existing beach/cliff texture work** by moving vertices out of alignment with the carefully-tuned vertex color zones

**Lesson: Do NOT smooth terrain surface vertices in XZ.** The terrain grid positions must remain locked to their geographic lon/lat coordinates. Coastline smoothness must be achieved through:
- Shader-based edge softening (alpha blending, SDF techniques)
- Higher mesh resolution at coastlines (subdivide boundary edges only)
- Cliff wall geometry that covers stepping (outward offset of cliff walls only, not terrain surface)
- Anti-aliasing in the coast/ocean shader where it samples depth/distance

### Key Lessons From Beach Ridge/Spike Fix (v19)

**The Problem:** Bright white/brown raised ridges and triangular spikes along the coastline in beach zones. The terrain was supposed to slope smoothly down to sea level, but instead there were visible walls, bumps, and jagged teeth at the coast boundary.

**Root Causes (FIVE interacting issues):**

1. **`MIN_LAND_H` override on beach vertices:** The `get_cliff` function forced `heights[grid_idx].max(MIN_LAND_H)` where `MIN_LAND_H = 0.03` for ALL land vertices. Beach-zone vertices whose heights had been sloped below 0.03 by the beach pass were forced back UP to 0.03, creating bumps at cliff tops.
   - **Fix:** Skip `MIN_LAND_H` for vertices with `beach_factor > 0.01`.

2. **Ocean vertex height mismatch:** Ocean vertices adjacent to beaches used `h.min(0.0)` = 0.0, while beach land vertices at the ocean edge were sloped to `BEACH_BASE_Y` (-0.35). The ocean side was HIGHER than the beach side, creating inverted slopes.
   - **Fix:** For ocean vertices with any beach-factor land neighbor, set height to the minimum of neighboring beach heights (clamped to `BEACH_BASE_Y`).

3. **`BEACH_REGIONS` rectangles didn't cover actual coastlines:** The Costa del Sol beach zone was defined too small. Cliff walls were emitted at the real coast because vertices fell outside the rectangle.
   - **Fix:** Expanded rectangles with 0.5-1.0 degree margin.

4. **`BEACH_BASE_Y` was above the ocean surface:** Beach terrain sat ABOVE the ocean surface, making all beach-edge triangles visible.
   - **Fix:** Lowered `BEACH_BASE_Y` to -0.35, well below ocean at -0.25.

5. **Mixed land/ocean cells in beach zones created visible spike triangles:** Removing cliff walls exposed raw terrain triangles in mixed cells.
   - **Fix:** Skip emitting terrain triangles for mixed land/ocean cells where any vertex has `beach_factor > 0`.

6. **Country border outlines overlaid on coastlines:** Soft-edged triangle-strip borders drawn over coastline edges.
   - **Fix:** `make_border_mesh` classifies coastline vs interior edges, skips coastline ones.

**The Layered Nature of the Bug:** This was 5-6 interacting issues. Fixing any single one in isolation did not visibly improve the result because the remaining issues masked the fix.

### Key Lessons From Beach/Cliff Boundary Gap Investigation

**The Problem:** Visible gaps at edges of `BEACH_REGIONS` rectangles where beach transitions to cliff.

**What Was Tried (v5 through v6e):**

1. **Taper BFS (KEPT):** Extended `beach_factor` 6 cells beyond rectangle edges.
2. **`beach_skip` array (KEPT):** Precomputed boolean including core beach + first 2 taper rings.
3. **Cliff base extension near beach (KEPT):** Cliff walls adjacent to beach zones extend to `BEACH_BASE_Y` instead of `CLIFF_BASE_Y`.
4. **AND condition for cliff skip (REVERTED):** Caused spike/needle artifacts.
5. **ALL-land-beach condition for cell skip (REVERTED):** Didn't fix the gap.
6. **Removing cell_in_beach_zone skip entirely (REVERTED):** Caused massive spikes.

**Architecture Lesson:** The `beach_skip` array is the canonical source of truth. Do not add new ad-hoc checks against `beach_factor` or `is_beach_zone()` — use `beach_skip[]` instead.

### Key Lessons From Blue Satellite Texture Bleeding Fix

**The Problem:** Blue triangles visible on terrain near ALL coastlines. The satellite texture contains ocean-colored pixels at the coastline, and the polygon-based land/ocean classification doesn't perfectly align.

**The Fix — Coastal Distance BFS + Graduated Vertex Color:**

BFS from ALL ocean-adjacent land vertices propagates distance inland up to `COASTAL_MASK_CELLS = 4` cells. Each ring gets progressively weaker warm tint and higher alpha:

| Distance | RGB Tint | Alpha | Cliff Blend % | Purpose |
|---|---|---|---|---|
| 0 (coast edge) | (0.72, 0.62, 0.48) | 0.45 | ~88% cliff | Strong mask, hides all blue |
| 1 | (0.82, 0.74, 0.60) | 0.60 | ~56% cliff | Moderate transition |
| 2 | (0.92, 0.87, 0.78) | 0.78 | ~12% cliff | Mild tint, mostly satellite |
| 3 | (0.97, 0.95, 0.90) | 0.92 | ~0% cliff | Subtle warm tint only |
| 4+ | (1.0, 1.0, 1.0) | 1.0 | 0% cliff | Pure satellite texture |

**Prevention Rules:**
1. `COASTAL_MASK_CELLS` should be increased if blue triangles reappear at higher mesh resolutions.
2. Alpha values must be chosen relative to the terrain shader's `smoothstep` thresholds.
3. This coastal mask is INDEPENDENT of the beach system — applies to ALL coastlines.

### Key Lessons From Ocean Vertex Color Fix (Blue Teeth at Cliff Tops)

**The Problem:** Blue "teeth" at cliff tops — thin blue fringes along cliff-to-ocean edge.

**Root Cause:** Ocean vertices in mixed land/ocean cell triangles kept `[1.0, 1.0, 1.0, 1.0]` (pure satellite = blue). GPU interpolation between cliff-textured land vertex and blue ocean vertex creates visible fringe.

**The Fix:** Give ocean vertices cliff-like or beach colors instead of pure satellite:
- **Non-beach ocean vertex:** `[0.72, 0.62, 0.48, 0.45]` — matches cliff-top land vertices
- **Beach-zone ocean vertex:** Beach colors with aggressive alpha ramp

**Prevention Rules:**
1. ALL vertex color assignments must handle ocean vertices explicitly — never leave at `[1.0, 1.0, 1.0, 1.0]` default.
2. Ocean vertex colors should match nearest land vertex style (cliff or beach).
3. This fix interacts with cliff wall geometry — cliff walls hide most mixed-cell triangles, but not all.
