---
name: rust-ownership
description: "Rust ownership, borrowing, lifetimes, smart pointers, mutability, and resource lifecycle. Use when diagnosing borrow-checker errors (E0382, E0499, E0502, E0506, E0507, E0515, E0596, E0597, E0716, E0106) or deciding between Box / Rc / Arc / Cell / RefCell / Mutex / RwLock / Weak / Cow, or implementing RAII / Drop / OnceLock / LazyLock / pool patterns."
user-invocable: false
---

# Rust Ownership, Borrowing & Resource Lifecycle

Covers four closely-related concerns: ownership/lifetimes, smart pointers, interior mutability, and resource lifecycle. The first question is almost always **"who owns this, for how long, and who is allowed to mutate it?"** — not "which type silences the error."

## Borrow-checker errors

| Error | Cause | First thing to check |
|---|---|---|
| **E0382** | Use of moved value | Does the caller still need the value? If yes → `&T`. If it's genuinely shared → `Arc<T>` / `Rc<T>`. `.clone()` last. |
| **E0597** | Reference outlives referent | The scope is wrong somewhere — usually the owner needs to live longer, not the reference shorter. |
| **E0506** | Assign while borrowed | End the borrow (smaller scope) or move the mutation elsewhere. |
| **E0507** | Move out of borrowed | Clone, take via `Option::take` / `mem::replace`, or pass by reference. |
| **E0515** | Returning reference to local | Return owned value, or take a reference parameter and tie lifetimes. |
| **E0716** | Temporary dropped | Bind the temporary to a `let` first. Usually a `.lock()` or builder result. |
| **E0106** | Missing lifetime | Pick the lifetime that matches real data flow; don't reflexively add `'a` to everything. |
| **E0596** | Mutate through `&` | Add `mut` to the binding, or reach for interior mutability only if you can't restructure. |
| **E0499** | Two `&mut` at once | Split the data (two fields → two borrows) or shrink the scopes. |
| **E0502** | `&mut` while `&` exists | Separate the borrow lifetimes. Frequently a hint the function should take owned data. |

> Rule of thumb: if you've hit the same error three times in a row, the design is wrong, not the annotations.

## Ownership quick reference

| Pattern | Semantics | Cost | Use when |
|---|---|---|---|
| Move | Transfer ownership | zero | Caller is done with the value |
| `&T` | Shared borrow | zero | Read-only access |
| `&mut T` | Exclusive borrow | zero | Need to mutate without giving ownership |
| `T: Copy` | Duplicate bitwise | zero | Small POD (integers, small structs) |
| `.clone()` | Deep duplicate | alloc + copy | You genuinely need an independent value |
| `Cow<'a, T>` | Borrow, clone on mutation | alloc only if mutated | Sometimes borrowed, sometimes owned |

## Smart pointers

| Type | Ownership | Thread-safe | Use when |
|---|---|---|---|
| `Box<T>` | single | Send/Sync if `T` is | Heap allocation, recursive types, trait objects |
| `Rc<T>` | shared | **no** | Single-threaded shared ownership |
| `Arc<T>` | shared | yes | Multi-threaded shared ownership |
| `Weak<T>` | non-owning | matches Rc/Arc | Break reference cycles (parent ← child) |

### Decision flow

```
heap? ── no ─→ stack (default)
   │
   yes
   │
single owner? ── yes ─→ Box<T>
   │
   no (shared)
   │
crosses threads? ── no ─→ Rc<T>
   │
   yes ─→ Arc<T>

cycles? ── yes ─→ one direction as Weak<T>
```

### Shared mutable state

| Context | Pattern |
|---|---|
| Single-thread, `T: !Copy` | `Rc<RefCell<T>>` |
| Single-thread, `T: Copy` | `Rc<Cell<T>>` |
| Multi-thread, general | `Arc<Mutex<T>>` |
| Multi-thread, read-heavy | `Arc<RwLock<T>>` |
| Multi-thread, simple counters/flags | `AtomicUsize` / `AtomicBool` |

## Interior mutability

The borrow rules still apply — `RefCell` / `Mutex` just move the check to runtime.

```
At any time you have either
    many  &T       (shared, read-only)
or
    one   &mut T   (exclusive)
— never both.
```

| Type | Check | Cost | Use when |
|---|---|---|---|
| `Cell<T>` | compile-time (for Copy) | zero | Small `Copy` fields, no references handed out |
| `RefCell<T>` | runtime (panics) | counter ops | Non-Copy, needs runtime-borrowed access |
| `Mutex<T>` | runtime (blocks) | lock | Thread-safe exclusive access |
| `RwLock<T>` | runtime (blocks) | lock | Read-heavy, thread-safe |
| `Atomic*` | lock-free | minimal | Simple primitives |

If `RefCell::borrow_mut` panics, the answer is almost never `try_borrow_mut` — it's that two code paths are reaching the same cell at once. Restructure.

## Resource lifecycle

### RAII / Drop

Prefer RAII over manual `close()` / `cleanup()`. Put cleanup in `Drop::drop`:

```rust
struct TempFile { path: PathBuf }
impl Drop for TempFile {
    fn drop(&mut self) { let _ = std::fs::remove_file(&self.path); }
}
```

Gotchas:
- `Drop` cannot return `Result`. If cleanup can fail meaningfully, expose an explicit `close(self) -> Result<_>` and keep `Drop` as a best-effort fallback.
- Moving out of a `Drop` type needs `Option::take` or `mem::replace` (E0509).
- `Drop` order within a scope is reverse declaration order; within a struct it's declaration order.

### Lazy init (prefer std over external crates)

```rust
use std::sync::OnceLock;
static CONFIG: OnceLock<Config> = OnceLock::new();
fn config() -> &'static Config {
    CONFIG.get_or_init(|| Config::load().expect("config required"))
}
```

- `OnceLock<T>` — thread-safe, set once, no closure stored.
- `LazyLock<T, F>` — thread-safe, closure runs on first access. Replaces `once_cell::sync::Lazy` and the `lazy_static!` macro.
- `OnceCell` / `LazyCell` — single-thread equivalents.

### Connection pools

Use `deadpool` (async) or `r2d2` (sync). Both give you an `Arc<Pool>`-shaped handle; the `Connection` returned is a guard that returns itself to the pool on `Drop`. Never `forget` a pool connection — it leaks a slot.

### Guard / scope patterns

Anything that needs a "do X on exit" hook becomes a small struct with `Drop`. Common examples: `MutexGuard`, transaction guards, span guards (tracing), cursor restores.

## Anti-patterns

- **`.clone()` to silence the compiler.** Almost always hides the real ownership question.
- **`Arc` everywhere on a single thread.** Use `Rc`. Atomic RMW is not free.
- **`RefCell` everywhere.** Usually means the data structure should be split.
- **`'static` as a default bound.** Restricts callers; use the shortest lifetime that works.
- **`Box::leak` for "convenience."** It's a permanent leak. Use `OnceLock` / `LazyLock`.
- **`lazy_static!` in new code.** Use `OnceLock` / `LazyLock` from std.
- **Mutex inside a hot loop.** Batch work per lock acquisition.
- **Mutual `Rc` cycles** without a `Weak` edge. Guaranteed leak.

## When to escalate

| Symptom | Likely real problem |
|---|---|
| Same borrow error after 3 rewrites | Data structure is wrong shape — split it, or change ownership direction |
| `Send`/`Sync` not satisfied in async | See `rust-concurrency` — usually a `Rc`/`RefCell` on a `.await` boundary |
| Lots of `Arc<Mutex<_>>` | Consider message passing (channels) instead of shared state |
| Lifetimes getting labyrinthine | Probably want owned data + clone-on-write, not more `'a` parameters |
