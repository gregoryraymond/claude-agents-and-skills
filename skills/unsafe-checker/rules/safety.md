# Safety Abstraction

Rules for building safe abstractions on top of unsafe code. Covers upholding safety invariants, panic safety, documenting caller obligations, and avoiding common unsoundness patterns when wrapping raw pointers, uninitialized memory, and auto-trait impls.

### safety-01: Be aware of memory safety issues from panics (clippy: panic_in_result_fn)

Panics unwind the stack and run destructors; if unsafe code has partially updated bookkeeping, those destructors may observe invalid state and cause UB. Update length/count fields only after the memory they describe is fully initialized.

```rust
// Bad: len incremented before write; if clone panics, Drop reads uninit memory
unsafe {
    self.len += 1;
    ptr::write(self.ptr.add(self.len - 1), value.clone());
}

// Good: write first, then bump len so Drop never sees uninitialized slots
unsafe {
    ptr::write(self.ptr.add(self.len), value);
    self.len += 1;
}
```

### safety-02: Unsafe code authors must verify safety invariants

`unsafe` does not disable safety requirements; it transfers responsibility from the compiler to you. You must verify pointer validity, aliasing, initialization, lifetimes, type validity, and thread safety by hand.

```rust
// Bad: blindly trusts caller inputs with no documentation or checks
unsafe fn process(ptr: *const Data, len: usize) {
    for i in 0..len { process_item(&*ptr.add(i)); }
}

// Good: document invariants, assert in debug, provide safe wrapper
/// # Safety
/// - `ptr` non-null, aligned, points to `len` initialized `Data` items
/// - memory not mutated during the call
unsafe fn process(ptr: *const Data, len: usize) {
    debug_assert!(!ptr.is_null() && ptr.is_aligned());
    for i in 0..len { process_item(&*ptr.add(i)); }
}
fn process_slice(data: &[Data]) {
    // SAFETY: slice guarantees all invariants
    unsafe { process(data.as_ptr(), data.len()) }
}
```

### safety-03: Do not expose uninitialized memory in public APIs (clippy: uninit_assumed_init)

Reading uninitialized memory is UB; safe callers must never be able to reach it through your API. Use `MaybeUninit` for delayed initialization and maintain a len/capacity invariant so only initialized bytes are exposed.

```rust
// Bad: assume_init on uninit bytes; safe as_slice can read garbage
let data: [u8; 1024] = unsafe { MaybeUninit::uninit().assume_init() };

// Good: store MaybeUninit, expose only the initialized prefix
pub struct Buffer { data: Box<[MaybeUninit<u8>; 1024]>, len: usize }
impl Buffer {
    pub fn as_slice(&self) -> &[u8] {
        // SAFETY: invariant: data[0..len] is initialized
        unsafe { std::slice::from_raw_parts(self.data.as_ptr() as *const u8, self.len) }
    }
}
```

### safety-04: Avoid double-free from panic safety issues

Double-free is UB. When reading out of a collection, update bookkeeping (length, flags) *before* the read so `Drop` will not also try to drop the same slot if something later unwinds.

```rust
// Bad: ptr::read copies out, but len still includes slot -> Drop double-frees
unsafe { Some(ptr::read(self.ptr.add(self.len))) }

// Good: decrement len first, so Drop skips the moved-out slot
self.len -= 1;
// SAFETY: len was decremented; Drop will not touch this slot again
unsafe { Some(ptr::read(self.ptr.add(self.len))) }
```

### safety-05: Consider safety when manually implementing auto traits (clippy: non_send_fields_in_send_ty)

`Send`/`Sync` are unsafe traits; a wrong impl causes data races (UB). Only impl them when the type's internals are actually thread-safe (atomics, locks, OS-backed handles) and document the reasoning.

```rust
// Bad: non-atomic refcount behind a raw pointer, claimed Sync
struct RcInner<T> { count: usize, data: T }
unsafe impl<T: Send> Sync for MyRc<T> {}

// Good: atomic refcount, bounds reflect actual safety
struct ArcInner<T> { count: AtomicUsize, data: T }
unsafe impl<T: Send + Sync> Send for MyArc<T> {}
unsafe impl<T: Send + Sync> Sync for MyArc<T> {}
```

### safety-06: Do not expose raw pointers in public APIs

Raw pointers in a public signature force users into unsafe and push UB risk onto them. Prefer references, slices, or smart pointers; if a raw pointer really is needed, make the function `unsafe` and document the obligations.

```rust
// Bad: safe public API hands out and accepts raw pointers
pub fn as_ptr(&self) -> *const u8 { self.data }
pub fn from_ptr(ptr: *mut u8, len: usize) -> Self { Self { data: ptr, len } }

// Good: safe API uses slices; raw-pointer entry is explicitly unsafe
pub fn as_slice(&self) -> &[u8] { &self.data }
/// # Safety
/// `ptr` must point to `len` bytes allocated by the global allocator, etc.
pub unsafe fn from_raw_parts(ptr: *mut u8, len: usize, cap: usize) -> Self {
    Self { data: Vec::from_raw_parts(ptr, len, cap) }
}
```

### safety-07: Provide unsafe counterparts for performance alongside safe methods

When skipping a safety check buys real performance, offer both a safe checked method and an `_unchecked` unsafe variant. Safe-by-default, unsafe-opt-in; the checked version should itself call the unchecked one after validating.

```rust
// Bad: only the unchecked form exists, forcing unsafe at every call site
pub unsafe fn get(&self, i: usize) -> &T { &*self.ptr.add(i) }

// Good: paired API, shared implementation
pub fn get(&self, i: usize) -> Option<&T> {
    if i < self.len {
        // SAFETY: i < len just checked
        Some(unsafe { self.get_unchecked(i) })
    } else { None }
}
/// # Safety
/// `i` must be < `self.len`.
pub unsafe fn get_unchecked(&self, i: usize) -> &T {
    debug_assert!(i < self.len);
    &*self.ptr.add(i)
}
```

### safety-08: Mutable return from immutable parameter is wrong (clippy: mut_from_ref)

A function taking `&self` or `&T` must not hand out `&mut T` to the same data unless the data lives inside an `UnsafeCell`. Casting `&` to `&mut` via raw pointers or `transmute` is always UB.

```rust
// Bad: fabricates &mut from &self without UnsafeCell -> UB
pub fn get_mut(&self) -> &mut i32 {
    unsafe { &mut *(&self.data as *const i32 as *mut i32) }
}

// Good: interior mutability through UnsafeCell (or Cell/RefCell/Mutex)
struct V { data: UnsafeCell<i32> }
impl V {
    // SAFETY: caller has proven exclusive access (e.g. holds the lock)
    pub fn get_mut(&self) -> &mut i32 { unsafe { &mut *self.data.get() } }
}
```

### safety-09: Add SAFETY comment before any unsafe block (clippy: undocumented_unsafe_blocks)

Every `unsafe` block and `unsafe impl` needs a `// SAFETY:` comment stating which invariants must hold and why they hold here. Vague comments ("trust me", "this is unsafe") are not acceptable.

```rust
// Bad: no explanation of why the unchecked access is sound
fn get(slice: &[i32], i: usize) -> i32 { unsafe { *slice.get_unchecked(i) } }

// Good: SAFETY names the invariant and why it holds at this call
fn get(slice: &[i32], i: usize) -> i32 {
    // SAFETY: caller guarantees i < slice.len()
    unsafe { *slice.get_unchecked(i) }
}
```

### safety-10: Add Safety section in docs for public unsafe functions (clippy: missing_safety_doc)

Public `unsafe fn` must have a `# Safety` section enumerating every caller obligation. `SAFETY:` comments explain soundness at a call site; `# Safety` docs tell callers what they must guarantee to avoid UB.

```rust
// Bad: unsafe public function, no safety docs
pub unsafe fn process_buffer(ptr: *const u8, len: usize) { /* ... */ }

// Good: explicit caller contract
/// # Safety
/// - `ptr` is non-null, aligned, points to `len` initialized bytes
/// - memory is not mutated during the call
/// - `len <= isize::MAX`
pub unsafe fn process_buffer(ptr: *const u8, len: usize) { /* ... */ }
```

### safety-11: Use assert! instead of debug_assert! in unsafe functions (clippy: debug_assert_with_mut_call)

`debug_assert!` is compiled out in release, so it must not be relied on for safety-critical checks inside an unsafe function. Use `assert!` when *this* function owns the invariant; `debug_assert!` is only appropriate when the caller owns it (per `# Safety` docs).

```rust
// Bad: safety check disappears in release builds
pub unsafe fn get_unchecked(s: &[i32], i: usize) -> &i32 {
    debug_assert!(i < s.len());
    &*s.as_ptr().add(i)
}

// Good: assert! when we're enforcing the bound ourselves
pub unsafe fn get_unchecked(s: &[i32], i: usize) -> &i32 {
    assert!(i < s.len(), "index {} out of bounds for len {}", i, s.len());
    &*s.as_ptr().add(i)
}
```
