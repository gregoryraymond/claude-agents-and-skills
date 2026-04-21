# Unsafe Code Checklist

Three passes — one before writing, one during review, plus a list of the most common bug patterns and their fixes.

---

## Before writing unsafe

### 1. Can you avoid it?

- Have you tried all safe alternatives?
- Can the code be restructured to satisfy the borrow checker?
- Would interior mutability (`Cell`, `RefCell`, `Mutex`) solve the problem?
- Is there a safe crate that already does this?
- Is the performance gain (if any) worth the safety risk?

If "no" to all, proceed.

### 2. What unsafe operation, specifically?

- [ ] Dereferencing a raw pointer (`*const T`, `*mut T`)
- [ ] Calling an `unsafe fn`
- [ ] Accessing a mutable `static`
- [ ] Implementing an unsafe trait (`Send`, `Sync`, …)
- [ ] Accessing `union` fields
- [ ] Calling `extern "C"` functions

### 3. Invariants for each operation

**Pointer dereference** — non-null, aligned, points to valid + initialized memory, not mutated by other code during use, valid for the full duration of use.

**Mutable aliasing** — no other `&mut` exists to the same memory, no `&` exists that can observe the mutation.

**FFI call** — signature matches C exactly (types, ABI), null pointers handled, panics cannot cross the boundary, ownership of allocated memory is documented.

**Send/Sync impl** — concurrent access is synchronized; the type really satisfies the trait's thread-safety contract.

### 4. Panic safety

- What's the program state if this panics at any line?
- Are partially-constructed objects cleaned up properly?
- Will a `Drop` impl see valid state?
- Do you need a panic guard?

### 5. Documentation

- [ ] Every `unsafe { ... }` has a `// SAFETY:` comment naming the invariants it relies on.
- [ ] Every `pub unsafe fn` has a `# Safety` doc section stating what the caller must guarantee.

### 6. Testing

- [ ] Debug assertions for invariants where feasible.
- [ ] Tested with `cargo miri test`.
- [ ] For FFI / threading: consider sanitizers (`-Zsanitizer=address` / `thread`).
- [ ] Fuzzing if inputs come from outside.

---

## Reviewing unsafe

### Surface

- [ ] Every `unsafe` block has a `// SAFETY:` comment.
- [ ] Every `unsafe fn` has a `# Safety` doc section.
- [ ] Safety comments are specific, not "trust me" or "this is safe".
- [ ] Unsafe blocks are minimized (smallest possible scope).

### Pointer validity

For each dereference:

- [ ] **Non-null** — checked, or guaranteed by construction.
- [ ] **Aligned** — for the type being read/written.
- [ ] **Valid** — points to allocated memory.
- [ ] **Initialized** — if being read.
- [ ] **Lifetime** — memory valid for the entire use.
- [ ] **Unique** — for `&mut`, only one mutable path at a time.

### Memory safety

- [ ] No aliasing — never `&` and `&mut` to the same memory simultaneously.
- [ ] No use-after-free.
- [ ] No double-free.
- [ ] No data races — concurrent access synchronized.
- [ ] Bounds checked — array/slice accesses in range.

### Type safety

- [ ] `transmute` — source and destination layouts actually compatible, valid bit patterns.
- [ ] FFI types have `#[repr(C)]`.
- [ ] Enum discriminants from external sources are validated.
- [ ] Union field access reads the currently-active variant.

### Panic safety

- [ ] Partial state is valid or rolled back on panic.
- [ ] `Drop` impls see valid state.
- [ ] Panic guard present where needed.

### FFI-specific

- [ ] Rust types match C types exactly (width, signedness, layout).
- [ ] Strings are null-terminated and allocated correctly.
- [ ] Memory ownership is documented (who allocates, who frees).
- [ ] Callbacks thread-safe if the C side may call from any thread.
- [ ] `catch_unwind` at every `extern "C"` boundary that might panic.
- [ ] C-style error returns handled and translated.

### Concurrency

- [ ] Manual `Send`/`Sync` impls are actually sound.
- [ ] Atomic memory orderings correct.
- [ ] No obvious deadlock paths.
- [ ] All shared mutable state synchronized.

### Red flags requiring extra scrutiny

| Pattern | Concern |
|---|---|
| `transmute` | Type/layout compatibility, provenance |
| `as` on pointers | Alignment, type punning |
| `static mut` | Data races |
| `*const T as *mut T` | Aliasing violation |
| Manual `Send` / `Sync` | Thread-safety contract |
| `assume_init` | Is it actually initialized? |
| `Vec::set_len` | Uninitialized slots readable |
| `slice::from_raw_parts` | Lifetime, validity, alignment |
| `ptr::offset` / `add` / `sub` | Out of bounds, provenance |
| FFI callbacks | Panic unwinding across boundary |

### Severity guide

| Pattern | Requires |
|---|---|
| `transmute` | Second reviewer + Miri test |
| Manual `Send`/`Sync` | Thread-safety-expert review |
| FFI call | Link to C interface documentation |
| `static mut` | Justification for not using atomic/mutex |
| Pointer arithmetic | Bounds proof in SAFETY comment |

### Sample comments

```
Good:  // SAFETY: index was checked to be < len on line 42
Weak:  // SAFETY: This is safe because we know it works
Weak:  // SAFETY: ptr is valid          (why is it valid? how do we know?)
```

---

## Common pitfalls

### 1. Dangling pointer to a local

```rust
// Bad
fn bad() -> *const i32 { let x = 42; &x as *const i32 }

// Good
fn good() -> Box<i32> { Box::new(42) }
```

### 2. `CString::new(..).as_ptr()` dangles

```rust
// Bad: CString dropped at end of function
fn bad() -> *const c_char {
    CString::new("hello").unwrap().as_ptr()
}

// Good: keep the CString alive
fn good(s: &CString) -> *const c_char { s.as_ptr() }
// Or transfer ownership
fn also_good(s: CString) -> *const c_char { s.into_raw() }
```

### 3. `Vec::set_len` with uninitialized data

```rust
// Bad: Strings uninit → reading them is UB
let mut v = Vec::with_capacity(10);
unsafe { v.set_len(10); }

// Good
let mut v = Vec::new();
v.resize(10, String::new());
```

### 4. Reference to a `repr(packed)` field

```rust
#[repr(packed)]
struct Packed { a: u8, b: u32 }

// Bad: &p.b may be misaligned → UB
fn bad(p: &Packed) -> &u32 { &p.b }

// Good
fn good(p: &Packed) -> u32 {
    unsafe { std::ptr::addr_of!(p.b).read_unaligned() }
}
```

### 5. Aliasing raw `*mut`

```rust
// Bad: two live *mut to the same place
let ptr1 = &mut x as *mut i32;
let ptr2 = &mut x as *mut i32;

// Good: one pointer, sequential writes
let ptr = &mut x as *mut i32;
unsafe { *ptr = 1; *ptr = 2; }
```

### 6. `transmute` across different sizes

```rust
// Bad: UB if sizeof(src) != sizeof(dst)
let y: u64 = unsafe { std::mem::transmute(42u32) };

// Good
let y: u64 = 42u32 as u64;
```

### 7. Invalid enum discriminant

```rust
#[repr(u8)]
enum Status { A = 0, B = 1, C = 2 }

// Bad: UB if raw > 2
unsafe fn bad(raw: u8) -> Status { std::mem::transmute(raw) }

// Good
fn good(raw: u8) -> Option<Status> {
    match raw { 0 => Some(Status::A), 1 => Some(Status::B), 2 => Some(Status::C), _ => None }
}
```

### 8. Panic unwinding across FFI

```rust
// Bad: panic unwinds into C → UB
#[no_mangle] extern "C" fn cb(x: i32) -> i32 {
    if x < 0 { panic!() } x * 2
}

// Good: catch before the boundary
#[no_mangle] extern "C" fn cb(x: i32) -> i32 {
    std::panic::catch_unwind(|| if x < 0 { panic!() } else { x * 2 })
        .unwrap_or(-1)
}
```

### 9. Double free via `Clone` on a handle

```rust
// Bad: Clone copies the raw pointer; both Drops free it
#[derive(Clone)] struct Handle(*mut c_void);
impl Drop for Handle { fn drop(&mut self) { unsafe { free(self.0); } } }

// Good: don't derive Clone on owning handles; use Rc/Arc if sharing is needed
struct Handle(*mut c_void);
impl Drop for Handle { fn drop(&mut self) { unsafe { free(self.0); } } }
```

### 10. `mem::forget` skips destructors

```rust
// Bad: lock never released
let g = lock.lock();
std::mem::forget(g);

// Good: let it drop normally
let g = lock.lock();
// ...
drop(g); // or just end the scope
```

### Detection quick-reference

| Pitfall | Caught by |
|---|---|
| Dangling pointer | Miri |
| Uninitialized read | Miri |
| Misaligned access | Miri, UBSan |
| Data race | ThreadSanitizer |
| Double free | AddressSanitizer |
| Invalid enum | manual review, `TryFrom` |
| FFI panic | unit test with panic in callback |
| Type confusion | Miri |
