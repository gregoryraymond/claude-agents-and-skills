---
name: shader-debugging
description: Dedicated guide for debugging WGSL shaders in this Bevy 0.15 / wgpu project — figuring out what math inside a fragment or vertex shader is producing wrong output. Covers visualize-as-color bisection, storage-buffer printf, RenderDoc shader stepping, WGSL semantic traps, and opinionated tooling recommendations. Use when a shader compiles and runs but produces wrong colors, NaN pixels, seams, broken lighting, wrong depth, or vertex displacement bugs. For texture-loading / sRGB / glTF-import problems, use `texture-debugging` instead.
user-invocable: true
allowed-tools: Read, Grep, Bash, Edit, Write, Agent, WebSearch, WebFetch
---

# Shader Debugging Guide

Complement to `wgsl-shaders` (technique database for writing shaders) and `texture-debugging` (texture/material asset pipeline). This skill is about the inner loop of **"why is the math inside this shader wrong"**.

Assume the shader compiles, the right textures arrive, and pixels reach the screen — they're just wrong pixels.

## §1 — Visualize intermediate values as color (first move, always)

Single highest-leverage technique. Temporarily replace the fragment output with the quantity you suspect, remapped into `[0,1]^3`.

| Quantity | Display | Reads as |
|---|---|---|
| Unsigned float `v ∈ [0,1]` | `return vec4(v, 0.0, 0.0, 1.0);` | Red brightness = magnitude |
| Signed float | `return vec4(v * 0.5 + 0.5, 1.0);` | Gray = 0, red = negative axis, green = positive |
| `vec2` UV | `return vec4(uv, 0.0, 1.0);` | Smooth red-green gradient; discontinuities = bug |
| World-space normal | `return vec4(normalize(n) * 0.5 + 0.5, 1.0);` | Pastel tie-dye on a sphere; flat color = broken TBN |
| Depth / distance | `return vec4(vec3(linear_depth / max_range), 1.0);` | Greyscale. **Linearize first** — raw `ndc_z` is hyperbolic and unreadable |
| Boolean / mask | `return vec4(f32(cond), 0.0, 0.0, 1.0);` | White = true |
| Derivatives | `return vec4(abs(dpdx(x)), abs(dpdy(x)), 0.0, 1.0);` | Flat black = you're on a quad edge or post-discard |
| NaN hunt | `return vec4(select(vec3(0.0), vec3(1.0, 0.0, 1.0), v != v), 1.0);` | Magenta pixels = NaN |

**A/B bisection via early `return`.** Put `return vec4(diag, 1.0);` at a point in the pipeline, move it up/down a few lines at a time until the output flips correct → wrong. That's your bug. This is `git bisect` for shaders — much faster than any printf.

**Bevy hot-reload loop.** Edit `.wgsl` under `assets/shaders/`, save; Bevy's asset server reloads. Wiggle the mouse to force a redraw (this project's `WinitSettings::Reactive` needs an event). Keep the window visible next to the editor. F2 saves a timestamped screenshot to `e2e/screenshots/live_*.png`; the 30-second auto-screenshot ring (`auto_0..auto_9.png`) is a free state-diff history.

## §2 — Printf-style WGSL via storage-buffer cursor probe

WGSL has no stdout. The canonical workaround: a storage buffer writable from the fragment shader, with a cursor-pixel uniform that gates writes so only the clicked pixel logs anything.

```wgsl
struct DebugRecord { pixel: vec2<u32>, tag: u32, value: vec4<f32> };

@group(3) @binding(0) var<storage, read_write> dbg: array<DebugRecord, 64>;
@group(3) @binding(1) var<storage, read_write> dbg_next: atomic<u32>;
@group(3) @binding(2) var<uniform> cursor: vec2<u32>;

fn dbg_log(tag: u32, v: vec4<f32>, frag: vec4<f32>) {
    if (u32(frag.x) == cursor.x && u32(frag.y) == cursor.y) {
        let i = atomicAdd(&dbg_next, 1u);
        if (i < 64u) {
            dbg[i] = DebugRecord(vec2<u32>(u32(frag.x), u32(frag.y)), tag, v);
        }
    }
}
```

Map-read the buffer from the CPU after `queue.submit`. One click = a call-stack trace for one fragment. The gate keeps cost negligible even at 4K.

**Existing libraries to know:**
- `looran/wgsl-debug` (https://github.com/looran/wgsl-debug) — TypeScript/browser automated inject/readback. Not directly usable from wgpu but the pattern transfers verbatim.
- W3C `shaderLog` proposal (https://github.com/gpuweb/gpuweb/issues/4704) — not shipped.
- No Bevy crate currently wraps this — if you need it, build a `Plugin` that attaches a storage-buffer bind group to an `ExtendedMaterial` and a system that reads back each frame. Gate behind `shader_defs: DEBUG_LOG` so release builds never allocate.

Vertex-stage logging: vertex shaders can't `read_write` storage buffers in wgpu (current spec). Route logs to a compute pre-pass indexed by `@builtin(vertex_index)`.

See `planning/pixel_picker_investigation.md §7.3` for a longer treatment of this pattern tied to the pixel-picker work.

## §3 — RenderDoc shader debugger (step-through)

Right-click a pixel → **Debug Pixel** — RenderDoc rebuilds the fragment shader with real bound inputs and lets you step line-by-line with locals visible. For vertex debug, use the Mesh Viewer → right-click vertex → **Debug Vertex**.

**Critical limits for wgpu/WGSL:**
- Shader debugger supports **D3D11, D3D12, Vulkan SPIR-V only**. Metal, GLES, WebGL are not supported. On Linux **switch to Vulkan before capturing**: `WGPU_BACKEND=vulkan`. Our project's `WGPU_BACKEND=gl` fallback (for surface format issues) disables the shader debugger.
- WGSL source is not the stepping target — naga translates WGSL → SPIR-V before Vulkan sees it. RenderDoc shows the SPIR-V. Readable, but cross-reference against your WGSL by structure.
- wgpu's WGSL→SPIR-V debug info (OpDebugSource / OpLine) is not yet emitted in release (https://github.com/gfx-rs/wgpu/issues/3896). When it lands you'll see line numbers; until then, use variable names (naga preserves them).
- Naga may inline/rename aggressively — step-into occasionally lands "nowhere". Look at the disassembly to orient.
- On AMD RADV (this project's GPU) use the latest Mesa; older RADV versions crash RenderDoc's pixel-debug.

Install path for Ubuntu 24.04 and Python-driven headless pixel-history analysis are in `texture-debugging §8`.

## §4 — Isolation / bisection methodology

When a frame is wrong, peel the pipeline back one stage at a time via early `return`. Order I recommend:

1. `return vec4(raw_albedo, 1.0);` — skip all lighting.
2. `return vec4(normalize(N) * 0.5 + 0.5, 1.0);` — check surface normal.
3. `return vec4(normalize(V) * 0.5 + 0.5, 1.0);` — view vector.
4. `return vec4(normalize(L) * 0.5 + 0.5, 1.0);` — light vector for a fixed light.
5. `return vec4(vec3(max(dot(N, L), 0.0)), 1.0);` — Lambertian term.
6. `return vec4(diffuse_only, 1.0);` — diffuse, no specular.
7. Add shadow term; visualize the shadow mask directly.
8. Add fog.
9. Add post-process.

Wrap each diagnostic in `#ifdef DEBUG_STAGE_N` rather than hand-deleting, so you can toggle between them without re-typing. `git stash` the diagnostic patch when done.

## §5 — Vertex-shader-specific debugging

Vertex shaders return clip-space position + varyings — can't "return a color" directly.

- **Smuggle as a varying.** Add `@location(7) debug: vec4<f32>` on the vertex output. Fill with whatever you want to inspect. Display in fragment behind `#ifdef DEBUG`. For raw per-vertex values (not interpolated), use `@interpolate(flat)`.
- **Shrink-display clip-space.** `out.position = vec4(vertex.xy * 0.1, 0.0, 1.0);` forces geometry to screen-center — confirms "is this being clipped off-screen?".
- **Compute pre-pass for vertex logging.** Write to a storage buffer indexed by `@builtin(vertex_index)` in a separate compute shader that reproduces the vertex math, read back from CPU.
- **NaN probe.** `if (any(pos != pos)) { out.position = vec4(0.0/0.0); }` drops NaN vertices into a black hole — their triangles vanish, confirming NaN is the issue.
- **RenderDoc Mesh Viewer** shows transformed vertex outputs as a sortable spreadsheet. Sort by column to find the row with `inf` / `nan` / absurd value.

## §6 — WGSL semantic traps (these look like bugs, they're spec)

| Symptom | Cause | Fix |
|---|---|---|
| Compile error: "derivative_uniformity" | `textureSample` inside non-uniform control flow (branch on a varying value) | Use `textureSampleLevel(tex, s, uv, 0.0)` or `textureSampleGrad`; or hoist the sample out of the branch and multiply the result by the mask |
| Texture LOD flickers along edges | Derivatives computed across quad boundaries on discarded pixels | Same fix — explicit LOD/grad |
| `@builtin(position)` looks off-by-half | Spec: pixel-centre is `(0.5, 0.5)`, not `(0, 0)` | Floor with `vec2<u32>(pos.xy)` (truncation handles 0.5 → 0) |
| `discard` tanks perf on AMD/Intel | Forces late-Z, defeats HiZ | Only use in alpha-test materials; otherwise rely on blend or pipeline state |
| Writing `@builtin(frag_depth)` tanks fps | Disables early-Z for the entire draw | Avoid unless required; if required, group depth-writers last in draw order |
| Counter wraps unexpectedly | u32 overflow (no trap) | Use two u32s or saturating clamp |
| Arithmetic shift surprise | WGSL `<<`/`>>` on i32 is arithmetic; shift count is mod 32 | Mask first: `x >> (n & 31u)` |
| Precision loss far from origin | f32 world coords + far camera | Use camera-relative positions; subtract camera_pos on CPU, pass as uniform |
| `select(a, b, cond)` backwards | WGSL: `select(false_val, true_val, cond)` — **opposite of GLSL's mix / C's ternary** | Memorize the signature |
| Integer varying won't compile | Integer interpolation must be flat | Add `@interpolate(flat)` on both vertex output and fragment input |
| `1.0 / 0.0` = Inf silently | No division trap | Clamp denominators: `1.0 / max(eps, x)` |

Uniformity-analysis docs: WGSL spec §16.3, and https://github.com/gpuweb/gpuweb/pull/1571. If you see "possibly non-uniform value passed here", trace the flagged value back to a varying input, restructure or use `*Level` / `*Grad` sampler variants.

## §7 — Tooling beyond RenderDoc

- **`naga` CLI** (`cargo install naga-cli`):
  - `naga my.wgsl --validate` — spec conformance check.
  - `naga my.wgsl out.spv` — emit SPIR-V for RenderDoc / RGA.
  - `naga my.wgsl out.metal` / `naga my.wgsl out.hlsl` — other targets; if translation fails here but WGSL validates, it's a naga backend bug — file upstream.
  - `naga my.wgsl out.txt` — dumps naga IR; useful to see what the validator thinks your code means.
- **wgsl-analyzer** (VS Code: `wgsl-analyzer.wgsl-analyzer`): LSP for WGSL — goto-def, type-on-hover, inline naga diagnostics. Install before any WGSL work; catches ~half of bugs at type-check time. Works with Bevy's `#import` / `#define_import_path` via naga_oil (some defs require configuration).
- **wgpu `dump_shaders`** / `WGPU_SHADER_DEBUG=1`: inspect translated MSL / HLSL / SPIR-V output. Reveals what naga actually compiled your shader into.
- **WGSL playgrounds:** https://webgpu.github.io/webgpu-samples/, https://playcanvas.github.io/tutorials/shaders/, Babylon WGSL sandbox. Fast iteration without booting the game.
- **wgpu traces** (`WGPU_TRACE=/tmp/trace cargo run ...`): binary replay of a frame. Useful for repro on other hardware; not for shader stepping.
- **AMD Radeon GPU Analyzer (RGA)**: static SPIR-V → GCN/RDNA ISA with VGPR/SGPR pressure, instruction count, latency estimates. Feed naga's `.spv`. Excellent for "why is this shader slow?" on AMD.
- **AMD Radeon GPU Profiler (RGP)**: wavefront occupancy, barrier analysis. Vulkan captures only.
- **NVIDIA Nsight Graphics**: best-in-class shader debugger on NVIDIA Vulkan. Not an option on this project (AMD GPU).
- **Tracy via `bevy/trace_tracy`** — GPU timeline alongside CPU. Already available in the project.

## §8 — Bevy-specific tricks

- **Hot-reload** works for shaders loaded via `asset_server.load("shaders/foo.wgsl")`. **Broken** for shaders registered via `FromWorld` or `internal_asset!` (https://github.com/bevyengine/bevy/issues/1449). If your shader won't reload, that's why — convert to file-load.
- **Shader defs for debug builds.** In a `Material` impl:
  ```rust
  fn specialize(
      _pipeline: &MaterialPipeline<Self>,
      descriptor: &mut RenderPipelineDescriptor,
      _layout: &MeshVertexBufferLayoutRef,
      _key: MaterialPipelineKey<Self>,
  ) -> Result<(), SpecializedMeshPipelineError> {
      if cfg!(debug_assertions) {
          descriptor.vertex.shader_defs.push("DEBUG".into());
          if let Some(frag) = descriptor.fragment.as_mut() {
              frag.shader_defs.push("DEBUG".into());
          }
      }
      Ok(())
  }
  ```
  Gate WGSL diagnostics with `#ifdef DEBUG ... #endif`. Zero cost in release.
- **ExtendedMaterial for debug variants.** Wrap the production material: `ExtendedMaterial<StandardMaterial, MyDebugExt>`. The extension adds a bind group with `debug_mode: u32` and replaces the fragment shader. Production path is untouched; toggle debug via component at runtime. One draw stays normal, another gets debug shader — side-by-side on screen.
- **naga_oil imports**: `#import "shaders/common.wgsl"::fresnel` works via naga_oil's module-by-module IR composition. If a helper fails to import, verify the source declares `#define_import_path foo::bar` at top.
- **F2 + auto-screenshot ring** (this project): every screenshot is a bisection step. Name the files after the hypothesis you're testing.

## §9 — Performance debugging

- **Instruction count via naga → RGA**: translate, feed to RGA, read "Instruction count" and "VGPR pressure". Target ≤64 VGPRs on RDNA2 for 4-wave occupancy; higher tanks perf.
- **Bottleneck classification** (in Nsight/RGP — or reason by hand from RGA output):
  - `LdsBusy` / `VmemStall` → texture bandwidth. Batch samples, reduce mip bias, use smaller formats.
  - `VALUStall` → ALU-bound. Strength-reduce; cache expensive normalize / pow.
  - `InstFetchStall` → shader too long; split pipelines.
  - High scalar-ALU stall + low occupancy → divergent branches; refactor to `select()` / `mix()`.
- **A/B frame-time**: wrap a section in `#ifdef HEAVY_PATH`, flip per frame, log via `FrameTimeDiagnosticsPlugin`. 0.2 ms deltas are detectable over 120-frame averages.
- **Cheap wins**: `textureSampleLevel(.., 0.0)` removes gradient cost; replace `pow(x, n)` with repeated multiply for small n; avoid `normalize` in fragment if a normalized varying suffices (flag `@interpolate(linear)` then normalize once per fragment).
- **Overdraw heatmap**: full-screen pass adding `+0.02` per pixel drawn, visualized as a heatmap. Reveals transparent-object overdraw — often the real cost, not the shader body.

## §10 — Learning sources

**Math intuition / foundations:**
- Inigo Quilez — https://iquilezles.org/articles/ — SDFs, smooth min, noise, palettes, intersection primitives. Every article has a Shadertoy demo.
- Freya Holmér (YouTube `@acegikmo`) — "Shaders for Game Devs" + "Math for Game Devs". Workbook: https://github.com/nucleartide/Shaders-for-Game-Devs-Workbook.
- The Book of Shaders — https://thebookofshaders.com/ — GLSL-flavoured, ~95% transfers to WGSL.
- Alan Zucconi — https://www.alanzucconi.com/tutorial-series/ — 69+ posts; especially the "Journey sand" and "Learning Shaders" series.
- Acko.net (Steven Wittens) — https://acko.net/ — long-form essays (ShaderGraph, MathBox, SDF typography).
- Catlike Coding — https://catlikecoding.com/unity/tutorials/ — Unity but the math is identical; go-to for PBR, flow maps, terrain.

**WebGPU / WGSL / wgpu specific:**
- WebGPU Fundamentals — https://webgpufundamentals.org/ — the WGSL primer; has a debugging page.
- Learn WGPU — https://sotrh.github.io/learn-wgpu/ — the Rust/wgpu tutorial.
- WGSL spec — https://www.w3.org/TR/WGSL/ — uniformity analysis §16.3, built-ins §15.
- Tour of WGSL — https://google.github.io/tour-of-wgsl/ — interactive.
- webgpu.rocks — compact function reference.
- Bevy `#rendering` Discord — real-time help from robtfm and other rendering contributors. Most authoritative Bevy-shader source.

**Examples / reference art:**
- Shadertoy — https://www.shadertoy.com/ — skim for technique, port to WGSL (syntax differs, math does not).

## §11 — Opinionated recommendations

1. **Reach for "return a color" first, always.** 10 seconds, solves 80% of shader bugs.
2. **Use RenderDoc, not Nsight, on this project** (AMD RADV). Set `WGPU_BACKEND=vulkan` before capturing; don't bother debugging over GL — shader debugger is disabled.
3. **Don't build a bespoke printf framework unless you'll use it twice a week.** The storage-buffer-on-cursor pattern is a two-hour build — worth it only for deep compute-shader debugging where `return vec4(...)` doesn't apply.
4. **Run `naga --validate` in pre-commit.** Cheaper than finding spec violations at runtime via a wgpu panic.
5. **Keep a `debug_shaders.wgsl` import** with `viz_signed`, `viz_unit`, `viz_bool`, `viz_uv`, `viz_normal` helpers. Import in every material. Zero cost in release (dead-code eliminated).
6. **wgsl-analyzer is not optional.** Install before any WGSL work.
7. **When in doubt, shorten the pipeline.** One diagnostic `return` early catches more bugs than any amount of whiteboard reasoning about the final output.

## §11.5 — Case study: light banding near coast (2026-04 session)

A concrete worked example of the bisection methodology, documented in
detail because the misdiagnosis cost a full session and the dead ends
recur.

### Symptom
Pale cream / light green strip ~20 px wide paralleling every coastline
and every inland cliff edge (lake rims, crater walls). Persisted across
camera distances. Rivers passing through the band were visibly lighter,
ruling out distance fog / vignette.

### What the fault doc claimed (wrong)
`LIGHT_BAND_COLOUR_FAULT.md` was written mid-session and pinned blame on
two terrain-shader paths: (1) a `vert_color.rgb` beige tint multiply,
(2) the `coast_darken` luminance ramp being too gentle. Both contributed
visible artefacts, but neither was the dominant source of the
"light band" the user kept reporting. Removing them improved the wide
view but left the close-zoom strip intact.

### Process-of-elimination that actually found it
The user enforced a strict bisection: **disable every shader, re-enable
one at a time, do not re-enable without explicit approval.** This caught
what individual-shader edits had missed.

1. All five fragment shaders (`terrain`, `coast`, `sea`, `ocean`, `fog`)
   patched to `if (input.world_position.x < 1e20) { discard; }` — only
   `ClearColor` visible. Confirmed the terrain mesh isn't the only
   actor. Use the spurious-condition wrapper because naga treats bare
   `discard` as a terminator and flags any following code as
   unreachable.
2. Re-enabled terrain only. Strip visible. → on the terrain mesh.
3. Effects within `terrain_material.wgsl` toggled one at a time:
   - `cliff_t = 0.0` — strip persists.
   - `beach_t = 0.0` — strip persists.
   - `var color = ambient + diffuse + fill;` → `return base_color`
     (unlit) — **strip vanishes.** Bug is in the lighting term.
   - `color = ambient` only — strip ~half intensity. Some contribution
     from ambient.
   - `color = diffuse` only — strip strongly visible. Diffuse is the
     dominant contributor.
4. Diagnosis: `let ndotl = max(dot(normal, light_dir), 0.0);` —
   diffuse intensity scales with `normal.y`. Cliff-top BFS-ring
   vertices have mesh-smoothed normals tilted toward the sun (because
   `gen_cliff_glb.rs` smooths from flat inland → vertical cliff face),
   while inland is purely flat. Tilted normals catch more diffuse
   light → bright band along every cliff crest, including inland
   crater rims and lake edges where the same smoothing runs.

### Fix
Replace `dot(normal, light_dir)` with `max(light_dir.y, 0.0)` — a
fixed virtual-up normal. Day/night sun-colour cycle is preserved (the
sun-warmth tint still varies with elevation), but the lighting no
longer reads the per-fragment normal so it can't differ across the
ring. Hemisphere ambient (`up_factor = normal.y * 0.5 + 0.5`) was also
replaced with a constant — even the small ambient gradient was
detectable at extreme zoom.

```wgsl
// Before — produces bright band on tilted BFS-ring normals
let ndotl = max(dot(normal, light_dir), 0.0);
let diffuse = base_color * ndotl * 0.55 * sun_color;
let up_factor = normal.y * 0.5 + 0.5;
let ambient = base_color * mix(0.35, 0.50, up_factor);

// After — orientation-independent
let fixed_ndotl = max(light_dir.y, 0.0);
let diffuse_flat = base_color * fixed_ndotl * 0.55 * sun_color;
let ambient_flat = base_color * 0.42;
return vec4(ambient_flat + diffuse_flat, 1.0);
```

### Lessons that generalise
- **Don't trust an analysis doc you wrote during a hot loop.** Re-bisect
  before assuming the documented cause is correct. Two earlier
  contributing factors do not mean a third can't dominate.
- **Bisect by stage, not by file.** The fault was in the lighting
  formula inside `terrain_material.wgsl`. File-level disable wouldn't
  have caught it without continuing into the fragment body.
- **Wrap `discard` in a spurious condition** (`if (val < 1e20)`) so
  naga doesn't reject the unreachable code following it.
- **The user's "still visible" is data.** Believe it over the metric.
  Sobel / luminance-profile tests called the band "fixed" multiple
  times when the user could still clearly see it. The metrics measured
  the wrong dimension (luminance step at the ring, not the lighting
  contribution that survived).
- **Strip the shader to `return base_color` early.** Took ~20 minutes
  to discover lighting was the cause once that step happened; the
  earlier hours were spent re-tuning data ramps that addressed
  symptoms one layer up.

### Secondary cleanups that landed in the same commit
- `ocean_material.wgsl` foam `vec3(0.85, 0.82, 0.72)` → dim grey at
  tighter depth band.
- `coast_material.wgsl` sand cap `(0.95, 0.80, 0.55)` → darker
  `(0.36, 0.30, 0.22)`; gold_shift weakened. These removed the
  bright-cream halo the user had separately complained about along
  beach strips.
- `gen_cliff_glb.rs` `coastal_mask_cells` widened 4 → 40 so the
  cliff-rim brown wash covers the full satellite ocean-bleed band.

### Related session outcome: selection-phase overlay grid pattern
Same bisection methodology; **root cause was mesh, not shader**.
`gen_cliff_glb.rs` adds center-fan subdivision vertices in every
coastal-mask cell. `terrain_map.grid_to_vert` only tracked corners,
so the territory_overlay update never coloured the centres → Gouraud
interpolation across each subdivided quad showed a transparent dot in
the middle of every tinted corner → checkerboard pattern. Fix: at
overlay-build time, cull non-corner vertices and emit clean per-cell
quads from grid corners only, with a `mean_y < 0.0` cull so quads that
straddle the coast aren't included. See
`territory_overlay::build_territory_overlay` and
`tests/integration/overlay_fill_solid.rs`.

## §12 — This project's current shader surface

Files under `assets/shaders/`:
- `terrain_material.wgsl` — terrain / cliff / beach blending driven by vertex-color alpha (1.0=terrain, 0.5=cliff, 0.0=beach). Known sensitive area: the `cliff_t = smoothstep(a, b, surface_type)` range. Over-wide range bleeds cliff tint into coastal-ring terrain vertices and produces a visible light band just inland of the cliff. Guarded by `overlay_coastal_band_luminance_profile` test.
- `coast_material.wgsl` — sand + rock blend for the coastal strip mesh; separate from terrain. `is_sand` mask + `gold_shift` multiplier controls sand warmth.
- `sea_material.wgsl` — animated ocean plane; FBM displacement + ripple normals + Blinn-Phong. Documented in `wgsl-shaders` skill.
- `ocean_material.wgsl` — deep open-ocean shader.
- `fog_material.wgsl` — edge fog overlay.

When iterating any of these, cross-reference the `wgsl-shaders` skill for technique database entries and the `/geometry` skill for constant dependencies between shader and mesh-generation code.

## Sources

- https://iquilezles.org/
- https://www.alanzucconi.com/tutorial-series/
- https://acko.net/
- https://thebookofshaders.com/
- https://webgpufundamentals.org/webgpu/lessons/webgpu-debugging.html
- https://sotrh.github.io/learn-wgpu/
- https://www.w3.org/TR/WGSL/
- https://google.github.io/tour-of-wgsl/
- https://renderdoc.org/docs/how/how_debug_shader.html
- https://renderdoc.org/docs/how/how_shader_debug_info.html
- https://github.com/gfx-rs/wgpu/issues/3896
- https://github.com/looran/wgsl-debug
- https://github.com/gpuweb/gpuweb/issues/4704
- https://github.com/gfx-rs/naga
- https://github.com/bevyengine/naga_oil
- https://github.com/wgsl-analyzer/wgsl-analyzer
- https://bevy-cheatbook.github.io/assets/hot-reload.html
- https://bevy.org/examples/shaders/shader-defs/
- https://gpuopen.com/rga/
- https://gpuopen.com/rgp/
- https://github.com/nucleartide/Shaders-for-Game-Devs-Workbook
- https://www.youtube.com/@acegikmo
