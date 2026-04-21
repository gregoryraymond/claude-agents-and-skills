---
name: geometry-blender-mesh-debug
description: Guide for debugging terrain and coastline GLB meshes using Blender's Python API in headless mode. Covers vertex color inspection, UV analysis, degenerate triangle detection, mesh health reports, and visual debugging techniques.
user-invocable: true
allowed-tools: Read, Grep, Bash, Edit, Write, Glob
---

# Blender Mesh Debug Guide

Blender 4.0.2 is installed at `/usr/bin/blender`. All scripts run headless via `blender --background`.

## Project GLB Files

- `crates/europe-zone-control/assets/models/coastline_lod0.glb` — Full resolution terrain (~2M verts, ~4M polys)
- `crates/europe-zone-control/assets/models/coastline_lod1.glb` — Reduced LOD

The terrain mesh object is named `Mesh_0`. It has:
- **Vertex colors**: Attribute `Col`, domain=CORNER, data_type=BYTE_COLOR
- **UVs**: Layer `UVMap`, domain=CORNER, data_type=FLOAT2
- A `Cube` object also exists in the file (8 verts) — ignore it.

---

## 1. Loading GLB Files (Headless)

```bash
blender --background --python-expr "
import bpy
bpy.ops.import_scene.gltf(filepath='path/to/file.glb')
for obj in bpy.data.objects:
    if obj.type == 'MESH':
        print(f'{obj.name}: {len(obj.data.vertices)} verts, {len(obj.data.polygons)} polys')
"
```

To run a Python script file instead:

```bash
blender --background --python /path/to/script.py
```

Pass arguments after `--`:

```bash
blender --background --python script.py -- /path/to/file.glb
```

Access them in the script with:
```python
import sys
argv = sys.argv[sys.argv.index("--") + 1:]
glb_path = argv[0]
```

---

## 2. Headless Mesh Inspection (Quick Summary)

Print vertex count, triangle count, bounding box, attribute names, and vertex color ranges.

```python
#!/usr/bin/env python3
"""Run: blender --background --python this_script.py -- /path/to/file.glb"""
import bpy
import sys
from mathlib import Vector

# Parse args
argv = sys.argv[sys.argv.index("--") + 1:]
glb_path = argv[0]

# Clear scene and import
bpy.ops.wm.read_homefile(use_empty=True)
bpy.ops.import_scene.gltf(filepath=glb_path)

for obj in bpy.data.objects:
    if obj.type != 'MESH':
        continue
    me = obj.data
    if len(me.vertices) < 100:
        continue  # skip placeholder objects

    print(f"\n=== {obj.name} ===")
    print(f"Vertices:  {len(me.vertices)}")
    print(f"Polygons:  {len(me.polygons)}")
    print(f"Loops:     {len(me.loops)}")
    print(f"Edges:     {len(me.edges)}")
    tri_count = sum(len(p.vertices) - 2 for p in me.polygons)
    print(f"Triangles: {tri_count}")

    # Bounding box
    xs = [v.co.x for v in me.vertices]
    ys = [v.co.y for v in me.vertices]
    zs = [v.co.z for v in me.vertices]
    print(f"Bounding box:")
    print(f"  X: [{min(xs):.4f}, {max(xs):.4f}]")
    print(f"  Y: [{min(ys):.4f}, {max(ys):.4f}]")
    print(f"  Z: [{min(zs):.4f}, {max(zs):.4f}]")

    # All attributes
    print(f"Attributes ({len(me.attributes)}):")
    for a in me.attributes:
        if not a.name.startswith('.'):
            print(f"  {a.name}: domain={a.domain}, type={a.data_type}")

    # Color attributes
    print(f"Color attributes ({len(me.color_attributes)}):")
    for c in me.color_attributes:
        print(f"  {c.name}: domain={c.domain}, type={c.data_type}")

    # UV layers
    print(f"UV layers ({len(me.uv_layers)}):")
    for u in me.uv_layers:
        print(f"  {u.name}")
```

---

## 3. Checking Vertex Colors

Blender 4.0 stores vertex colors as **color attributes** (not the legacy `vertex_colors`). For this project, the attribute is named `Col` with domain `CORNER` and type `BYTE_COLOR`.

### Print min/max/average per RGBA channel

```python
"""Run: blender --background --python this_script.py -- /path/to/file.glb"""
import bpy, sys
import numpy as np

argv = sys.argv[sys.argv.index("--") + 1:]
bpy.ops.wm.read_homefile(use_empty=True)
bpy.ops.import_scene.gltf(filepath=argv[0])

for obj in bpy.data.objects:
    if obj.type != 'MESH' or len(obj.data.vertices) < 100:
        continue
    me = obj.data

    for ca in me.color_attributes:
        print(f"\n=== Color Attribute: {ca.name} (domain={ca.domain}, type={ca.data_type}) ===")
        n = len(ca.data)
        colors = np.zeros(n * 4, dtype=np.float32)
        ca.data.foreach_get("color", colors)
        colors = colors.reshape(n, 4)

        for ch, name in enumerate(["R", "G", "B", "A"]):
            col = colors[:, ch]
            print(f"  {name}: min={col.min():.4f}  max={col.max():.4f}  "
                  f"mean={col.mean():.4f}  std={col.std():.4f}")

        # Count loops with alpha < 0.5 (cliff-textured)
        low_alpha = np.sum(colors[:, 3] < 0.5)
        print(f"  Loops with alpha < 0.5: {low_alpha} / {n} ({100*low_alpha/n:.1f}%)")

        # Count loops with blue > 0.7 (potential ocean bleed)
        blue_high = np.sum((colors[:, 2] > 0.7) & (colors[:, 0] < 0.3))
        print(f"  Loops with blue>0.7 & red<0.3 (ocean bleed?): {blue_high}")
```

### Vertex color histogram by alpha bucket

```python
# Add after the per-channel stats above:
buckets = [0, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1.01]
alpha = colors[:, 3]
print("  Alpha histogram:")
for i in range(len(buckets) - 1):
    count = np.sum((alpha >= buckets[i]) & (alpha < buckets[i+1]))
    print(f"    [{buckets[i]:.1f}, {buckets[i+1]:.1f}): {count}")
```

---

## 4. Checking UVs

### Report UV bounds and detect degenerate UVs

```python
"""Run: blender --background --python this_script.py -- /path/to/file.glb"""
import bpy, sys
import numpy as np

argv = sys.argv[sys.argv.index("--") + 1:]
bpy.ops.wm.read_homefile(use_empty=True)
bpy.ops.import_scene.gltf(filepath=argv[0])

for obj in bpy.data.objects:
    if obj.type != 'MESH' or len(obj.data.vertices) < 100:
        continue
    me = obj.data

    for uv_layer in me.uv_layers:
        print(f"\n=== UV Layer: {uv_layer.name} ===")
        n = len(uv_layer.data)
        uvs = np.zeros(n * 2, dtype=np.float32)
        uv_layer.data.foreach_get("uv", uvs)
        uvs = uvs.reshape(n, 2)

        print(f"  U: min={uvs[:,0].min():.6f}  max={uvs[:,0].max():.6f}")
        print(f"  V: min={uvs[:,1].min():.6f}  max={uvs[:,1].max():.6f}")

        # Detect all-same UV (degenerate)
        u_range = uvs[:,0].max() - uvs[:,0].min()
        v_range = uvs[:,1].max() - uvs[:,1].min()
        if u_range < 1e-6 and v_range < 1e-6:
            print("  WARNING: All UVs are identical (degenerate UV map)")

        # UVs outside [0,1]
        outside = np.sum((uvs[:,0] < 0) | (uvs[:,0] > 1) | (uvs[:,1] < 0) | (uvs[:,1] > 1))
        print(f"  UVs outside [0,1]: {outside} / {n} ({100*outside/n:.1f}%)")

        # Per-polygon UV area check (degenerate triangles in UV space)
        degen_uv_count = 0
        for poly in me.polygons:
            loop_uvs = [uvs[li] for li in range(poly.loop_start, poly.loop_start + poly.loop_total)]
            if poly.loop_total == 3:
                a, b, c = loop_uvs
                area = abs((b[0]-a[0])*(c[1]-a[1]) - (c[0]-a[0])*(b[1]-a[1])) * 0.5
                if area < 1e-10:
                    degen_uv_count += 1
        print(f"  Degenerate UV triangles (zero UV area): {degen_uv_count}")
```

---

## 5. Finding Degenerate Triangles, Flipped Normals, Non-Manifold Edges

Uses BMesh for robust topology analysis.

```python
"""Run: blender --background --python this_script.py -- /path/to/file.glb"""
import bpy, bmesh, sys
from mathlib import Vector

argv = sys.argv[sys.argv.index("--") + 1:]
bpy.ops.wm.read_homefile(use_empty=True)
bpy.ops.import_scene.gltf(filepath=argv[0])

for obj in bpy.data.objects:
    if obj.type != 'MESH' or len(obj.data.vertices) < 100:
        continue
    print(f"\n=== Topology Analysis: {obj.name} ===")

    bm = bmesh.new()
    bm.from_mesh(obj.data)
    bm.faces.ensure_lookup_table()
    bm.edges.ensure_lookup_table()
    bm.verts.ensure_lookup_table()

    # Zero-area faces
    zero_area = [f for f in bm.faces if f.calc_area() < 1e-8]
    print(f"Zero-area faces: {len(zero_area)}")
    if zero_area:
        for f in zero_area[:10]:
            print(f"  Face {f.index}: area={f.calc_area():.2e}, "
                  f"center={f.calc_center_median()}")

    # Non-manifold edges (not shared by exactly 2 faces, or boundary)
    non_manifold = [e for e in bm.edges if not e.is_manifold]
    boundary = [e for e in non_manifold if e.is_boundary]
    wire = [e for e in non_manifold if e.is_wire]
    other_nm = [e for e in non_manifold if not e.is_boundary and not e.is_wire]
    print(f"Non-manifold edges: {len(non_manifold)}")
    print(f"  Boundary edges: {len(boundary)}")
    print(f"  Wire edges (no faces): {len(wire)}")
    print(f"  Other non-manifold: {len(other_nm)}")

    # Flipped normals — faces whose normal points opposite to neighbors
    flipped_count = 0
    for face in bm.faces:
        for neighbor in face.edges:
            linked = neighbor.link_faces
            if len(linked) == 2:
                other = linked[0] if linked[1] == face else linked[1]
                if face.normal.dot(other.normal) < -0.5:
                    flipped_count += 1
                    break
    print(f"Potentially flipped faces (normal opposes neighbor): {flipped_count}")

    # Loose vertices (not part of any edge)
    loose_verts = [v for v in bm.verts if not v.link_edges]
    print(f"Loose vertices: {len(loose_verts)}")

    # Duplicate vertices (same position, different index)
    from collections import defaultdict
    pos_map = defaultdict(list)
    for v in bm.verts:
        key = (round(v.co.x, 6), round(v.co.y, 6), round(v.co.z, 6))
        pos_map[key].append(v.index)
    dupes = {k: v for k, v in pos_map.items() if len(v) > 1}
    print(f"Duplicate vertex positions: {len(dupes)} groups, {sum(len(v)-1 for v in dupes.values())} extra verts")

    bm.free()
```

---

## 6. Visual Debugging (With Display)

These require a running X display. From SSH, set DISPLAY and XAUTHORITY first:

```bash
export XAUTHORITY=$(ls /run/user/1000/.mutter-Xwaylandauth.*)
export DISPLAY=:0
```

### Face Orientation Overlay (blue = front, red = back)

In Blender UI: Viewport Overlays dropdown (top-right of 3D viewport) -> check "Face Orientation".

Via Python (in a non-background Blender session):
```python
import bpy
# Enable face orientation overlay
for area in bpy.context.screen.areas:
    if area.type == 'VIEW_3D':
        area.spaces[0].overlay.show_face_orientation = True
```

### Wireframe Display Mode

```python
import bpy
for area in bpy.context.screen.areas:
    if area.type == 'VIEW_3D':
        area.spaces[0].shading.type = 'WIREFRAME'
```

### Vertex Color Display Mode

```python
import bpy
for area in bpy.context.screen.areas:
    if area.type == 'VIEW_3D':
        shading = area.spaces[0].shading
        shading.type = 'SOLID'
        shading.color_type = 'VERTEX'
```

### Normal Visualization (face and vertex normals)

```python
import bpy
obj = bpy.context.active_object
bpy.ops.object.mode_set(mode='EDIT')
# In the Overlays panel:
for area in bpy.context.screen.areas:
    if area.type == 'VIEW_3D':
        overlay = area.spaces[0].overlay
        overlay.show_face_normals = True
        overlay.normals_length = 0.5
        # For vertex normals:
        overlay.show_vertex_normals = True
```

### Render a headless screenshot with vertex colors visible

```python
"""Run with display: DISPLAY=:0 blender --python this_script.py -- file.glb output.png"""
import bpy, sys

argv = sys.argv[sys.argv.index("--") + 1:]
glb_path, output_path = argv[0], argv[1]

bpy.ops.wm.read_homefile(use_empty=True)
bpy.ops.import_scene.gltf(filepath=glb_path)

# Set viewport to vertex color
for area in bpy.context.screen.areas:
    if area.type == 'VIEW_3D':
        shading = area.spaces[0].shading
        shading.type = 'SOLID'
        shading.color_type = 'VERTEX'

# Set render output
bpy.context.scene.render.filepath = output_path
bpy.context.scene.render.resolution_x = 1920
bpy.context.scene.render.resolution_y = 1080
bpy.ops.render.opengl(write_still=True)
```

---

## 7. Mesh Statistics in Edit Mode

Blender's Edit Mode has a Statistics overlay showing vert/edge/face/tri counts. Enable via:

```python
import bpy
for area in bpy.context.screen.areas:
    if area.type == 'VIEW_3D':
        area.spaces[0].overlay.show_stats = True
```

For headless analysis, the Python scripts above provide equivalent data.

---

## 8. Isolating Problem Areas (Select by Attribute Value)

### Select all vertices below a Y threshold

```python
"""Select verts with Y < threshold. Run interactively or save selection to vertex group."""
import bpy, bmesh

obj = bpy.context.active_object
bpy.ops.object.mode_set(mode='EDIT')
bm = bmesh.from_edit_mesh(obj.data)

threshold = -0.2  # Change as needed
bpy.ops.mesh.select_all(action='DESELECT')
for v in bm.verts:
    if v.co.y < threshold:
        v.select = True

bm.select_flush_mode()
bmesh.update_edit_mesh(obj.data)
print(f"Selected {sum(1 for v in bm.verts if v.select)} vertices with Y < {threshold}")
```

### Select vertices by vertex color alpha range (headless, prints indices)

```python
"""Run: blender --background --python this_script.py -- file.glb 0.0 0.5"""
import bpy, sys
import numpy as np

argv = sys.argv[sys.argv.index("--") + 1:]
glb_path = argv[0]
alpha_min, alpha_max = float(argv[1]), float(argv[2])

bpy.ops.wm.read_homefile(use_empty=True)
bpy.ops.import_scene.gltf(filepath=glb_path)

for obj in bpy.data.objects:
    if obj.type != 'MESH' or len(obj.data.vertices) < 100:
        continue
    me = obj.data
    ca = me.color_attributes.get("Col")
    if not ca:
        continue

    n = len(ca.data)
    colors = np.zeros(n * 4, dtype=np.float32)
    ca.data.foreach_get("color", colors)
    colors = colors.reshape(n, 4)

    # Map loop indices back to vertex indices
    loop_to_vert = np.zeros(len(me.loops), dtype=np.int32)
    me.loops.foreach_get("vertex_index", loop_to_vert)

    mask = (colors[:, 3] >= alpha_min) & (colors[:, 3] <= alpha_max)
    vert_indices = set(loop_to_vert[mask])
    print(f"Vertices with alpha in [{alpha_min}, {alpha_max}]: {len(vert_indices)}")

    # Print bounding box of selected vertices
    if vert_indices:
        positions = np.zeros(len(me.vertices) * 3, dtype=np.float32)
        me.vertices.foreach_get("co", positions)
        positions = positions.reshape(-1, 3)
        sel = positions[list(vert_indices)]
        print(f"  X: [{sel[:,0].min():.4f}, {sel[:,0].max():.4f}]")
        print(f"  Y: [{sel[:,1].min():.4f}, {sel[:,1].max():.4f}]")
        print(f"  Z: [{sel[:,2].min():.4f}, {sel[:,2].max():.4f}]")
```

---

## 9. Comparing LODs

Load both LOD0 and LOD1 and compare vertex counts, bounding boxes, and attribute presence.

```python
"""Run: blender --background --python this_script.py -- lod0.glb lod1.glb"""
import bpy, sys

argv = sys.argv[sys.argv.index("--") + 1:]
lod0_path, lod1_path = argv[0], argv[1]

def analyze_glb(path, label):
    bpy.ops.wm.read_homefile(use_empty=True)
    bpy.ops.import_scene.gltf(filepath=path)
    print(f"\n=== {label}: {path} ===")
    for obj in bpy.data.objects:
        if obj.type != 'MESH' or len(obj.data.vertices) < 100:
            continue
        me = obj.data
        print(f"  Object: {obj.name}")
        print(f"  Vertices: {len(me.vertices)}")
        print(f"  Polygons: {len(me.polygons)}")
        tri_count = sum(len(p.vertices) - 2 for p in me.polygons)
        print(f"  Triangles: {tri_count}")
        xs = [v.co.x for v in me.vertices]
        ys = [v.co.y for v in me.vertices]
        zs = [v.co.z for v in me.vertices]
        print(f"  Bounds X: [{min(xs):.4f}, {max(xs):.4f}]")
        print(f"  Bounds Y: [{min(ys):.4f}, {max(ys):.4f}]")
        print(f"  Bounds Z: [{min(zs):.4f}, {max(zs):.4f}]")
        attrs = [a.name for a in me.attributes if not a.name.startswith('.')]
        print(f"  Attributes: {attrs}")
        return len(me.vertices), len(me.polygons)
    return 0, 0

v0, p0 = analyze_glb(lod0_path, "LOD0")
v1, p1 = analyze_glb(lod1_path, "LOD1")

if v0 and v1:
    print(f"\n=== Comparison ===")
    print(f"Vertex ratio (LOD1/LOD0): {v1/v0:.3f}")
    print(f"Polygon ratio (LOD1/LOD0): {p1/p0:.3f}")
```

**Quick one-liner for this project:**
```bash
blender --background --python compare_lods.py -- \
  crates/europe-zone-control/assets/models/coastline_lod0.glb \
  crates/europe-zone-control/assets/models/coastline_lod1.glb
```

---

## 10. Common Terrain Mesh Issues Visible in Blender

| Issue | How to spot | Blender tool/technique |
|---|---|---|
| **Holes in mesh** | Missing faces, can see through terrain | Face Orientation overlay (no color = missing face) |
| **Flipped faces** | Red faces in Face Orientation overlay | Select face, Mesh > Normals > Recalculate Outside |
| **Disconnected vertices** | Loose verts not attached to any face | Select All > Mesh > Clean Up > Delete Loose |
| **Overlapping faces** | Z-fighting flicker, face count too high | Select All > Mesh > Clean Up > Merge by Distance |
| **T-junctions** | Vertex on an edge without being connected | Non-manifold edge selection (Ctrl+Shift+Alt+F) |
| **Spike/needle triangles** | Long thin triangles, spikes poking out | Sort by face area, inspect smallest/largest |
| **UV seams** | Visible texture discontinuities | UV Editor: check for island gaps/overlaps |
| **Vertex color discontinuity** | Abrupt color changes at polygon boundaries | Solid mode with Vertex color display |
| **Beach/cliff boundary gaps** | Missing geometry between beach slope and cliff wall | Isolate vertices near Y=-0.25 (ocean surface level) |

---

## 11. Exporting a JSON Mesh Health Report

Complete script that outputs a JSON report suitable for automated CI or diff comparisons.

```python
"""
Mesh health report as JSON.
Run: blender --background --python mesh_report.py -- input.glb output.json
"""
import bpy, bmesh, sys, json
import numpy as np

argv = sys.argv[sys.argv.index("--") + 1:]
glb_path = argv[0]
output_path = argv[1] if len(argv) > 1 else None

bpy.ops.wm.read_homefile(use_empty=True)
bpy.ops.import_scene.gltf(filepath=glb_path)

report = {"file": glb_path, "meshes": []}

for obj in bpy.data.objects:
    if obj.type != 'MESH' or len(obj.data.vertices) < 100:
        continue

    me = obj.data
    mesh_report = {"name": obj.name}

    # Basic counts
    mesh_report["vertex_count"] = len(me.vertices)
    mesh_report["polygon_count"] = len(me.polygons)
    mesh_report["edge_count"] = len(me.edges)
    mesh_report["loop_count"] = len(me.loops)
    mesh_report["triangle_count"] = sum(len(p.vertices) - 2 for p in me.polygons)

    # Bounding box via numpy
    positions = np.zeros(len(me.vertices) * 3, dtype=np.float32)
    me.vertices.foreach_get("co", positions)
    positions = positions.reshape(-1, 3)
    mesh_report["bounds"] = {
        "x": [float(positions[:,0].min()), float(positions[:,0].max())],
        "y": [float(positions[:,1].min()), float(positions[:,1].max())],
        "z": [float(positions[:,2].min()), float(positions[:,2].max())],
    }

    # Attributes
    mesh_report["attributes"] = [
        {"name": a.name, "domain": a.domain, "data_type": a.data_type}
        for a in me.attributes if not a.name.startswith('.')
    ]

    # Vertex color stats
    color_stats = {}
    for ca in me.color_attributes:
        n = len(ca.data)
        colors = np.zeros(n * 4, dtype=np.float32)
        ca.data.foreach_get("color", colors)
        colors = colors.reshape(n, 4)
        color_stats[ca.name] = {
            "domain": ca.domain,
            "data_type": ca.data_type,
            "channels": {}
        }
        for ch, name in enumerate(["r", "g", "b", "a"]):
            col = colors[:, ch]
            color_stats[ca.name]["channels"][name] = {
                "min": float(col.min()),
                "max": float(col.max()),
                "mean": float(col.mean()),
                "std": float(col.std()),
            }
        color_stats[ca.name]["low_alpha_count"] = int(np.sum(colors[:, 3] < 0.5))
        color_stats[ca.name]["ocean_bleed_count"] = int(
            np.sum((colors[:, 2] > 0.7) & (colors[:, 0] < 0.3))
        )
    mesh_report["color_attributes"] = color_stats

    # UV stats
    uv_stats = {}
    for uv_layer in me.uv_layers:
        n = len(uv_layer.data)
        uvs = np.zeros(n * 2, dtype=np.float32)
        uv_layer.data.foreach_get("uv", uvs)
        uvs = uvs.reshape(n, 2)
        uv_stats[uv_layer.name] = {
            "u_range": [float(uvs[:,0].min()), float(uvs[:,0].max())],
            "v_range": [float(uvs[:,1].min()), float(uvs[:,1].max())],
            "outside_01_count": int(np.sum(
                (uvs[:,0] < 0) | (uvs[:,0] > 1) | (uvs[:,1] < 0) | (uvs[:,1] > 1)
            )),
        }
    mesh_report["uv_layers"] = uv_stats

    # Topology analysis via BMesh
    bm = bmesh.new()
    bm.from_mesh(me)
    bm.faces.ensure_lookup_table()
    bm.edges.ensure_lookup_table()
    bm.verts.ensure_lookup_table()

    zero_area = [f for f in bm.faces if f.calc_area() < 1e-8]
    non_manifold = [e for e in bm.edges if not e.is_manifold]
    boundary = [e for e in non_manifold if e.is_boundary]
    wire = [e for e in non_manifold if e.is_wire]
    loose = [v for v in bm.verts if not v.link_edges]

    # Flipped normals
    flipped = 0
    for face in bm.faces:
        for edge in face.edges:
            linked = edge.link_faces
            if len(linked) == 2:
                other = linked[0] if linked[1] == face else linked[1]
                if face.normal.dot(other.normal) < -0.5:
                    flipped += 1
                    break

    mesh_report["topology"] = {
        "zero_area_faces": len(zero_area),
        "non_manifold_edges": len(non_manifold),
        "boundary_edges": len(boundary),
        "wire_edges": len(wire),
        "loose_vertices": len(loose),
        "flipped_faces": flipped,
    }

    # Face area distribution
    areas = np.array([f.calc_area() for f in bm.faces])
    mesh_report["face_area_stats"] = {
        "min": float(areas.min()),
        "max": float(areas.max()),
        "mean": float(areas.mean()),
        "median": float(np.median(areas)),
        "std": float(areas.std()),
    }

    bm.free()
    report["meshes"].append(mesh_report)

# Output
report_json = json.dumps(report, indent=2)
if output_path:
    with open(output_path, 'w') as f:
        f.write(report_json)
    print(f"Report written to {output_path}")
else:
    print(report_json)
```

**Usage:**
```bash
# Print to stdout
blender --background --python mesh_report.py -- \
  crates/europe-zone-control/assets/models/coastline_lod0.glb

# Write to file
blender --background --python mesh_report.py -- \
  crates/europe-zone-control/assets/models/coastline_lod0.glb \
  /tmp/mesh_report.json
```

---

## 12. Quick Reference: One-Liner Commands

```bash
# Count vertices and polygons
blender --background --python-expr "
import bpy; bpy.ops.import_scene.gltf(filepath='FILE.glb')
for o in bpy.data.objects:
 if o.type=='MESH': print(f'{o.name}: {len(o.data.vertices)}v {len(o.data.polygons)}p')
"

# List all attributes
blender --background --python-expr "
import bpy; bpy.ops.import_scene.gltf(filepath='FILE.glb')
for o in bpy.data.objects:
 if o.type=='MESH':
  for a in o.data.attributes:
   if not a.name.startswith('.'): print(f'{o.name}.{a.name}: {a.domain} {a.data_type}')
"

# Check if mesh has vertex colors
blender --background --python-expr "
import bpy; bpy.ops.import_scene.gltf(filepath='FILE.glb')
for o in bpy.data.objects:
 if o.type=='MESH': print(f'{o.name}: {len(o.data.color_attributes)} color attrs')
"

# Bounding box
blender --background --python-expr "
import bpy; bpy.ops.import_scene.gltf(filepath='FILE.glb')
for o in bpy.data.objects:
 if o.type=='MESH' and len(o.data.vertices)>100:
  bb=o.bound_box; xs=[b[0] for b in bb]; ys=[b[1] for b in bb]; zs=[b[2] for b in bb]
  print(f'{o.name}: X[{min(xs):.3f},{max(xs):.3f}] Y[{min(ys):.3f},{max(ys):.3f}] Z[{min(zs):.3f},{max(zs):.3f}]')
"
```

---

## 13. Project-Specific Notes

- The terrain mesh `Mesh_0` has ~2M vertices and ~4M polygons at LOD0. BMesh operations on it take 10-30 seconds.
- Vertex color attribute `Col` uses `BYTE_COLOR` type (0-1 float range, stored as bytes). The alpha channel controls cliff vs satellite texture blending in the terrain shader.
- Low alpha (< 0.5) means cliff texture dominates. High alpha (> 0.85) means satellite texture. See the "Blue Satellite Texture Bleeding Fix" section in CLAUDE.md for the full alpha-to-blend mapping.
- The `BEACH_BASE_Y` is -0.35, ocean surface is at Y=-0.25, `CLIFF_BASE_Y` is -0.2. Vertices between -0.35 and -0.25 are in the submerged beach zone.
- When investigating coastline artifacts, focus on vertices near Y=-0.25 (ocean surface) and check their vertex color alpha values.
- `foreach_get` is dramatically faster than Python-level iteration for large meshes. Always use numpy + `foreach_get` for the terrain mesh.
