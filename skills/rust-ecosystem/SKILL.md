---
name: rust-ecosystem
description: "Rust crate ecosystem, Cargo, features, workspaces, and FFI. Use for E0425 / E0433 / E0603, choosing a crate (serde, tokio, reqwest, axum, sqlx, clap, tracing, anyhow, thiserror, …), designing feature flags, workspace layout, or integrating with C / C++ / Python / Node / WASM via bindgen / cbindgen / pyo3 / napi-rs / wasm-bindgen."
user-invocable: false
---

# Rust Ecosystem & Cargo

## Default crate picks

When in doubt, these are the community defaults. Reach for something else only if you have a reason.

| Need | Default crate |
|---|---|
| Serialization | `serde` + one of `serde_json`, `bincode`, `rmp-serde`, `toml`, `serde_yaml` |
| Async runtime | `tokio` (features: `rt-multi-thread`, `macros`, `net`, `fs`, ...) |
| HTTP client | `reqwest` |
| HTTP server | `axum` (tower-based, modern). `actix-web` is a fine alternative. |
| gRPC | `tonic` |
| SQL (async, compile-checked) | `sqlx` |
| SQL (sync, ORM) | `diesel` |
| CLI parsing | `clap` (derive macros) |
| Structured logging | `tracing` + `tracing-subscriber` |
| Errors — library | `thiserror` |
| Errors — app | `anyhow` |
| UUIDs | `uuid` |
| Time | `time` or `chrono` (time is newer, narrower) |
| Regex | `regex` |
| Hashmap w/ faster hash | `ahash`, `rustc-hash` |
| Small vectors | `smallvec` |
| Dates/duration parsing | `humantime` |
| Testing assertions | `assert2`, `pretty_assertions`, `insta` (snapshot) |
| Property testing | `proptest`, `quickcheck` |
| Randomness | `rand`, `rand_chacha` |

## Choosing a crate

Quick screen before adopting a new dependency:

- **Recent activity** — last commit / release inside 6 months (exceptions: genuinely finished crates).
- **Downloads / reverse-deps** — high numbers don't prove quality, but very low ones are a flag.
- **API docs** — examples on `docs.rs`, not just rustdoc stubs.
- **Transitive footprint** — `cargo tree -e normal` on a test project; a 2-line feature shouldn't pull 40 deps.
- **MSRV** — does the crate's minimum-supported Rust version fit your target?
- **License** — MIT/Apache-2.0 is the norm; flag GPL for commercial products.

## Cargo features

```toml
# Cargo.toml
[features]
default = ["tls"]
tls = ["dep:rustls", "dep:rustls-pemfile"]
sqlite = ["dep:rusqlite"]
postgres = ["dep:tokio-postgres"]

[dependencies]
rustls = { version = "0.23", optional = true }
rustls-pemfile = { version = "2", optional = true }
rusqlite = { version = "0.31", optional = true }
tokio-postgres = { version = "0.7", optional = true }
```

- Use `dep:<crate>` in feature lists to avoid the implicit feature-named-after-a-dep behaviour.
- Features should be **additive** — enabling more features must never *remove* functionality. Users can unify features across the dependency graph.
- Test the matrix: `cargo hack --feature-powerset check`.

## Workspaces

```toml
# top-level Cargo.toml
[workspace]
resolver = "2"
members = ["crates/*", "bin/*"]

[workspace.package]
edition = "2024"
rust-version = "1.85"
license = "MIT OR Apache-2.0"

[workspace.dependencies]
serde = { version = "1", features = ["derive"] }
tokio = { version = "1", features = ["full"] }
```

- `resolver = "2"` is required for modern feature unification (and is default for 2021+ editions on new workspaces).
- `[workspace.dependencies]` + `{ workspace = true }` in member crates keeps versions consistent.
- Per-crate `Cargo.toml` should reference workspace-level packages: `edition.workspace = true`, etc.

## Common errors

| Error | Cause | Fix |
|---|---|---|
| **E0433** (unresolved module) | Crate not declared, or wrong feature | Add to `[dependencies]`, or enable the needed feature |
| **E0432** (unresolved import) | Item exists but isn't `pub` along that path | Check the crate's re-export structure on docs.rs |
| **E0603** (private item) | Item is `pub(crate)` / `pub(super)` only | Use the documented public path |
| **E0425** (not found) | Often: trait in scope missing | `use <crate>::<Trait>;` |
| `feature X not found` | Typo or feature removed in newer version | Check `cargo add --help`'s suggestion or docs.rs for the version |
| Duplicate types at link time | Two versions of the same crate in the graph | `cargo tree -d` to find duplicates; unify in workspace |
| Version conflict | Two deps want incompatible versions | Upgrade the older one, or open an upstream issue |

## FFI integration

| Direction | Tool | Notes |
|---|---|---|
| C/C++ headers → Rust bindings | `bindgen` | Usually used from `build.rs`. See `unsafe-checker` for safety. |
| Rust → C ABI header | `cbindgen` | Export a `extern "C"` API and generate `.h` |
| Rust ↔ Python | `pyo3` + `maturin` | `pyo3` is the dominant binding; `maturin` builds the wheel |
| Rust ↔ Node.js | `napi-rs` | Modern N-API; `neon` is older |
| Rust → WebAssembly | `wasm-bindgen` + `wasm-pack` (browser), or `cargo build --target wasm32-wasi` (WASI) | Choose based on runtime |

All `extern "C"` / unsafe FFI code needs a `// SAFETY:` comment justifying why each invariant holds. See the `unsafe-checker` skill for invariant-by-invariant review.

## Anti-patterns

- `extern crate foo;` in 2018+ editions — redundant.
- `#[macro_use] extern crate foo;` — use explicit `use foo::the_macro;` imports.
- Wildcard versions (`foo = "*"`) — reproducibility goes out the window.
- Vendoring everything you depend on — only justified for truly hostile build environments (air-gapped, audit).
- Adding a huge crate for one function — consider copying the function (with attribution) or finding a smaller crate.
- Leaving `anyhow` as a *public* return type in a library crate — you've forced it on every downstream user.
- Feature flags that *remove* behavior — breaks feature unification.
- Not running `cargo tree -d` when the build suddenly doubles in size.

## Quick commands

```bash
cargo add tokio --features macros,rt-multi-thread
cargo tree -e normal          # only runtime deps
cargo tree -d                 # show duplicate versions
cargo tree -i <crate>         # who depends on this?
cargo outdated                # (cargo-outdated) what can be bumped
cargo deny check              # license / advisory / sources policy
cargo hack check --feature-powerset  # feature matrix
cargo update -p <crate>       # bump only one crate
```
