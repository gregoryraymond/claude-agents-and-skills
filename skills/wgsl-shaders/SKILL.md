---
name: wgsl-shaders
description: Guide for writing and iterating WGSL shaders in this Bevy project. Apply when modifying sea_material.wgsl, fog_material.wgsl, or any shader work. Includes visual iteration protocol, technique reference database, and production-grade rendering strategies.
user-invocable: true
allowed-tools: Read, Grep, Bash, Edit, Write, Agent, WebSearch
---

# WGSL Shader Development Guide

## Reference Database (REQUIRED)

A Notion database of 35+ shader techniques with WGSL code, visual descriptions, and performance notes:
https://www.notion.so/242d870d9d644cefaf30957a6a33ca24

Data source ID: `7462b024-3b50-41bd-9489-abcf3eb79a2e`

**IMPORTANT: Before implementing any technique, you MUST load the relevant Notion database entry into context.** Use the Notion MCP `notion-fetch` or `notion-search` tool to retrieve the full entry including WGSL code snippets, performance notes, and top-down effectiveness rating. Do not work from memory of these techniques.

## Technique Reference Summary

### Core Shader Building Blocks

**Value Noise (2D)** — Hash-based 2D noise with bilinear interpolation. The foundation of all procedural ocean effects in the current shader. Uses fract(sin(dot(...))) hash with smoothstep interpolation between grid cells. 4 hash lookups per evaluation. Cheap individually but expensive when stacked into 5+ octaves per pixel. Currently used for both vertex wave displacement and fragment ripple normals.
- Top-Down: High | Load from DB: "Value Noise"

**Sharp Noise (peaked crests)** — Takes absolute value of centered noise: `1.0 - abs(noise(p)*2.0-1.0)`. Creates sharp peaks at zero crossings with flat troughs between them, simulating ocean wave crest ridges seen from above. Same cost as regular noise plus one abs(). Use sparingly on lower octaves only — applying to all octaves creates visual noise (lesson learned from our iterations).
- Top-Down: High | Load from DB: "Sharp Noise"

**FBM (Fractal Brownian Motion)** — Sums multiple noise octaves at increasing frequency and decreasing amplitude, with a rotation matrix applied between octaves to break grid alignment. Each octave adds finer detail. 4 octaves = 16 hash lookups. The core loop: `val += amp * noise(pos); amp *= 0.5; pos = rot * pos * 2.0;`. Keep to 3-5 octaves for vertex displacement, 2-3 for fragment.
- Top-Down: High | Load from DB: "FBM"

**Blinn-Phong Specular** — Half-vector specular model: `pow(dot(normal, half_vec), power)`. The power controls highlight sharpness — high power (80-120) creates tight sun glints on wave crests, low power (4-8) creates a broad sheen across the whole surface. For top-down views, you need BOTH: a sharp lobe catches individual crests, a broad lobe provides overall surface sheen. The broad lobe is critical because at steep top-down angles, sharp specular is nearly invisible.
- Top-Down: High | Load from DB: "Blinn-Phong"

**Fresnel Reflection** — Water reflects more light at grazing angles and is more transparent when viewed straight down. Schlick approximation: `F = F0 + (1-F0) * pow(1-dot(N,V), 5)`. For a top-down strategy camera looking nearly straight down, Fresnel makes water more transparent/refractive. At the edges of the view, water becomes more reflective. This is why the centre of the ocean looks different from the edges — it's physically correct behavior. F0 for water is approximately 0.02.
- Top-Down: High | Load from DB: "Fresnel"

**Wave Self-Shadowing** — Darkens wave faces that tilt away from the light direction using `dot(normal, light_dir)`. The result is mapped through smoothstep to create a soft transition between lit faces and shadowed back-faces. This is the single most important technique for making individual waves visible from top-down — without it, waves look flat and indistinguishable. shadow_min of 0.25 means shadowed faces are 25% brightness; the smoothstep range (-0.05, 0.35) controls transition sharpness.
- Top-Down: High | Load from DB: "Wave Self-Shadowing"

**Height-Based Color Modulation** — Maps wave displacement height to a brightness multiplier: crests are brighter, troughs are darker. Uses smoothstep to map the wave height range to a 0-1 factor, then `mix(trough_dark, crest_bright, factor)` to modulate base_color. Current range is 0.65 (troughs at 65% brightness) to 1.30 (crests at 130%). This creates the visible banding pattern that follows wave shapes. Essential for top-down readability alongside self-shadowing.
- Top-Down: High | Load from DB: "Height-Based Color"

**Ripple Normal Perturbation** — Computes per-pixel normals from procedural noise using finite differences (central differencing). Samples ripple_height at the fragment position and two offset positions (pos+eps_x, pos+eps_z), then builds a normal from the height differences. This adds fine wavelet detail that catches specular light without requiring vertex displacement at that scale. The ripple_scale parameter controls how much the normals deviate from the vertex normal — 0.08-0.12 is subtle shimmer, >0.15 creates visible noise. Currently the most expensive part of the fragment shader (3x noise evaluations per pixel).
- Top-Down: High | Load from DB: "Ripple Normal"

**Atmospheric Distance Fog** — Blends fragment color toward a haze color based on distance from the map center, using `smoothstep(onset, max_dist, distance) * max_opacity`. Creates depth perception and naturally hides map edges. The fog_rect uniform defines the boundary. Current settings: onset at 50% distance, max blend 55%, haze color is a blue-grey. This is separate from the fog_material.wgsl overlay which handles the visual fog-of-war border.
- Top-Down: High | Load from DB: "Atmospheric Distance Fog"

**Wave Amplitude Envelope** — Two large-scale noise layers at very low frequencies (0.08, 0.15) that drift slowly over time, creating spatial variation in wave height. Output ranges from 0.4 to 1.0, meaning some areas have tall waves and others are calmer. This breaks up the uniform wave field into natural-looking wave groups/sets. The effect is more apparent in animation than in still screenshots. Adds 2 extra noise evaluations in the vertex shader.
- Top-Down: Medium | Load from DB: "Wave Amplitude Envelope"

**Warm Sunlight Tint** — Multiplies lit wave faces by a warm color `vec3(1.08, 1.04, 0.92)` blended in by ndotl (dot product of normal and light direction). Sun-facing surfaces get a subtle red/green boost with blue reduction, while shadowed faces stay cool grey-blue. This creates the warm/cool temperature contrast visible in real ocean photographs — sunlit crests are warmer than shadowed troughs. A single mix() operation, negligible cost.
- Top-Down: High | Load from DB: "Warm Sunlight"

**Subsurface Scattering** — Simulates light transmitting through thin wave crests. Computes a forward-scatter term using `dot(view_dir, -light_dir)` raised to a power, masked by wave height so only crests glow. The SSS color is typically warm teal. In a top-down view, this mainly appears as subtle bright highlights on elevated wave crests. Low cost (a few dot products and a pow), but the visual impact from directly overhead is limited compared to a first-person sea-level view.
- Top-Down: Medium | Load from DB: "Subsurface Scattering"

### Ocean & Wave Techniques

**Gerstner Waves (Trochoidal)** — The most recommended upgrade for this project. Vertices move in circular orbits instead of just vertically, producing the characteristic trochoid wave profile: sharp narrow crests with broad flat troughs. Each wave is defined by direction, wavelength, amplitude, steepness (Q parameter, 0-1), and speed. Sum 4-8 waves with different parameters for a natural look. The horizontal XZ displacement bunches vertices together at crests, making them visually sharper without extreme vertical amplitude. Crucially, normals can be computed analytically (closed-form derivative of the wave equation), eliminating the expensive 3-sample finite difference currently used for vertex normals. This makes Gerstner both better looking AND cheaper than the current value noise approach. The Q (steepness) parameter directly controls crest sharpness — when `sum(Q_i * omega_i * A_i) > 1`, the surface self-intersects (loops), which should be avoided.
- Top-Down: High | Load from DB: "Gerstner Waves"

**FFT Ocean (Tessendorf)** — The gold standard for high-fidelity real-time ocean rendering. Jerry Tessendorf's 2001 paper describes generating ocean surfaces by sampling a statistical wave spectrum (Phillips or JONSWAP) in the frequency domain and transforming to spatial domain via inverse FFT. The result is a displacement map + normal map that tiles seamlessly and produces non-repeating, physically correct wave statistics with proper frequency distribution and dispersion relationships. Requires WebGPU compute shaders for the FFT butterfly passes (typically 512x512 grid = 9 passes). The displacement and normal maps are generated once per frame and sampled cheaply in vertex/fragment shaders. Also produces choppy wave horizontal displacement and a Jacobian field for foam detection. The WebTide project proves this is viable on WebGPU, but it's significantly more complex to implement than Gerstner waves for potentially modest visual improvement at our camera distance.
- Top-Down: High | Load from DB: "FFT Ocean"

**Normal Map Detail Waves** — Overlays 2-3 scrolling tileable normal map textures at different scales and animation speeds to add fine wavelet detail without any vertex displacement. The normal maps are blended using Reoriented Normal Mapping (RNM) for correctness — simple additive blending is incorrect for normal maps. This is the primary way AAA games add small-scale wave detail visible from any camera distance. A single 256x256 tileable ocean normal map sampled at 2-3 UV scales with time-based scrolling replaces our current expensive procedural ripple_height function (which does 3x noise evaluations per pixel across 3 octaves = 36 hash lookups). The texture approach is dramatically cheaper and produces more natural-looking detail. This should replace ripple_height as the second priority after Gerstner waves.
- Top-Down: High | Load from DB: "Normal Map Detail Waves"

**Two-Level Waves (GPU Gems)** — The 2004 technique from the GPU Gems book that remains the baseline for most real-time water. Level 1: 4 Gerstner waves displace the mesh vertices (large-scale wave shapes). Level 2: ~15 additional waves are pre-rendered into a 256x256 normal map (fine detail). The normal map is regenerated each frame on the GPU or uses scrolling pre-baked textures. Includes edge-length filtering (attenuate waves shorter than 4x mesh edge length to prevent aliasing) and depth-based amplitude modulation for shallows. Runs on the most minimal shader hardware. This is the approach we should target — it provides the best quality-per-cost ratio for a WebGPU strategy game.
- Top-Down: High | Load from DB: "GPU Gems Two-Level"

**Beer-Lambert Water Absorption** — Physically-based depth coloring using `transmittance = exp(-depth * extinction_coefficient)`. Different wavelengths have different extinction rates: red is absorbed quickly (high coefficient ~0.45), green moderately (~0.09), blue slowly (~0.06). This produces the natural color gradient from transparent/turquoise in shallow water to dark navy in deep water without requiring hand-tuned color stops. One exp() call per pixel, extremely cheap. Should replace our current 4-stop linear gradient which is less physically accurate.
- Top-Down: High | Load from DB: "Beer-Lambert"

**Jacobian Foam** — Detects where waves are breaking by computing the Jacobian determinant of the horizontal displacement field: `J = (1 + dDx/dx)(1 + dDz/dz) - (dDz/dx)(dDx/dz)`. When J drops below a threshold (surface is folding/self-intersecting), that's where whitecaps form in nature. Foam intensity accumulates over time and decays, creating persistent foam trails that fade. This is the standard technique for generating realistic dynamic foam in production water shaders. Requires horizontal displacement data (from Gerstner or FFT), which our current value-noise-only approach doesn't provide. Would need Gerstner waves implemented first.
- Top-Down: High | Load from DB: "Jacobian Foam"

**Fresnel Transparency** — Extends the basic Fresnel concept specifically for water transparency. At steep angles (looking straight down as in our game), `dot(view, normal)` is close to 1.0, so Fresnel gives low reflectance = high transparency. At grazing angles (edges of view), high reflectance = mirror-like. For our top-down camera, the water should be significantly more see-through in the center of the screen than at the edges. Currently our shader uses a hardcoded view direction — switching to Bevy's actual camera position would make Fresnel respond to zoom level and pan position, dramatically improving the sense of a 3D surface.
- Top-Down: High | Load from DB: "Fresnel Transparency"

### Beach & Coastal Techniques

**Depth-Based Shore Foam** — The simplest and most effective shoreline effect. Compares the water surface depth with the scene depth buffer; where the difference is small (water meets land), foam is drawn. A scrolling noise texture modulates the foam edge to prevent hard lines. From top-down, these foam lines clearly delineate coastlines and add significant visual richness. Requires access to the depth buffer, which in Bevy means using a prepass. Very cheap: one depth sample + one noise texture sample per pixel. This is how most games from indie to AAA render shoreline foam.
- Top-Down: High | Load from DB: "Shore Foam"

**Animated Shoreline Waves** — Uses a distance-from-shore gradient (0 at coast, 1 at deep water) combined with time-driven sine waves to animate waves rolling up the beach. The wave front carries white foam, and the sand behind the retreating wave darkens (wet sand). The rhythmic advance/retreat cycle is highly visible from top-down and adds the feeling of a living coastline. Can be driven by a shore distance texture baked per-coastal-strip. Low cost: simple sine + smoothstep math.
- Top-Down: High | Load from DB: "Animated Shoreline"

**Sand-to-Water Coastal Blend** — Creates the natural transition gradient from dry golden sand through darker wet sand to shallow turquoise water with white foam at the waterline. Uses a signed distance from the shore with noise perturbation for an irregular edge. Four material zones blended via smoothstep: dry sand (full albedo), wet sand (darker, shinier from water film), foam line (white at transition), shallow water (turquoise). Critical for making coastlines look natural from top-down rather than having a hard land/water boundary.
- Top-Down: High | Load from DB: "Sand-to-Water"

**Tide Lines** — Draws subtle lines of debris and foam at periodic height intervals up the beach, simulating tide marks left by previous high tides. Each line is created by `smoothstep(threshold, 0.0, abs(world_y - line_height + noise))` with noise perturbation for natural irregularity. Higher lines (older tides) are rendered fainter. A simple effect that adds significant realism to beaches viewed from overhead. Negligible performance cost — a few smoothstep operations.
- Top-Down: High | Load from DB: "Tide Lines"

**Flow Map Currents** — Uses a 2D texture where each pixel stores a direction vector indicating how water should flow at that location. UV coordinates for normal maps and foam textures are offset by the flow direction over time, creating the appearance of water flowing around headlands, through straits, and toward beaches. Two layers with 0.5 phase offset are crossfaded to prevent texture stretching (a well-known flow-map technique). From top-down, this makes water movement feel natural and geographic rather than uniform scrolling. Requires creating a flow map texture (can be painted in any image editor — red=X flow, green=Y flow, 0.5=no flow).
- Top-Down: High | Load from DB: "Flow Map"

### Cliff & Rock Techniques

**Triplanar Cliff Mapping** — Projects the same rock texture from all three world axes (X, Y, Z) and blends the projections using the surface normal as weights. Faces pointing up get the Y projection (top-down view), vertical faces get the X or Z projection (side view). The sharpness parameter controls blend falloff — higher values give sharper transitions between projections. This eliminates the UV stretching that plagues steep cliff faces in conventional UV mapping. From top-down, cliff edges at the coast show clean rock texture. Three texture samples instead of one, but no UV unwrapping needed.
- Top-Down: Medium | Load from DB: "Triplanar Cliff"

**Cliff Weathering & Wet Rock** — Adds environmental detail to cliff faces based on world-space height and proximity to water. Near the waterline, rock is darkened and given lower roughness (wet/shiny appearance) using `smoothstep(splash_height, 0.0, height_above_water)`. Higher up, upward-facing surfaces accumulate green moss/lichen weighted by `normal.y`. Crevices (low ambient occlusion) get darker grime. From top-down, the wet rock band at the base of coastal cliffs is visible and adds to the sense of water interaction with the environment.
- Top-Down: Medium | Load from DB: "Cliff Weathering"

### Underwater Techniques

**Voronoi Caustics** — Projects animated caustic light patterns (the dancing web-like patterns you see on the bottom of a swimming pool) onto underwater surfaces. Computed by evaluating Voronoi noise at two different scales and time offsets, then taking the minimum of both layers. The characteristic web pattern emerges from `smoothstep(0.0, 0.15, c) * smoothstep(0.4, 0.15, c)` which selects only the edges of Voronoi cells. From top-down, caustics are visible on shallow seabeds and coastal areas, adding a strong sense of water transparency and light interaction. Each Voronoi evaluation checks 9 neighboring cells (a 3x3 grid), so two layers = ~18 distance calculations per pixel.
- Top-Down: Medium | Load from DB: "Voronoi Caustics"

## Production Ocean Rendering Approaches

Before attempting a major shader rewrite, load the relevant Notion database entry for production-proven approaches. The entries below describe generic technique archetypes with links to academic papers, open-source implementations, and public tutorials.

### Stylized FFT + Art Direction
"Start realistic, then stylize" — build on a physically correct FFT-based Tessendorf ocean as the foundation, then layer artistic stylization on top. The physically correct base ensures waves behave correctly (proper dispersion, wave interaction, energy conservation) even when the visual style is non-photorealistic. Foam is generated two ways: Jacobian-based whitecaps on wave crests, and depth-buffer intersection foam around objects.
- **Load from DB**: "Stylized FFT Ocean"

### Offline-Baked FFT Displacement Textures
A common optimization for open-world naval games: use two precomputed sets of FFT displacement stored as tiling/cycling RGB textures — the expensive FFT computation is done offline, and at runtime the shader just samples textures. A third layer of small detail waves handles close-up fidelity. The system can support a full Beaufort scale (0-12) for weather, giving artists a single intuitive slider from dead calm to hurricane seas. Object hulls interact with the water via displacement masks projected onto the surface. Depth-based coloring creates transparent shallows transitioning to deep blue.
- **Load from DB**: "Baked FFT Displacement"
- **Waterplane Analysis**: https://simonschreibt.de/gat/black-flag-waterplane/

### Crest Ocean System (Open Source)
The most fully-featured open-source ocean renderer. Uses CDClipmaps (combining Clipmaps simplicity with CDLOD continuous detail) for the mesh, with multi-resolution cascaded render textures centered at the camera for displacement, foam, shadow, and depth data. Wave generation supports both ShapeFFT (spectrum-based) and ShapeGerstner (artist-controlled individual waves). The Pierson-Moskowitz empirical spectrum model drives realistic wave statistics. Multiple wave sources are combined into a single Animated Waves texture, so the water shader itself only needs one texture sample for all wave data. Includes dynamic wave simulation for object interaction via sphere force injection.
- **Load from DB**: "Crest Ocean System"
- **GitHub**: https://github.com/wave-harmonic/crest
- **Docs**: https://crest.readthedocs.io/en/stable/user/waves.html

### CPU Heightmap Simulation — STRATEGY-GAME FRIENDLY
**Most relevant to our project** — a top-down perspective pipeline. A heightmap-to-normal-map approach: simulate the water surface on CPU threads (using SIMD-optimized code), generate mipmapped normal maps, and render with a standard water shader. The CPU simulation can handle shallow river dynamics. The tradeoff is instructive: the simulation runs on dedicated CPU threads, freeing GPU for rendering. This is pragmatic for strategy games where the water is background, not the focal point. The focus is on readability at zoom distances, not close-up realism.
- **Load from DB**: "CPU Heightmap Water"
- **Engine Anatomy Write-up**: https://gpuopen.com/learn/anatomy-total-war-engine-part-2/

### GPU Gems Two-Level Waves — RECOMMENDED APPROACH
The 2004 technique from GPU Gems that remains the best cost/quality ratio for real-time water. The insight: separate wave simulation into two levels. Level 1 (geometric): 4 Gerstner waves displace mesh vertices, creating visible parallax and large-scale wave shapes. Level 2 (textural): ~15 additional waves pre-rendered into a 256x256 normal map, adding fine specular detail without vertex cost. Edge-length filtering attenuates waves shorter than 4x the mesh edge length to prevent aliasing. Depth-based amplitude modulation reduces waves in shallows. The whole system runs with zero CPU overhead and works on the most minimal shader hardware. **This is the approach we should implement** — 4 Gerstner waves in the vertex shader + a scrolling normal map in the fragment shader.
- **Load from DB**: "GPU Gems Two-Level Waves"
- **Tutorial**: https://developer.nvidia.com/gpugems/gpugems/part-i-natural-effects/chapter-1-effective-water-simulation-physical-models

### Baked Flipbook Ocean
An alternative approach that front-loads all cost to offline: simulate a tileable, looping ocean in any fluid simulator, then bake the height field, normal maps, and foam masks to flipbook textures (~100MB of storage). At runtime, the shader simply samples these pre-baked textures frame by frame — no wave computation at all. Includes fake subsurface scattering via emissive based on baked wave height, velocity buffer output for anti-ghosting in temporal super resolution, and compute shader buoyancy. The cheapest possible runtime approach with predictable visual quality. Would require generating the flipbook asset.
- **Load from DB**: "Baked Flipbook Ocean"
- **Blog**: https://stijnhernalsteen.wordpress.com/2024/01/02/watertech/

### Hexagonal Aperiodic Tiling (HPG 2024) — STATE OF THE ART
A recent academic advance in ocean rendering. Solves the biggest visual problem with FFT/tiled oceans: visible repetition patterns when the tiling period is visible from above. Uses hexagonal tiling with randomized content selection — blends exactly 3 hexagonal tiles per texel with weights that equal 1 at center and 0 at edges. The input is standard Tessendorf periodic displacement/normal maps; the output is fully aperiodic (non-repeating). Displacement maps are synthesized in the vertex shader, normals + LEAN maps in the fragment shader. Supports flow maps for directional wave control without precomputation.
- **Load from DB**: "Hexagonal Tiling"
- **Paper**: https://www.ubisoft.com/en-us/studio/laforge/news/5WHMK3tLGMGsqhxmWls1Jw

### WebTide FFT (WebGPU) — PROOF OF CONCEPT
Proves that Tessendorf FFT ocean is viable in the browser using WebGPU compute shaders. Implements Phillips spectrum on a 512x512 grid (262,144 complex multiplications per frame), Stockham FFT butterfly passes on the GPU, choppy wave horizontal displacement, and physically-based rendering with Fresnel (F=0.02+0.98*(1-cos)^5) and high-power specular (exponent 720, intensity 210). The most directly relevant open-source reference for our Bevy+WebGPU stack.
- **Load from DB**: "WebTide FFT"
- **GitHub**: https://github.com/BarthPaleologue/WebTide
- **Blog**: https://barthpaleologue.github.io/Blog/posts/ocean-simulation-webgpu/

### Alex Tardif Water Walkthrough — COMPLETE TUTORIAL
The most thorough single-page water shader tutorial. Covers every component of a production water shader: 2 Gerstner waves (from GPU Gems), hardware tessellation (factor 7 via hull + domain shaders), dual scrolling normal maps blended via TBN matrix, screen-space reflections with walk-back refinement against the depth buffer, refraction via normal-offset UV distortion with above-water validation, and a 3-component foam system (texture-based foam + noise spotting + height/angle placement + edge foam via depth softening). Specular uses PBR GGX distribution disrupted by 3 noise samples at different UV scales for sparkle.
- **Load from DB**: "Alex Tardif Water Walkthrough"
- **Blog**: https://alextardif.com/Water.html

### Dual-Spectrum JONSWAP Middleware
Middleware-style ocean rendering featuring dual customizable JONSWAP spectra with individual wind speed, direction, and amplitude — this means you can have local wind waves AND distant swell in the same scene. Frequency-domain simulation via inverse FFT. Interactive effects (wakes, explosions) via velocity potentials injected into the frequency domain. Generates anisotropic BRDF data in real-time for physically-based water surfaces. Multiple LOD settings. Parameterized by real-world variables (wind speed in m/s, direction in degrees).
- **Load from DB**: "Dual JONSWAP Middleware"

## Recommended Strategy for This Project

For a **top-down strategy game on Bevy + WebGPU**, the recommended approach (by priority):

1. **Gerstner Waves** (replace value noise) — physically correct, cheaper, better looking
2. **Normal Map Detail Waves** (replace procedural ripple_height) — cheaper, more detail
3. **View-dependent lighting** (use Bevy's actual camera position, not hardcoded)
4. **Beer-Lambert depth coloring** (replace linear depth gradient)
5. **Depth-based shore foam** (add shoreline definition)
6. **Flow maps** (water flows around geography)

This matches the GPU Gems "two-level" approach used successfully in production since 2004.

## Project Shaders

| File | Purpose |
|------|---------|
| `crates/europe-zone-control/src/sea_material.wgsl` | Animated ocean (waves, specular, color) |
| `crates/europe-zone-control/src/fog_material.wgsl` | Edge fog overlay |

The ocean shader runs on narrow coastal strip meshes (12 units wide), NOT a full-screen plane. Most visible "ocean" at distance is `ClearColor` fill.

## Visual Iteration Protocol

**NEVER self-assess shader quality with scores.** Always verify visually.

### The Loop

1. **Capture before**: `cargo run -p europe-zone-control -- --video /tmp/ocean-before --video-frames 60 --camera-x 15 --camera-z -53 --camera-distance 30`
2. **Read frames**: Compare frames 0, 20, 40 against reference (`/mnt/d/capture7.png`, `/mnt/d/capture5.png`)
3. **Identify the SINGLE biggest visual difference**
4. **Make ONE targeted change**
5. **Capture after**: `cargo run -p europe-zone-control -- --video /tmp/ocean-after --video-frames 60 --camera-x 15 --camera-z -53 --camera-distance 30`
6. **Compare before/after/reference visually**
7. **Revert if worse**: `git checkout -- crates/europe-zone-control/src/sea_material.wgsl`

### Rules

- ONE change per iteration — never batch multiple changes
- Always capture video (not just screenshots) — the shader is animated
- If using `WGPU_BACKEND=gl` and it panics, try without it (Vulkan default)
- Compare at GAME camera angle (top-down), not first-person
- Revert immediately if a change doesn't clearly improve things

## Reference Images

| File | View | Use For |
|------|------|---------|
| `/mnt/d/capture7.png` | First-person ocean (Blender) | Wave shape, specular, color reference |
| `/mnt/d/capture6.png` | First-person ocean (Blender) | Wave density, texture reference |
| `/mnt/d/capture5.png` | Top-down ocean (Blender) | **Primary reference** for game camera angle |
| `/mnt/d/OceanTutorial.blend` | Blender source file | Study shader node setup if needed |

## Lessons Learned (from 23+ iterations)

### What Works
- Brightening base colors from near-black to steel-blue
- Broad specular with low exponent (6-8) for top-down visibility
- Wave self-shadowing (ndotl-based darkening, min ~0.25)
- Height-based crest/trough color modulation
- Desaturated grey-blue sky reflections
- Wave frequency ~2.8x base for visible individual crests
- Warm sunlight tint on lit faces

### What Doesn't Work
- High ripple_scale (>0.15) — creates visual noise/static
- Sharp_noise on ripple octaves — too aggressive, looks like snow
- Sparkle masks (noise-modulated specular) — creates uniform noise instead of natural glints
- More than 3 ripple octaves — diminishing returns, high cost
- Aggressive crest highlights (>0.15 additive) — washes out the ocean
- Self-assessed quality scores — always lie. Use video captures.

### Parameter Safe Ranges

| Parameter | Safe Range | Current | Notes |
|-----------|-----------|---------|-------|
| ripple_scale | 0.06 - 0.12 | 0.10 | >0.15 creates noise |
| ripple base freq | 3.0 - 5.0 | 4.5 | >6.0 too busy |
| ripple octaves | 2 - 3 | 3 | >3 diminishing returns |
| spec_sharp power | 40 - 120 | 80 | <40 too soft, >200 invisible from top-down |
| spec_broad power | 4 - 8 | 6 | <4 washes out |
| height_mod range | 0.65-1.30 | 0.65-1.30 | >1.4 too bright, <0.5 too dark |
| shadow_min | 0.20 - 0.40 | 0.25 | <0.15 too dark |
| wave base freq | 1.5 - 3.5 | 2.8 | Higher = more crests but smaller |
| vertex octaves | 4 - 5 | 5 | >6 expensive, minimal visual gain |

## WGSL Syntax Quick Reference

```wgsl
// Types
var x: f32 = 1.0;
var v: vec2<f32> = vec2(1.0, 2.0);
var v3: vec3<f32> = vec3(0.1, 0.2, 0.3);
var m: mat2x2<f32> = mat2x2(cos(a), sin(a), -sin(a), cos(a));

// Built-in functions
floor(x)  ceil(x)  fract(x)  abs(x)  sign(x)
min(a,b)  max(a,b)  clamp(x, lo, hi)
mix(a, b, t)  smoothstep(edge0, edge1, x)
sin(x)  cos(x)  pow(x, n)  sqrt(x)  length(v)
dot(a, b)  cross(a, b)  normalize(v)  reflect(I, N)

// Vertex output
struct VertexOutput {
    @builtin(position) clip_position: vec4<f32>,
    @location(0) world_position: vec3<f32>,
    @location(1) uv: vec2<f32>,
};

// Fragment output
@fragment fn fragment(in: VertexOutput) -> @location(0) vec4<f32> { ... }

// Texture sampling
@group(2) @binding(1) var my_texture: texture_2d<f32>;
@group(2) @binding(2) var my_sampler: sampler;
let color = textureSample(my_texture, my_sampler, uv);
```

## Bevy Material Integration

The sea shader uses `MaterialExtension` in `sea.rs`. Key uniforms:
- `time: f32` — elapsed seconds
- `amplitude: f32` — wave height scale
- `fog_rect: vec4<f32>` — fog boundary (center_x, center_z, half_w, half_h)
- Bathymetry texture — depth-based coloring

To add a new uniform, update both `SeaMaterial` struct in `sea.rs` and the `@group/@binding` in the WGSL.

## Source Code Examples (Direct File Links)

Before implementing any technique, study these real implementations. Links are to raw source files you can fetch and read directly.

### Bevy/WGSL (Most Relevant)

**Neopallium/bevy_water** — Production Bevy ocean. Directional waves, FBM noise, Beer's law depth, Fresnel, PBR. 176 stars.
- Vertex shader: https://raw.githubusercontent.com/Neopallium/bevy_water/main/assets/shaders/water_vertex.wgsl
- Fragment shader: https://raw.githubusercontent.com/Neopallium/bevy_water/main/assets/shaders/water_fragment.wgsl
- Shared functions: https://raw.githubusercontent.com/Neopallium/bevy_water/main/assets/shaders/water_functions.wgsl
- Bindings: https://raw.githubusercontent.com/Neopallium/bevy_water/main/assets/shaders/water_bindings.wgsl
- FBM noise: https://raw.githubusercontent.com/Neopallium/bevy_water/main/assets/shaders/noise/fbm.wgsl
- Value noise: https://raw.githubusercontent.com/Neopallium/bevy_water/main/assets/shaders/noise/vnoise.wgsl

**nickjhughes/bevy_water_shaders** — WGSL port of Acerola's FFT ocean to Bevy. Three approaches in one repo.
- FFT water (WGSL): https://raw.githubusercontent.com/nickjhughes/bevy_water_shaders/main/assets/shaders/fft_water_material.wgsl
- FBM water (WGSL): https://raw.githubusercontent.com/nickjhughes/bevy_water_shaders/main/assets/shaders/fbm_water_material.wgsl
- Sum-of-sines water (WGSL): https://raw.githubusercontent.com/nickjhughes/bevy_water_shaders/main/assets/shaders/sum_water_material.wgsl

**tailow/water-simulation** — Bevy ocean with volumetric underwater raymarching.
- Full shader: https://raw.githubusercontent.com/tailow/water-simulation/main/assets/shaders/water.wgsl

**mekroner/water-shader** — Bevy water with animated normal maps, Beer's law, PBR.
- Full shader: https://raw.githubusercontent.com/mekroner/water-shader/main/assets/shaders/water_material.wgsl

### WebGPU WGSL (FFT Pipeline)

**BarthPaleologue/WebTide** — Full FFT ocean in WGSL compute shaders. The most complete WGSL FFT reference.
- Phillips spectrum: https://raw.githubusercontent.com/BarthPaleologue/WebTide/master/src/shaders/phillipsSpectrum.wgsl
- Dynamic spectrum update: https://raw.githubusercontent.com/BarthPaleologue/WebTide/master/src/shaders/dynamicSpectrum.wgsl
- Horizontal IFFT: https://raw.githubusercontent.com/BarthPaleologue/WebTide/master/src/shaders/horizontalStepIfft.wgsl
- Vertical IFFT: https://raw.githubusercontent.com/BarthPaleologue/WebTide/master/src/shaders/verticalStepIfft.wgsl
- Twiddle factors: https://raw.githubusercontent.com/BarthPaleologue/WebTide/master/src/shaders/twiddleFactors.wgsl
- Permutation: https://raw.githubusercontent.com/BarthPaleologue/WebTide/master/src/shaders/permutation.wgsl
- Water vertex (GLSL): https://raw.githubusercontent.com/BarthPaleologue/WebTide/master/src/shaders/waterMaterial/vertex.glsl
- Water fragment (GLSL): https://raw.githubusercontent.com/BarthPaleologue/WebTide/master/src/shaders/waterMaterial/fragment.glsl

### Gerstner Wave Reference

**CaffeineViking/osgw** — Definitive Gerstner wave implementation with tessellation. Based on GPU Gems.
- Core Gerstner functions: https://raw.githubusercontent.com/CaffeineViking/osgw/master/share/shaders/gerstner.glsl
- Vertex shader: https://raw.githubusercontent.com/CaffeineViking/osgw/master/share/shaders/gerstner.vert
- Fragment shader: https://raw.githubusercontent.com/CaffeineViking/osgw/master/share/shaders/gerstner.frag
- Tessellation control: https://raw.githubusercontent.com/CaffeineViking/osgw/master/share/shaders/gerstner.tesc
- Tessellation eval: https://raw.githubusercontent.com/CaffeineViking/osgw/master/share/shaders/gerstner.tese
- Lighting: https://raw.githubusercontent.com/CaffeineViking/osgw/master/share/shaders/lighting.glsl

### FFT Ocean (Non-WGSL but Best Quality)

**GarrettGunnell/Water (Acerola)** — Most complete FFT ocean. JONSWAP, 4-cascade, Jacobian foam.
- Compute shader: https://raw.githubusercontent.com/GarrettGunnell/Water/main/Assets/Shaders/FFTWater.compute
- Render shader: https://raw.githubusercontent.com/GarrettGunnell/Water/main/Assets/Shaders/FFTWater.shader

**2Retr0/GodotOceanWaves** — Clean GLSL FFT with JONSWAP/TMA, Hasselmann spreading, 8-cascade PBR.
- Spectrum compute: https://raw.githubusercontent.com/2Retr0/GodotOceanWaves/main/assets/shaders/compute/spectrum_compute.glsl
- FFT butterfly: https://raw.githubusercontent.com/2Retr0/GodotOceanWaves/main/assets/shaders/compute/fft_butterfly.glsl
- FFT compute: https://raw.githubusercontent.com/2Retr0/GodotOceanWaves/main/assets/shaders/compute/fft_compute.glsl
- Water surface: https://raw.githubusercontent.com/2Retr0/GodotOceanWaves/main/assets/shaders/spatial/water.gdshader

**tessarakkt/godot4-oceanfft** — Godot 4 FFT ocean with PBR surface.
- Initial spectrum: https://raw.githubusercontent.com/tessarakkt/godot4-oceanfft/devel/addons/tessarakkt.oceanfft/shaders/InitialSpectrum.glsl
- FFT horizontal: https://raw.githubusercontent.com/tessarakkt/godot4-oceanfft/devel/addons/tessarakkt.oceanfft/shaders/FFTHorizontal.glsl
- Surface visual: https://raw.githubusercontent.com/tessarakkt/godot4-oceanfft/devel/addons/tessarakkt.oceanfft/shaders/SurfaceVisual.gdshader

### Shadertoy (GLSL, browser-viewable)

- **Seascape by TDM** — Perlin noise ocean with ray marching, immersive lighting: https://www.shadertoy.com/view/Ms2SD1
- **Physically-based ocean** — Procedural with proper Fresnel/specular: https://www.shadertoy.com/view/MdXyzX

### Godot Shader Gallery (inline source on page)

- Gerstner Wave Ocean: https://godotshaders.com/shader/gerstner-wave/
- Volumetric Ocean Waves: https://godotshaders.com/shader/volumetric-ocean-waves/
- Absorption-Based Stylized Water: https://godotshaders.com/shader/absorption-based-stylized-water/
- Realistic Water with Reflection/Refraction: https://godotshaders.com/shader/realistic-water-with-traced-and-simple-reflection-and-refraction-v2/

## Key Academic References

- **Tessendorf (2001)**: "Simulating Ocean Water" — Foundation of all modern ocean rendering. [PDF](https://jtessen.people.clemson.edu/reports/papers_files/coursenotes2004.pdf)
- **GPU Gems Ch.1 (2004)**: Effective Water Simulation — Two-level Gerstner approach. [NVIDIA](https://developer.nvidia.com/gpugems/gpugems/part-i-natural-effects/chapter-1-effective-water-simulation-physical-models)
- **Dupuy et al.**: Real-time Animation and Rendering of Ocean Whitecaps. [PDF](https://liris.cnrs.fr/Documents/Liris-5812.pdf)
- **Darles et al. (2011)**: Survey of Ocean Simulation and Rendering. [arXiv](https://arxiv.org/abs/1109.6494)
- **Ubisoft La Forge (2024)**: Making Waves — Hexagonal tiling for aperiodic oceans. [Paper](https://www.ubisoft.com/en-us/studio/laforge/news/5WHMK3tLGMGsqhxmWls1Jw)
