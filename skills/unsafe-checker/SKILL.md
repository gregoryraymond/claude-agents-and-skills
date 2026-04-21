---
name: unsafe-checker
description: "Rust unsafe code review and FFI. Use for unsafe blocks, raw pointers (*const / *mut), NonNull, MaybeUninit, transmute, extern \"C\", union, #[repr(C)] / #[repr(packed)], static mut, manual Send / Sync impls, CString / CStr / c_char, bindgen / cbindgen / libc, soundness analysis, SAFETY comments, and undefined-behavior audits."
allowed-tools: ["Read", "Grep", "Glob"]
---

# Unsafe Rust Checker

Review and guidance for `unsafe` Rust — soundness, FFI, raw pointers, safe abstractions, and the documentation discipline that makes review possible. The bar is higher here than in safe Rust: the compiler is no longer holding the invariants, so the author and reviewer must.

## When unsafe is legitimate

| Use case | Example |
|---|---|
| FFI | Calling C or exposing C ABI |
| Low-level primitives | Implementing `Vec`, `Arc`, lock-free data structures |
| Measured performance | Safe baseline benchmarked; unsafe wins by a real margin |

**Never valid:** as an escape hatch from the borrow checker. If you're reaching for `unsafe` to shut the compiler up, the data structure is almost always wrong.

## Non-negotiables

Every unsafe site must have both:

```rust
// SAFETY: <why the invariants hold at this call site>
unsafe { /* ... */ }

/// # Safety
/// <what the caller must guarantee>
pub unsafe fn dangerous(/* ... */) { /* ... */ }
```

Plus:

- Unsafe blocks are the **smallest possible scope** — wrap one operation, not a whole function.
- Public APIs **never** expose raw pointers, uninitialized memory, or unsoundness — wrap them.
- Manual `unsafe impl Send`/`Sync` gets extra scrutiny and a multi-line `// SAFETY:` comment.
- Every `transmute` / `static mut` / `*const as *mut` is a red flag for a second reviewer.

## Operation → what must hold

| Operation | Invariants |
|---|---|
| `*ptr` dereference | non-null, aligned, points to valid + initialized memory, memory valid for the duration, no concurrent mutation |
| `&*ptr` / `&mut *ptr` | above, plus aliasing rules (one `&mut` at a time, no `&` while `&mut` live) |
| `transmute::<A, B>` | `size_of::<A>() == size_of::<B>()`, every bit pattern of `A` is a valid `B` |
| `extern "C"` call | signature matches C exactly; ownership of allocated memory documented; panics cannot cross |
| `unsafe impl Send`/`Sync` | type really is thread-safe under the stated contract |
| `static mut` | synchronized (prefer `AtomicT` / `Mutex<T>` / `OnceLock` instead) |
| Union field access | reads only the active variant |

## Clippy lints worth enabling

These directly map to checker rules:

| Lint | Maps to |
|---|---|
| `undocumented_unsafe_blocks` | safety-09 (SAFETY comment) |
| `missing_safety_doc` | safety-10 (`# Safety` docs on pub unsafe fn) |
| `panic_in_result_fn` | safety-01 / ffi-04 (panic safety) |
| `non_send_fields_in_send_ty` | safety-05 (manual Send/Sync) |
| `uninit_assumed_init`, `uninit_vec` | safety-03 / mem-06 (MaybeUninit) |
| `mut_from_ref` | safety-08 (mut return from immut input) |
| `cast_ptr_alignment` | ptr-04 (alignment) |
| `cast_ref_to_mut` | ptr-05 (no `*const → *mut` by cast) |
| `ptr_as_ptr` | ptr-06 (prefer `.cast()`) |
| `unaligned_references` | ffi-11 (packed field refs) |
| `debug_assert_with_mut_call` | safety-11 (use `assert!`, not `debug_assert!`, in unsafe invariants) |

Recommended `Cargo.toml`:

```toml
[lints.rust]
unsafe_op_in_unsafe_fn = "deny"

[lints.clippy]
undocumented_unsafe_blocks = "deny"
missing_safety_doc = "deny"
multiple_unsafe_ops_per_block = "warn"
```

## Deprecated patterns

| Don't | Do |
|---|---|
| `mem::uninitialized()` | `MaybeUninit<T>` |
| `mem::zeroed()` for types with invalid zero | `MaybeUninit<T>` |
| `*const T as *mut T` | Fix the source of mutability; use `UnsafeCell` if truly needed |
| `CString::new(s).unwrap().as_ptr()` in one line | Bind the `CString` first; `.as_ptr()` on a dropped value dangles |
| `static mut` | `AtomicT` / `Mutex<T>` / `OnceLock<T>` / `LazyLock<T>` |
| Hand-rolled `extern` blocks for large C APIs | `bindgen` (with a pinned build-time version) |
| Raw pointer in public API | Safe wrapper (`NonNull<T>` inside, safe methods outside) |

## Red-flag quick scan

When reviewing a diff, greps that find almost every interesting case:

```
unsafe\b           # every unsafe block / fn / impl / trait
transmute          # type punning — always a second look
static\s+mut       # data-race magnet
as\s+\*mut         # aliasing shenanigans
\.set_len\(        # uninitialized-slot exposure
assume_init        # is it actually initialized?
catch_unwind       # panic-boundary code; make sure it's at every extern "C"
#\[repr\(packed    # misaligned reference hazards
```

## Rule index

Detailed rules live in `rules/`. Each cluster file is self-contained — one section per rule with a minimal bad/good example.

| File | Contents |
|---|---|
| `rules/general.md` | Three foundational principles: unsafe is not an escape hatch, not a perf reflex, and must remain visible in API names. |
| `rules/safety.md` | 11 rules for building safe abstractions: SAFETY comments, `# Safety` docs, panic safety, Send/Sync impls, MaybeUninit, never expose raw pointers. |
| `rules/ptr-union.md` | Raw pointer rules (prefer `NonNull`, alignment, no `*const → *mut`, prefer `.cast()`, `PhantomData`) and union rules (avoid outside FFI; no cross-lifetime fields). |
| `rules/mem.md` | Memory-layout rules: `#[repr(...)]`, foreign memory, reentrant syscalls, bitfield crates, `MaybeUninit`. |
| `rules/ffi.md` | 18 FFI rules plus I/O safety — strings, panic boundary, portable types, ownership, layout stability, opaque types, trait-object interop, raw handles. |

## Supporting material

- `checklist.md` — pre-write / review / pitfalls checklists in one place.
- `examples/safe-abstraction.md` — worked examples of wrapping unsafe behind safe APIs.
- `examples/ffi-patterns.md` — worked FFI patterns (strings, callbacks, opaque handles).

## Tools worth running

- **Miri** (`cargo +nightly miri test`) — catches most UB patterns reachable from tests.
- **AddressSanitizer** (`RUSTFLAGS="-Zsanitizer=address"`, nightly) — use-after-free, heap errors.
- **ThreadSanitizer** (`RUSTFLAGS="-Zsanitizer=thread"`, nightly) — data races.
- **`cargo-careful`** — replaces the standard library with one that runs additional debug checks.
- **`cargo-geiger`** — counts unsafe usage across the dependency tree.

Claude already knows unsafe Rust mechanically; the value this skill adds is the **discipline**: SAFETY comments at every block, minimal scope, safe public wrappers, and soundness as a first-class concern in review.
