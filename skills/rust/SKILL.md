---
name: rust
description: Guide for Rust development including code style, testing, building, and quality checks using cargo tools. Apply when working with Rust code, Cargo.toml, or running cargo commands.
user-invocable: true
allowed-tools: Read, Grep, Bash, Edit, Write, Agent, Glob
---

# Rust Development Guide

**Load this skill before writing any Rust code.** Follow every rule below. Violations create tech debt that compounds.

---

## Quality Gate: Every Change Must Pass

Before considering any Rust change done, run these checks. Fix all issues before presenting work to the user.

```bash
# 1. Build — must succeed with zero errors
cargo check --workspace

# 2. Clippy — must produce zero warnings and zero errors
cargo clippy --workspace -- -D warnings

# 3. Tests — all must pass
cargo test -p europe-zone-control --lib
cargo test -p lobby-server

# 4. Format check (don't auto-format files you didn't touch)
cargo fmt -- --check
```

If clippy or tests fail, fix the issues. Do not present code that doesn't pass these checks.

---

## No Warnings Policy

**Zero warnings in code you write or modify.** This means:

- No `unused_variables`, `unused_imports`, `dead_code`, `unused_mut` warnings
- No clippy warnings of any severity
- If you add a function, it must be called. If you add an import, it must be used.
- Remove dead code — don't comment it out, don't leave it "for later"

### `#[allow(...)]` Rules

**Do not add `#[allow(dead_code)]`, `#[allow(unused)]`, or any other suppression attribute** unless ALL of the following are true:

1. The code genuinely needs to exist (e.g., a struct field required by a serialization format, an enum variant used in pattern matching but not constructed yet)
2. You can explain WHY in a comment on the same line
3. There is no reasonable way to restructure to avoid the warning

Bad (never do this):
```rust
#[allow(dead_code)]
fn some_helper() { ... }  // "might need it later"
```

Good (rare, justified):
```rust
#[allow(dead_code)]  // Sidecar binary format requires this field
pub(crate) terrain_vertex_count: usize,
```

### Existing `#[allow(...)]` in the Codebase

The codebase has some existing `#[allow(dead_code)]` annotations. Do not add more. When modifying code near existing ones, evaluate whether the suppression is still needed and remove it if not.

---

## Code Style

### Naming
- `snake_case` for functions, variables, modules
- `CamelCase` for types, traits, enums
- `SCREAMING_SNAKE_CASE` for constants
- Descriptive names — `terrain_vert_count` not `tvc`

### Functions
- Keep functions under ~50 lines. Extract helpers when complexity grows.
- System functions (Bevy) can be longer due to query parameter boilerplate.
- Prefer returning `Result` or `Option`. Use `?` propagation.
- NEVER use `.unwrap()` or `.expect("reason")` except in test code.
- 

### Types
- Use newtypes for domain concepts: `PlayerId(usize)` not bare `usize`
- Derive only what you need. Don't blanket-derive `Clone, Debug, Default` on everything.
- Prefer `&str` over `String` in function parameters when you don't need ownership.

### Error Handling
- `.unwrap()` is acceptable in:
  - Tests
- Everywhere else, handle cascade errors upwards so that they are either handled at the correct point, or cause the game to exit through the error bubbling all the way up.

### Imports
- Use `use super::*` or `use crate::` for internal imports
- Group imports: std, external crates, crate-internal
- Remove unused imports immediately

---

## Bevy-Specific Patterns

### Systems
- **System parameter count:** Target **5 parameters or fewer** per system. If a system has **more than 5**, consider using `#[derive(SystemParam)]` bundles to group related parameters. If a system has **10 or more parameters**, you **MUST** refactor using SystemParam bundles — no exceptions. Load the `/ecs` skill for the full SystemParam bundling guide.
- Use `run_if()` conditions to prevent systems from running unnecessarily — don't check conditions inside the system body when a run condition works.
- Prefer `resource_changed::<T>` over checking every frame.
- **Never store frequently-changing state in `GameState`** — it triggers `resource_changed` cascades across many systems. Use a separate resource (see `HoveredCountry` pattern).

### Queries
- Use `With<T>` / `Without<T>` filters to narrow queries
- Add `Without<A>` when a query conflicts with another query in the same system
- Prefer `get_single()` over `.iter().next()` for singleton entities

### Resources
- `Res<T>` for read-only, `ResMut<T>` for mutation
- Only use `ResMut` when you actually need to mutate — it triggers change detection
- `Option<Res<T>>` for resources that may not exist yet

### Commands
- `commands.spawn()` is deferred — the entity won't exist until the next sync point
- When system A spawns entities that system B needs to see, ensure proper ordering with `.after()` / `.before()`

---

## Performance Rules

### Allocations
- Avoid allocating in per-frame systems. Reuse `Vec`s, use `Local<T>` for persistent buffers.
- `meshes.add()` and `materials.add()` allocate GPU resources — don't call them every frame unless you also clean up the old handles.
- Strong `Handle<T>` keeps the asset alive. Dropping the handle queues it for cleanup, but cleanup may be delayed.

### Mesh Operations
- `meshes.get_mut()` marks the mesh as changed, triggering GPU re-upload. Only call when you actually need to modify the mesh.
- Use `RenderAssetUsages::RENDER_WORLD` for read-only GPU meshes to avoid keeping a CPU copy.
- Octahedral normal encoding (`Snorm16x2`) saves 8 bytes/vertex vs `Float32x3`.

### Change Detection
- `resource_changed::<T>` fires when the resource's `DerefMut` is accessed, even if the value didn't actually change. Guard mutations with `if current != new_value` checks.

---

## Workspace Structure

```
crates/
  europe-zone-control/   # Main game (Bevy 0.15)
  lobby-server/           # Axum WebSocket server
  ai-arena/               # Headless AI tournament
```

### Build Commands

```bash
cargo check --workspace              # Fast type check
cargo build -p europe-zone-control    # Build game
cargo build -p lobby-server           # Build server
cargo clippy --workspace             # Lint all crates
cargo test --workspace                # Test all crates
```

### Profiles
- `dev` profile: `opt-level = 1` (playable Bevy), dependencies at `opt-level = 3`
- `release` profile: LTO thin, strip, `opt-level = "s"`, `panic = "abort"`

---

## Common Clippy Lints to Watch For

| Lint | Fix |
|------|-----|
| `approx_constant` | Use `std::f32::consts::PI` not `3.14159` |
| `too_many_arguments` | Use `#[derive(SystemParam)]` bundles (see `/ecs` skill). Target <=5 params, must fix at >=10 |
| `needless_return` | Remove explicit `return` at end of function |
| `single_match` | Use `if let` instead |
| `collapsible_if` | Merge nested `if` conditions |
| `redundant_closure` | Pass function directly: `.map(foo)` not `.map(\|x\| foo(x))` |
| `clone_on_copy` | Don't `.clone()` Copy types |
| `manual_map` | Use `.map()` instead of match-with-Some |
| `unnecessary_unwrap` | Restructure to use `if let` or `?` |

---

## File Size

**Target ~500 lines of code per file.** Files beyond 500 LOC become hard to navigate, review, and reason about. When a file grows past this threshold:

- Extract related logic into a new module (e.g., `game.rs` -> `game/combat.rs`, `game/economy.rs`)
- Move helper functions, constants, or types into dedicated files
- Use the parent module file (`game.rs`) for re-exports and high-level orchestration

This is a guideline, not a hard rule. Some files (e.g., large match statements, generated code, shader bindings) legitimately exceed 500 lines. But if a file is growing because it has multiple responsibilities, split it.

---

## Testing Conventions

- **Inline tests are acceptable for 1-2 simple tests** — a small `#[cfg(test)] mod tests { ... }` at the bottom of a source file is fine for trivial unit tests that are tightly coupled to the code above. Beyond that, extract to the `tests/` directory.
- **All substantial tests live in the `tests/` directory** at the crate root, organized into subfolders by test type:

```text
crates/europe-zone-control/
  tests/
    unit/           # Fast pure-logic tests (no GPU, no network)
      combat.rs
      economy.rs
      ui_update.rs
    integration/    # Tests requiring multiple systems or real Bevy app
      ui_interaction.rs
      hud_alignment.rs
    e2e/            # End-to-end browser/native tests
      ...
```

- Each subfolder maps to a test type (in order of speed/isolation):
  - `tests/unit/` — Pure logic, no Bevy `App`, no GPU. Fast. Runs with `cargo test`.
  - `tests/integration/` — Requires a Bevy `App`, display, or GPU. Runs with `#[ignore]` or a separate test target.
  - `tests/e2e/` — End-to-end tests driving the full native binary via the test bridge (stdin/stdout).
- Test files mirror the source module they cover: `src/game/combat.rs` → `tests/unit/combat.rs`
- Use `#[test]` for fast tests, `#[test] #[ignore]` for tests requiring GPU/display
- Test function names describe what's being verified: `fn coastal_vertex_near_sea_level_is_valid()`

### Visibility for testability

When moving inline tests to `tests/unit/`, the test file can only access `pub` and `pub(crate)` items. If a function needs to be tested but is currently private:

- **Widen it to `pub(crate)`** — this is the accepted trade-off for keeping tests separate. It does not expose the item outside the crate.
- Add a brief comment when the visibility exists solely for testing: `pub(crate) fn file_sha256(...) // pub(crate) for unit tests`

### Migrating existing inline tests

The codebase may have some legacy inline `#[cfg(test)]` blocks with many tests. When you touch a file that has more than 2 inline tests, migrate them to `tests/unit/` as part of the change:

1. Create `tests/unit/<module_name>.rs` (or add to it if it already exists)
2. Move the test functions there, replacing `use super::*` with explicit `use europe_zone_control::...` imports
3. Widen any tested private items to `pub(crate)`
4. Delete the `#[cfg(test)] mod tests` block from the source file
5. Verify tests still pass: `cargo test -p europe-zone-control --lib`

- See `/testing` skill for full test infrastructure reference

---

## DO NOT Rules

1. **Do not add `#[allow(...)]`** - try your hardest to write it a different way
2. **Do not leave unused imports, variables, or functions** — remove them immediately
3. **Do not use `.unwrap()` in production code paths**
4. **Do not skip clippy** — every PR-worthy change must pass `cargo clippy --workspace`
5. **Do not add dependencies without checking** if the functionality exists in std or existing deps
6. **Do not use `unsafe`** — there is no reason for unsafe code in this project
7. **Do not suppress compiler warnings with `#![allow(...)]`** at the crate level
8. **Do not commit code that doesn't compile** — `cargo check --workspace` must pass
9. **Do not add `println!` for debugging** — use `info!`, `warn!`, `error!` from `bevy::log` (or `tracing`)
10. **Do not use `String` where `&str` suffices** — avoid unnecessary allocations
