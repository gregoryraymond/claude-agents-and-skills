---
name: texture-debugging
description: Expert guide for diagnosing and fixing texturing problems in Bevy 0.15 / wgpu / WGSL / glTF workflows. Apply when a texture isn't showing, appears on the wrong mesh, colors look washed-out / over-saturated, or per-instance tinting bleeds between entities. Covers the glTF scene-graph traps, shared-material bugs, sRGB pitfalls, and RenderDoc-driven investigation.
user-invocable: true
allowed-tools: Read, Grep, Bash, Edit, Write, Agent, WebSearch, WebFetch
---

# Texture Debugging Guide

Practical field guide for texture problems in this Bevy project. Battle-tested against real bugs we have hit in this codebase (e.g. the spartan shield inheriting the armor texture via name propagation; the shield tint bleeding between army instances via shared `StandardMaterial` mutation).

Before diving in, always triage with **"is the asset wrong, or is our code wrong?"**. The fastest way is to drop the GLB into Don McCurdy's viewer — if it looks correct there but wrong in-engine, the bug is ours.

## Fast triage: three visual bugs, three decision trees

### "My texture is on the wrong mesh / wrong part of the model"

1. Load the GLB in https://gltf-viewer.donmccurdy.com/ and confirm materials are assigned to the expected primitives **in the file itself**. If the file is wrong, fix it in Blender — no amount of code will rescue a bad export.
2. Run https://github.khronos.org/glTF-Validator/ on the file — catches silent corruption and missing UVs.
3. If the file is right, the bug is in our Bevy scene walk. See **§1 "glTF hierarchy traps"** below. Log `(entity_name, parent_chain, material_handle_id)` for every mesh entity — mismatches jump out immediately.
4. Check for shared-handle mutation (see **§2**) — the texture might have been loaded correctly and overwritten post-load.

### "My texture isn't showing at all"

1. Is the asset loaded? Check `AssetServer::get_load_state(handle)`.
2. Does the entity actually have a `MeshMaterial3d<StandardMaterial>`? Missing component = default gray material.
3. Does the mesh have UVs? Open in the McCurdy viewer; meshes without UVs render flat.
4. Is the bind group correct? Launch in RenderDoc, F12 to capture, inspect **Pipeline State** for the draw call — confirm the texture handle is bound.
5. Is the mesh behind the camera / culled / at alpha 0? Sample the texture directly in RenderDoc's Texture Viewer.

### "Colors look washed-out / over-saturated / pastel / crunchy"

Almost always sRGB / linear confusion (**§4**). Steps:
1. Confirm the texture format matches content: color (albedo, emissive) = `Rgba8UnormSrgb`; data (normal, roughness, metallic, masks) = `Rgba8Unorm`.
2. Disable tonemapping (`Tonemapping::None` on the camera) — see the raw linear output.
3. Disable bloom / post-processing when debugging color.
4. For a custom loader: you own sRGB correction. The default Bevy glTF loader handles this; custom loaders often don't.

## §1 — glTF hierarchy traps (the `shield1 → Weapon` problem)

**The trap we fell into:** Bevy's glTF loader creates a separate entity for every node in the scene graph. When a grouping node like `Weapon` contains `shield1` and `spear1` as children, and we recurse down propagating names to descendants via `entry().or_insert_with(...)` (first-writer-wins), the grouping parent's name stamps itself onto every mesh entity underneath. `shield1` and `spear1` never win against their parent. The mesh ends up classified as `"Weapon"`, matches the catch-all arm of the `spartan_tex_group` match, and receives the armor texture.

**General rule:** classify at the primitive level, not the ancestor level. Several options:

- **Skip grouping parents explicitly.** Add them to a skip list so they don't propagate. This is what we did in `crates/europe-zone-control/src/game/army.rs` (`apply_spartan_textures`) — nodes like `"Weapon"`, `"Armor"`, `"Head"`, `"Hair"`, `"Eyes"`, `"warrior"` are skipped so the real part names (`shield1`, `spear1`, `Head1`, `Body3`) reach the mesh.
- **Deep-win instead of shallow-win.** Iterate descendants in reverse / BFS-to-leaf order and use `insert` instead of `or_insert_with`, so the closest (deepest) named ancestor dominates.
- **Use the `Gltf` asset API** rather than walking the spawned scene. It gives structured access to primitives with their material handles preserved:

```rust
fn classify_via_gltf(
    gltf_handle: Handle<Gltf>,
    gltfs: Res<Assets<Gltf>>,
    gltf_meshes: Res<Assets<GltfMesh>>,
) {
    let Some(gltf) = gltfs.get(&gltf_handle) else { return; };
    for (name, mesh_handle) in &gltf.named_meshes {
        let Some(gltf_mesh) = gltf_meshes.get(mesh_handle) else { continue; };
        for primitive in &gltf_mesh.primitives {
            // primitive.mesh: Handle<Mesh>
            // primitive.material: Option<Handle<StandardMaterial>>
            // use `name` + primitive index as a stable identifier
        }
    }
}
```

- **Name Blender materials semantically** (`mat_shield`, `mat_spear_shaft`) and match on *material name*, not node name. Requires exporting materials with real names, not "Placeholder".

**Debug recipe for this class of bug:**

```rust
// Drop this into any system that has a scene root + name/material queries.
fn debug_dump_scene(
    scene_q: Query<Entity, With<Handle<Scene>>>,
    children: Query<&Children>,
    names: Query<&Name>,
    mats: Query<&MeshMaterial3d<StandardMaterial>>,
) {
    for root in &scene_q {
        let mut stack = vec![(root, String::new())];
        while let Some((e, path)) = stack.pop() {
            let nm = names.get(e).map(|n| n.as_str()).unwrap_or("<unnamed>");
            let full = if path.is_empty() { nm.to_string() } else { format!("{path}/{nm}") };
            let mat = mats.get(e).ok().map(|m| format!("{:?}", m.0.id()));
            if mat.is_some() { info!("{full} -> mat={:?}", mat); }
            if let Ok(ch) = children.get(e) {
                for &c in ch { stack.push((c, full.clone())); }
            }
        }
    }
}
```

Output tells you exactly which entity chain owns each material handle. Compare against expectations.

## §2 — Shared-material bugs (the shield-color-bleeds problem)

**The trap we fell into:** `spartan.glb` loads once; every `SceneRoot` instance holds handles that point to the **same** `StandardMaterial` assets. Inside a tint pass doing `materials.get_mut(&mat_handle.0)` and setting `base_color = state.tint` mutates the shared material — every other spartan instance immediately inherits that tint. Last-writer-wins. Symptom: own shield and enemy shield are both the player's color; marching unit is red until encamping respawns the scene.

**Fix:** clone the material per scene instance *before* mutating.

```rust
// Tintable (per-owner) branch:
let Some(original) = materials.get(&mat_handle.0).cloned() else { continue };
let mut cloned = original;
cloned.base_color = state.tint;
let new_handle = materials.add(cloned);
commands.entity(d).insert(MeshMaterial3d(new_handle));
```

This is what we did in `army.rs::apply_spartan_textures`. The textured branches (armor / body / head / weapon) still share their materials — all owners want the same texture, so sharing is fine and actually desirable (fewer materials, better batching).

**When you do NOT want to clone:**
- The modification is meant to affect every instance (e.g. a one-shot cleanup of metallic/roughness for all city towers — see `node_rendering.rs::fix_tower_materials`).
- You have 500 enemies all the same color — clone once up-front per team, not per entity.

**Rule of thumb:** one material asset = one visual identity. 50 units with subtly different tints either need 50 materials, or a custom material with a per-instance uniform, or a vertex-color tint on per-entity mesh instances. Not one shared asset mutated 50 times per frame.

**Detection heuristic:** if you see visual state bleed between "identical" entities, the first hypothesis should be shared-handle mutation. Log `mat_handle.0.id()` alongside entity id — same asset id across multiple entities + in-place mutation = bug.

## §3 — Investigation tools in priority order

### RenderDoc (the gold standard)
- https://renderdoc.org/
- Launch the game through RenderDoc, F12 to capture a frame.
- **Texture Viewer:** every bound texture, format, mip chain. Find the one you are debugging, eyeball the pixels. If the texture itself looks wrong, the bug is upstream (loader / Blender / export).
- **Pipeline State per draw call:** confirms which textures, samplers, and bind groups are actually bound at the moment a specific primitive rendered. This is the only way to definitively answer "is the right texture on the right draw call".
- Works on Linux with Vulkan backend out of the box.

### Don McCurdy's glTF viewer
- https://gltf-viewer.donmccurdy.com/
- Drop a `.glb` in, see the scene graph, materials, textures. First stop for any "is my asset right?" question. Eliminates half of all texture bugs as authoring issues in under a minute.

### gltf-validator
- https://github.khronos.org/glTF-Validator/
- Machine-readable validity check. Good to run in CI against committed GLBs.

### bevy_inspector_egui
- https://github.com/jakobhellermann/bevy-inspector-egui
- Live entity / component / asset inspection in the running game. Lets you mutate material fields and see the result immediately — great for sampling acceptable values before baking them into code.

### wgpu validation
- `RUST_LOG=wgpu=warn cargo run -p europe-zone-control` catches binding-group / pipeline-layout / format mismatches early. Vulkan validation layers (`VK_INSTANCE_LAYERS=VK_LAYER_KHRONOS_validation`) add another tier.

### In-shader visualizers (cheap, always-available)

```wgsl
// UVs as color — should be a smooth gradient
return vec4<f32>(in.uv.x, in.uv.y, 0.0, 1.0);

// World-space normals as RGB — a sphere should look like the classic RGB ball
return vec4<f32>(normalize(in.world_normal) * 0.5 + 0.5, 1.0);

// Tangents (for normal mapping)
return vec4<f32>(in.world_tangent.xyz * 0.5 + 0.5, 1.0);
```

UV-as-color catches the most bugs. Solid colors = collapsed UVs. Black patches = UVs outside [0,1] with CLAMP sampler. Seams visible as discontinuities = atlas boundary issues.

## §4 — WGSL / wgpu texturing gotchas

### sRGB vs linear (the #1 washed-out-colors culprit)
- `Rgba8UnormSrgb` → GPU does sRGB→linear on sample. Use for **color** (albedo, emissive).
- `Rgba8Unorm` → no conversion. Use for **data** (normal, roughness, metallic, mask).
- Double-correction symptom: pastel washed-out look. You are sampling a linear-interpreted image that is actually sRGB.
- Missing-correction symptom: crunchy over-saturated look. You are doing linear math on sRGB-encoded pixels.
- In Bevy: `StandardMaterial::base_color_texture` expects sRGB; `normal_map_texture` and metallic-roughness expect linear. The default glTF loader gets this right. Custom loaders must set the sRGB flag explicitly.
- Reference: https://learnopengl.com/Advanced-Lighting/Gamma-Correction

### Sampler filter and address modes
- `FilterMode::Nearest` for pixel art / Synty-style palette atlases — linear filtering bleeds across stripes.
- `AddressMode::ClampToEdge` for atlases (prevents bleed from neighbouring tiles). Repeat is for tiling textures.
- **Atlas bleed** at tile edges: either clamp, or inset UVs by half a texel (`0.5 / atlas_width`).

### Alpha premultiplication
- Dark halos around semi-transparent foliage / cloth = premultiplication mismatch. `AlphaMode::Blend` vs `AlphaMode::Premultiplied` — try the other one.

### Binding layout mismatches
- wgpu is strict. `@group(2) @binding(3) var tex: texture_2d<f32>;` must match the bind group layout *exactly*, including visibility stages. Read the wgpu error text, it names the offending binding.

### Depth texture reads
- `texture_depth_2d` requires a comparison sampler and `textureSampleCompare`. Mixing with `texture_2d<f32>` is a common error when porting shaders.

## §5 — Workflow techniques

### Palette-atlas textures (Synty / Kenney style)
- Tiny colormap PNG (e.g. 128x128) of vertical color stripes. Every material UVs into the right stripe.
- What our city models (`models/city.glb`, `models/capital.glb`) use — see `node_rendering.rs`.
- Pros: one draw call per model set, tiny VRAM, instant recolor by swapping the palette texture.
- Cons: no surface detail, requires `FilterMode::Nearest` or inset UVs.
- Swap the palette texture at runtime = instant team-color / seasonal reskin.

### Vertex colors for per-instance tint
- Store tint in `Mesh::ATTRIBUTE_COLOR`. Shader multiplies into albedo. Zero extra textures, no shared-material problems. Cost: one mesh per tint.

### Detail textures
- Multiply a low-frequency albedo by a tiling high-frequency detail at close range. Fakes 4K textures without shipping them.

### Triplanar mapping (UV bailout)
- When UVs are broken / missing / procedural (cliffs, marching-cubes terrain): sample three times per world axis, blend by normal.
- https://catlikecoding.com/unity/tutorials/advanced-rendering/triplanar-mapping/ (Unity but math is identical in WGSL).

## §6 — Project-specific gotchas to check first

These are bugs we have actually hit in this codebase. Check them before debugging from first principles.

- **`apply_spartan_textures` in `army.rs`**: grouping parent nodes (`Weapon`, `Armor`, `Head`, `Hair`, `Eyes`, `warrior`) are skipped in the name-propagation pass. If you add a new spartan model variant, make sure you skip its grouping nodes too — run the scene-graph dump in §1 to identify them.
- **Per-owner tinting**: the tintable branch in `apply_spartan_textures` *must* clone the material. If you add a new per-owner visual (e.g. banner trim, helmet plume), it needs its own cloned material or its own entity with its own `StandardMaterial`.
- **City banners** (`node_rendering.rs::spawn_node_markers`): each banner gets a fresh `materials.add(...)`. Do not simplify to a shared banner material or all cities flicker to the same color.
- **`fix_tower_materials`** *intentionally* mutates the shared tower material — all towers want the same metallic=0/reflectance=0.2 cleanup. Resist the urge to "fix" this to clone per-tower; it is correct.
- **Palette atlas on cities**: uses `FilterMode::Nearest` via the Blender export. If a new city model ships with linear filtering it will show color bleed between stripes — re-export with nearest-neighbour.

## §7 — Canonical references (open these before debugging, not after)

- Bevy Cheatbook — Materials: https://bevy-cheatbook.github.io/3d/materials.html
- Bevy Cheatbook — Asset Handles: https://bevy-cheatbook.github.io/assets/handles.html
- Learn wgpu: https://sotrh.github.io/learn-wgpu/
- WGSL spec: https://www.w3.org/TR/WGSL/
- glTF 2.0 spec: https://registry.khronos.org/glTF/specs/2.0/glTF-2.0.html
- LearnOpenGL gamma correction: https://learnopengl.com/Advanced-Lighting/Gamma-Correction
- LearnOpenGL normal mapping: https://learnopengl.com/Advanced-Lighting/Normal-Mapping
- Catlike Coding triplanar: https://catlikecoding.com/unity/tutorials/advanced-rendering/triplanar-mapping/
- Inigo Quilez articles (texture sampling, filtering): https://iquilezles.org/articles/
- RenderDoc docs: https://renderdoc.org/docs/
- Bevy examples — 3D rendering: https://bevyengine.org/examples/3d-rendering/
- Bevy Discord #rendering channel — highest-quality real-time help

## §8 — RenderDoc workflow for agent-driven debugging

RenderDoc is the single highest-leverage tool for pinpointing texturing bugs. For an AI agent it is even more useful than for a human, because RenderDoc exposes a **Python API over captured frames** — a frame capture becomes a queryable database, and the agent can write short scripts to ask precise questions: "which textures were sampled at pixel (x,y)?", "what draws touched this pixel?", "give me the fragment shader that ran for this draw and export the bound albedo texture to PNG".

The user presses F12 to save a `.rdc` file. The agent runs Python scripts against it. Agent never needs the GUI.

### Install (Ubuntu 24.04 — our environment)

RenderDoc is not in apt or snap for this distro; use the official static Linux tarball.

```bash
# One-time install, user-local:
mkdir -p ~/tools && cd ~/tools
curl -LO https://renderdoc.org/stable/1.36/renderdoc_1.36.tar.gz
tar xzf renderdoc_1.36.tar.gz
# Binaries are in ~/tools/renderdoc_1.36/bin/
# Python API is in ~/tools/renderdoc_1.36/ (lib + python bindings)

# Add to PATH (append to ~/.bashrc):
export PATH="$HOME/tools/renderdoc_1.36/bin:$PATH"
# And for the Python bindings (needed for headless scripting):
export PYTHONPATH="$HOME/tools/renderdoc_1.36:$PYTHONPATH"
export LD_LIBRARY_PATH="$HOME/tools/renderdoc_1.36/lib:$LD_LIBRARY_PATH"
```

Verify: `renderdoccmd --help` and `python3 -c "import renderdoc; print(renderdoc.GetVersionString())"`.

Check https://renderdoc.org/builds for the current stable version number — substitute `1.36` above if a newer one is out.

### Capturing a frame

Two ways:

1. **GUI, interactive** — `qrenderdoc`, File → Launch Application → point at `target/debug/europe-zone-control`. Set `XAUTHORITY=$(ls /run/user/1000/.mutter-Xwaylandauth.*) DISPLAY=:0` first so Xwayland works. Run the game, reproduce the bug, press **F12** to capture. Capture lands in `~/.local/share/renderdoc/` as `<binary_name>_<timestamp>.rdc`.

2. **CLI, agent-friendly** — no GUI needed, spawns the binary, F12 key triggers capture. Capture path logged to stdout.

```bash
XAUTHORITY=$(ls /run/user/1000/.mutter-Xwaylandauth.*) DISPLAY=:0 \
renderdoccmd capture -d /tmp/rdc target/debug/europe-zone-control -- --view
# User presses F12 in the window. Captures written to /tmp/rdc/<binary>_<timestamp>.rdc.
```

Scripted capture (press F12 programmatically after N frames) is also supported via `renderdoccmd capture --opt CaptureAllCmdLists --wait-for-debugger` — but the usual flow is "user reproduces, hits F12, hands the `.rdc` path to the agent".

### Agent-driven queries — the Python API

The `renderdoc` Python module loads `.rdc` files headlessly. Core pattern:

```python
#!/usr/bin/env python3
"""Open an .rdc capture and enumerate the draw calls that wrote to a given pixel."""
import sys, renderdoc as rd, json

rdc_path = sys.argv[1]
px_x, px_y = int(sys.argv[2]), int(sys.argv[3])

cap = rd.OpenCaptureFile()
status = cap.OpenFile(rdc_path, "rdc", None)
assert status == rd.ResultCode.Succeeded, status

ctrl = cap.OpenCapture(rd.ReplayOptions(), None)
try:
    # Jump to the last action (final frame state) then pixel-history the target.
    actions = ctrl.GetRootActions()
    last = actions[-1]
    while last.children:
        last = last.children[-1]
    ctrl.SetFrameEvent(last.eventId, False)

    target_id = ctrl.GetTargetBuffers()[0]   # final backbuffer
    history = ctrl.PixelHistory(target_id, px_x, px_y, rd.Subresource(), rd.CompType.Typeless)

    out = []
    for h in history:
        action = ctrl.GetAction(h.eventId)
        out.append({
            "eventId": h.eventId,
            "action": action.customName or action.GetName(ctrl.GetStructuredFile()),
            "pre_color":  [h.preMod.col.floatValue[i]  for i in range(4)],
            "shader_out": [h.shaderOut.col.floatValue[i] for i in range(4)],
            "post_color": [h.postMod.col.floatValue[i] for i in range(4)],
            "depth_test": str(h.depthTestFailed),
            "shader_discarded": h.shaderDiscarded,
        })
    print(json.dumps(out, indent=2))
finally:
    ctrl.Shutdown()
    cap.Shutdown()
```

Run: `python3 pixel_history.py /tmp/rdc/capture.rdc 640 360`. Returns JSON listing every draw that touched that pixel, with pre-shader / shader-output / post-blend colors and depth-test outcome. This is the gold-standard answer to "why does this pixel look wrong" — pre/post values at every stage, automatically.

### Common agent queries (recipes)

Each is a ~20-line Python script over the same capture file. Add these to `scripts/rdc/` as needed.

- **"What textures were bound at eventId N?"** — `ctrl.GetPipelineState().GetReadOnlyResources(rd.ShaderStage.Pixel)`; iterate, print `Name()` + `ResourceId`, cross-reference against `ctrl.GetResource(rid)` for texture dimensions/format.
- **"Export all bound textures at eventId N as PNGs so I can look at them"** — `ctrl.SaveTexture(rd.TextureSave(resourceId=..., destType=rd.FileType.PNG, ...), "/tmp/tex.png")`. The agent can then `Read` those PNGs as images.
- **"What was the UV at pixel (x,y) for the last draw?"** — pixel-history → last event → `ctrl.DebugPixel(x, y, rd.DebugPixelInputs())` returns a `ShaderDebugTrace`; walk the trace to find the `uv` varying's value at the fragment entry.
- **"Show me the fragment shader source for the draw that wrote this pixel"** — from pixel-history grab the eventId → `ctrl.GetPipelineState().GetShaderReflection(rd.ShaderStage.Pixel).rawBytes` or `.entryPoint`, then `ctrl.GetDebugMessages()` / `reflection.debugInfo.files` for the disassembled WGSL.
- **"List every draw that used texture asset X"** — walk `ctrl.GetRootActions()` recursively, for each action `ctrl.SetFrameEvent(action.eventId, False)` then `GetReadOnlyResources()`, filter by resource id.

### Integrating with this project

Add `scripts/rdc/` to the repo with the common recipes above. Pattern for the agent:

1. User reports a rendering bug and describes the pixel / area.
2. User reproduces the bug in the game while running under `renderdoccmd capture` (or just under the `qrenderdoc` GUI if manual).
3. User saves the capture and pastes the path into the chat.
4. Agent runs the relevant `scripts/rdc/*.py` with that path and the pixel coordinates, gets structured JSON, reasons about the result.
5. Agent extracts textures / shader source as PNGs / text files into `/tmp/` and `Read`s them for visual inspection.

This turns RenderDoc into a tool Claude can drive autonomously — no GUI interaction needed for the agent, just the `.rdc` file.

### When RenderDoc is the wrong tool

- **Reproducing on-demand (no single frame matters)**: if the bug only appears over time or across many frames, in-game instrumentation (§7.3 storage buffer) is better.
- **Machines without a GPU or display**: the capture must be made on a graphics-capable machine; replay can be headless but capture cannot.
- **Bugs in headless renderers / `ai-arena`**: there is no frame to capture. Use logs + the pixel picker (planning/pixel_picker_investigation.md §2) in a minimal rendering harness.

### Sources and further reading

- Install: https://renderdoc.org/builds
- CLI reference: https://renderdoc.org/docs/how/how_capture_log.html
- Python API reference: https://renderdoc.org/docs/python_api/renderdoc/index.html
- Pixel history: https://renderdoc.org/docs/window/pixel_history.html
- Shader debugging: https://renderdoc.org/docs/how/how_debug_shader.html
- Replay controller: https://renderdoc.org/docs/python_api/renderdoc/replaycontroller.html

## §9 — Hard-won lessons (the short list)

1. **Always view the GLB in the McCurdy viewer before debugging in-engine.** Eliminates 50% of "wrong texture" bugs as authoring issues.
2. **Name Blender materials semantically.** Names are your only anchor in a scene walk.
3. **Never mutate a shared `StandardMaterial` in place** unless the mutation should affect every instance. Clone first.
4. **Match texture formats to content:** sRGB for color, Unorm for data.
5. **UV-as-color is your best friend.** When a texture looks weird, visualize UVs first — half the time the UVs are the problem, not the texture.
6. **RenderDoc beats `println`.** Time spent learning RenderDoc's Pipeline State panel pays back 10x.
7. **One material asset = one visual identity.** 50 units with different tints need 50 materials OR a per-instance uniform, not one shared asset mutated 50 times.
8. **Disable post-processing when debugging color.** Tonemapping + bloom + exposure hide the truth.
9. **Classify at the primitive, not the ancestor.** Grouping nodes lie.
10. **When two "identical" entities behave differently, suspect shared-handle mutation first.**
