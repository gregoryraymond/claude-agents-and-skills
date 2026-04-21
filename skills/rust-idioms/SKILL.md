---
name: rust-idioms
description: "Rust idioms, mental models, and anti-patterns. Use when reviewing code for pitfalls (clone-everywhere, unwrap-in-production, fighting the borrow checker, String-for-everything, premature Arc/Rc, manual unsafe), or explaining Rust concepts to someone coming from Java / C++ / Python / JS, or deciding whether a pattern is symptom-chasing vs. a real fix."
user-invocable: false
---

# Rust Idioms & Anti-Patterns

Reference for code review and for explaining *why* Rust wants you to do something. Most "Rust is awkward here" moments resolve by changing the data model, not by adding `.clone()` / `.unwrap()` / `unsafe`.

## Top anti-patterns

| Anti-pattern | What it usually hides | Idiomatic fix |
|---|---|---|
| `.clone()` everywhere | Unclear ownership — nobody decided who owns the data | Pick an owner; pass `&T` / `&mut T` to the rest |
| `.unwrap()` in library / app code | Unhandled failure mode | `?`, or `expect("why this cannot fail")` |
| `Rc` / `Arc` where one owner would do | Reflex, not need | Plain ownership + borrows |
| `Rc<RefCell<T>>` / `Arc<Mutex<T>>` sprinkled everywhere | Shared mutable state is the wrong default | Channels, or split the data so each task owns its piece |
| `String` parameters for read-only text | Forced allocation at every call site | `&str` (or `impl AsRef<str>` / `Cow<'_, str>`) |
| `Vec<T>` parameter for read-only slice | Forced allocation | `&[T]` |
| Index loops (`for i in 0..v.len()`) | C-style thinking | `for x in &v` / `.iter().enumerate()` |
| Boolean state flags (`is_connected`) | State machine pretending not to be one | Type-state (see `rust-types`) |
| `pub` field on invariant-carrying struct | Breaks validation | Private field + validated constructor + accessor |
| `lazy_static!` in new code | Works but outdated | `OnceLock` / `LazyLock` from std |
| `Box::leak` for "I just need a `&'static`" | Permanent leak | `OnceLock` or `LazyLock` |
| Inheritance via `Deref` | Misleading API; method resolution surprises | Composition, extension traits |
| `unsafe` for ergonomics | UB risk | Find the safe pattern; `unsafe` is for things that truly can't be done safely |
| `mem::transmute` for type casts | Almost always UB-adjacent | `as`, `TryFrom`, or `bytemuck::cast` |
| Manual linked list | Fighting the borrow checker for no benefit | `Vec`, `VecDeque`, or `im`/`rpds` persistent structures |

## Mental models that actually fit

- **Ownership is not reference counting.** It's "exactly one name has the authority to drop this value." Moves transfer that authority; borrows temporarily delegate read (`&`) or read+write (`&mut`) access.
- **Lifetimes aren't GC.** They're a static claim: "this reference does not outlive that value." The compiler checks the claim; it doesn't keep anything alive.
- **`&mut` means exclusive, not just mutable.** You can mutate through any owned value; `&mut` is about *no aliasing while I'm writing*.
- **Errors are values.** `Result` is just an enum. `?` is just early-return. `thiserror` / `anyhow` are conveniences, not magic.
- **Traits are not base classes.** They describe capabilities that can be added to any type; no hierarchy, no `super`.
- **Zero-cost abstractions cost at compile time.** Generics monomorphize; lots of bounds + lots of call sites = long builds. `dyn Trait` trades one indirect call for smaller binaries and faster builds.

## Coming from other languages

| From | Biggest shift |
|---|---|
| Java / C# | Values are owned, not heap-by-default. `Box` is the escape hatch, not the norm. No null — use `Option`. |
| C / C++ | The compiler enforces what you were already trying to enforce in code review. No use-after-free, no data races on safe types. |
| Python / JS | No GC — values are dropped deterministically at end of scope. `clone()` is explicit; assignment usually moves. |
| Go | Errors are a sum type, not `(T, error)`. Generics are zero-cost, not interface-boxed. No `nil` — `Option<T>` or `Result<T, E>`. |
| Haskell / OCaml | Lots looks familiar (enums, pattern matching, `?`). The new thing is ownership/lifetimes; purity is not the goal, memory-safety without GC is. |

## Refactoring smells

| Smell | Points to |
|---|---|
| Six `.clone()`s in a short function | Wrong ownership direction. Often the function should take `&self` and return borrowed data. |
| Many `.unwrap()`s in tests | Fine — use `anyhow::Result` in tests and `?` for cleaner bodies. |
| Many `.unwrap()`s in app | Missing error type, or missing early validation at the boundary. |
| Trait-bound soup (`T: Clone + Send + Sync + 'static + Debug`) | Over-generic; try a concrete type. |
| Giant `match` on an enum | Move the behavior into methods on the enum (or a trait impl'd by each variant's payload). |
| Functions > ~50 lines with nested matches | Extract helpers; use `let ... else { return Err(..) };` to flatten. |
| `impl Deref for MyStruct { type Target = Inner; }` to "inherit" API | Use an extension trait or explicit delegation. |

## Quick review checklist

- [ ] No `.clone()` without a comment or obvious need
- [ ] No `.unwrap()` in library or app code (tests & startup are OK with `.expect("reason")`)
- [ ] No `pub` fields on structs with invariants
- [ ] No `String` where `&str` / `impl AsRef<str>` works
- [ ] No `Vec<T>` where `&[T]` works
- [ ] No index loops where an iterator fits
- [ ] No ignored `#[must_use]` warnings
- [ ] Every `unsafe` block has a `// SAFETY:` comment stating the invariant
- [ ] Error variants are distinguishable — no single "Other(String)" catch-all
- [ ] `Rc` / `Arc` / `Mutex` each justified (why shared? why locked?)

## Common compiler errors reframed

| Error | Wrong mental model | Right mental model |
|---|---|---|
| E0382 (use after move) | "The value is still there, GC will clean it up later" | Ownership transferred — the original name no longer has authority |
| E0499 (two `&mut`) | "Multiple writers with locking is fine" | `&mut` means *exclusive*; if you need shared mutation, use interior mutability or split the data |
| E0502 (`&` + `&mut`) | "Readers and one writer is fine" | Not at the same time; shrink the scopes or split the struct |
| E0597 (borrow longer than owner) | "Just extend the lifetime" | The owner has to live longer; lifetimes describe reality, they don't create it |
| E0507 (move out of borrow) | "Rust should just clone it" | You asked for a reference, not ownership — clone explicitly or redesign |
| E0106 (missing lifetime) | "Add `'a` to shut it up" | The compiler can't guess which input the output borrows from — tell it |

## When code is fighting you

Three-strike rule: if the same borrow / lifetime / trait-bound error comes back after two targeted fixes, stop patching and look at the data structure. Usually one of:

- Data should be split (one struct → two, so two `&mut`s are possible).
- Data direction is wrong (parent → child borrow vs. child → parent).
- A field that's conceptually "sometimes here, sometimes not" should be an `Option` or a type-state.
- You need owned data here, not a reference — accept the clone once at the boundary and stop propagating references.
