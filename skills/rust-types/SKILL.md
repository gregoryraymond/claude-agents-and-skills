---
name: rust-types
description: "Rust generics, traits, trait objects, and type-driven design. Use for E0277 (trait bound not satisfied), E0308 (type mismatch), E0599 (no method found), E0038 (object safety), or when choosing between generics / impl Trait / dyn Trait, designing newtypes, type-state machines, PhantomData, marker traits, sealed traits, or the builder pattern."
user-invocable: false
---

# Rust Types, Traits & Type-Driven Design

Two intertwined topics: **(1)** how to express polymorphism (generics vs. trait objects), and **(2)** how to push invariants into the type system so they can't be violated at runtime.

## Static vs. dynamic dispatch

| Form | Dispatch | Binary size | Runtime cost | Use when |
|---|---|---|---|---|
| `fn f<T: Trait>(x: T)` | static (monomorphized) | grows per instantiation | zero | Type is known at call site, performance matters |
| `fn f(x: impl Trait)` | static | same as above | zero | Same as above, terser argument syntax |
| `fn f() -> impl Trait` | static | — | zero | Hiding a concrete return type (closures, iterators) |
| `fn f(x: &dyn Trait)` | dynamic (vtable) | smaller | one indirect call | Heterogeneous input, plugin-style |
| `fn f() -> Box<dyn Trait>` | dynamic | smaller | alloc + indirect call | Returning "one of several" types |
| `enum E { A(..), B(..) }` | match-dispatch | compact | zero | Closed set of variants |

Default: start with generics. Reach for `dyn Trait` when you need heterogeneous collections (`Vec<Box<dyn Trait>>`), plugin points, or compile-time savings on a very large trait.

### Common dispatch errors

| Error | Cause | Likely real fix |
|---|---|---|
| **E0277** (trait bound not satisfied) | `T` doesn't implement `Trait` | Add the bound, *or* reconsider — are you abstracting at the right level? |
| **E0308** (type mismatch) | Concrete type ≠ expected | Often generic inference; annotate once to find the real mismatch |
| **E0599** (no method found) | Trait not in scope | `use crate::module::Trait;` |
| **E0038** (not object-safe) | Method returns `Self`, takes `self` by value, or has generic params | Use generics (static dispatch), or split the trait into an object-safe sub-trait |

### Object safety in one line

A trait is object-safe iff its methods don't use `Self` in return/argument types (except as `&self`/`&mut self`) and don't have generic parameters. Non-object-safe methods can be gated behind `where Self: Sized`.

## Type-driven design

Push invariants into types so invalid states don't compile. Less runtime validation, fewer assertions, better docs.

### Newtype — a struct wrapper around a primitive

```rust
pub struct Email(String);
impl Email {
    pub fn parse(s: &str) -> Result<Self, ParseError> {
        if !s.contains('@') { return Err(ParseError); }
        Ok(Self(s.to_string()))
    }
}
```

Use for: semantic primitives (`UserId`, `Celsius`, `TokenHash`), validated values, and anything where "just a `String`" would let callers pass the wrong thing.

### Type-state — encoding states as type parameters

```rust
use std::marker::PhantomData;

struct Connection<S> { stream: TcpStream, _s: PhantomData<S> }
struct Disconnected; struct Connected; struct Authenticated;

impl Connection<Disconnected> {
    fn connect(self) -> Connection<Connected> { /* ... */ }
}
impl Connection<Connected> {
    fn authenticate(self, creds: Creds) -> Connection<Authenticated> { /* ... */ }
}
impl Connection<Authenticated> {
    fn send(&mut self, msg: &[u8]) { /* only reachable in this state */ }
}
```

Use when a struct has a meaningful lifecycle of states and calling the wrong method in the wrong state should be a compile error.

### PhantomData — zero-sized type/lifetime marker

Needed when a type parameter isn't used in any field, to declare variance, drop semantics, or lifetime relationships. Pattern: `PhantomData<T>`, `PhantomData<&'a T>`, `PhantomData<fn(T) -> T>` for invariance.

### Marker traits & sealed traits

```rust
// Marker: capability flag, no methods
pub trait Validated {}

// Sealed: prevent downstream crates from implementing
mod private { pub trait Sealed {} }
pub trait MyTrait: private::Sealed { /* ... */ }
```

Sealed traits give you `pub` traits that you still fully control implementations of — safe API evolution without a `#[non_exhaustive]` enum.

### Builder — gradual construction

For types with many optional fields, or where construction needs validation across multiple fields:

```rust
pub struct Request { /* ... */ }
pub struct RequestBuilder { /* ... optional fields ... */ }
impl RequestBuilder {
    pub fn timeout(mut self, d: Duration) -> Self { /* ... */ self }
    pub fn build(self) -> Result<Request, BuildError> { /* validate here */ }
}
```

Combine with type-state for builders that won't compile until required fields are set.

## Decision guide

| If you need... | Reach for... |
|---|---|
| Same behavior across known types, zero cost | Generic function / `impl Trait` |
| Heterogeneous collection | `Vec<Box<dyn Trait>>` |
| Return "one of several" types with common interface | `Box<dyn Trait>` (or `enum` if closed) |
| Closed set of variants | `enum` |
| Type-safe wrapper for a primitive | Newtype |
| Only-valid-calls-compile | Type-state with `PhantomData` |
| Variance / drop-check hints | `PhantomData<...>` |
| Capability tag, no runtime | Marker trait (empty `trait Foo {}`) |
| Controlled trait impls | Sealed trait |
| Optional fields + validation | Builder |

## Anti-patterns

- **Primitive obsession** — `String` for emails, `u64` for user-ids. Use newtypes.
- **Boolean flags for states** — `is_connected: bool`. Use type-state.
- **`Option` everywhere to mean "maybe initialized"** — use a builder that produces the finished type.
- **Over-generic everything** — `fn foo<T: A + B + C + D>(...)` explodes compile time and error messages. Use concrete types until you actually need polymorphism.
- **`dyn Trait` when all types are known at compile time** — pays vtable + alloc for nothing.
- **Deep trait hierarchies** — Rust traits aren't classes; composition via multiple small traits usually reads better.
- **Public fields on invariant-carrying structs** — breaks validation. Keep fields private, provide a validated constructor.

## When to escalate

| Symptom | Likely real problem |
|---|---|
| Trait-bound soup in every signature | Abstraction is too generic — use concrete types or a narrower trait |
| Compile times blowing up | Over-monomorphization; convert inner helpers to `dyn` |
| E0038 on a trait you designed | Split into an object-safe base + a `Sized`-bound extension |
| Fighting with `PhantomData` variance | You probably need `fn(T) -> T` (invariant) or `fn() -> T` (covariant out); check the nomicon |
