# Raw Pointers & Unions

Raw pointers bypass Rust's borrow checker and require explicit care around nullability, aliasing, alignment, variance, and thread safety. Unions share memory across fields and should only appear at C FFI boundaries.

## Raw Pointers

### ptr-01: Do not share raw pointers across threads

Raw pointers are neither `Send` nor `Sync`. Sharing `*const T`/`*mut T` across threads without synchronization is a data race (UB). Use `Arc<Mutex<T>>`, `AtomicPtr`, or transfer ownership instead.

```rust
// Bad: data race — both threads write through the same raw pointer
let mut data = 42i32;
let ptr = &mut data as *mut i32;
let handle = thread::spawn(move || unsafe { *ptr = 100; });
unsafe { *ptr = 200; }
handle.join().unwrap();

// Good: synchronize via Arc<Mutex<T>>
let data = Arc::new(Mutex::new(42i32));
let data_clone = Arc::clone(&data);
let handle = thread::spawn(move || { *data_clone.lock().unwrap() = 100; });
*data.lock().unwrap() = 200;
handle.join().unwrap();
```

### ptr-02: Prefer NonNull<T> over *mut T

When a pointer is never null, use `NonNull<T>` to encode that invariant in the type, enable niche optimization (`Option<NonNull<T>>` is pointer-sized), and get covariance.

```rust
// Bad: *mut T leaves "never null" as an undocumented invariant
struct MyBox<T> { ptr: *mut T }

// Good: NonNull enforces non-null and enables Option niche optimization
use std::ptr::NonNull;
struct MyBox<T> { ptr: NonNull<T> }
impl<T> MyBox<T> {
    pub fn new(value: T) -> Self {
        let raw = Box::into_raw(Box::new(value));
        // SAFETY: Box::into_raw never returns null
        Self { ptr: unsafe { NonNull::new_unchecked(raw) } }
    }
}
```

### ptr-03: Use PhantomData for variance and ownership

Raw pointers carry no ownership, lifetime, or variance info. Add `PhantomData` so the compiler applies drop-check, lifetime elision, and the correct variance.

```rust
// Bad: compiler doesn't know MyVec<T> owns T values — drop check is wrong
struct MyVec<T> { ptr: *mut T, len: usize, cap: usize }

// Good: PhantomData<T> expresses ownership; PhantomData<&'a T> expresses borrow
use std::marker::PhantomData;
use std::ptr::NonNull;
struct MyVec<T> {
    ptr: NonNull<T>,
    len: usize,
    cap: usize,
    _marker: PhantomData<T>,
}
struct Iter<'a, T> {
    ptr: *const T,
    end: *const T,
    _marker: PhantomData<&'a T>,
}
```

Common patterns: `PhantomData<T>` (owns, covariant), `PhantomData<&'a T>` (borrows), `PhantomData<&'a mut T>` (invariant in T), `PhantomData<fn(T)>` (contravariant).

### ptr-04: Alignment (clippy: cast_ptr_alignment)

Never dereference a pointer cast to a type with stricter alignment than the source. On ARM/RISC-V/WASM misaligned access is UB; on x86 it's merely slow and often buggy.

```rust
// Bad: bytes may not be 4-byte aligned — UB on ARM/RISC-V
fn bad_cast(bytes: &[u8]) -> u32 {
    let ptr = bytes.as_ptr() as *const u32;
    unsafe { *ptr }
}

// Good: read_unaligned avoids the alignment requirement
fn good_cast(bytes: &[u8]) -> u32 {
    let ptr = bytes.as_ptr() as *const u32;
    // SAFETY: caller ensures >= 4 bytes
    unsafe { ptr.read_unaligned() }
}

// Better: safe conversion via fixed-size array
fn best(bytes: &[u8]) -> u32 {
    u32::from_ne_bytes(bytes[..4].try_into().unwrap())
}
```

### ptr-05: Do not cast *const to *mut to write (clippy: cast_ref_to_mut)

Writing through a `*mut T` derived from `&T` or `*const T` violates aliasing and is always UB — the compiler assumes `&T` means immutable and may cache reads. Use `&mut`, `Cell`/`RefCell`, or `UnsafeCell` (the only sound way to get `*mut T` from `&self`).

```rust
// Bad: writing through a pointer derived from &T is UB regardless of aliasing
fn bad(value: &i32) {
    let ptr = value as *const i32 as *mut i32;
    unsafe { *ptr = 42; }
}

// Good: take &mut, or use interior mutability via UnsafeCell
use std::cell::UnsafeCell;
struct RawMutable { value: UnsafeCell<i32> }
impl RawMutable {
    fn modify(&self) {
        // SAFETY: external synchronization guarantees exclusive access
        unsafe { *self.value.get() = 42; }
    }
}
```

### ptr-06: Prefer pointer::cast over `as` (clippy: ptr_as_ptr)

`cast()` and friends (`cast_mut`, `cast_const`, `with_addr`) are clearer than `as` and prevent accidental provenance loss via `usize` round-trips.

```rust
// Bad: `as` chains are hard to read and can launder provenance through usize
fn bad(ptr: *const u8) -> *mut i32 {
    ptr as *mut u8 as *mut i32
}
fn bad_roundtrip(ptr: *const u8) -> *const u8 {
    let addr = ptr as usize;
    addr as *const u8 // provenance lost
}

// Good: explicit cast methods keep intent and provenance clear
fn good(ptr: *const u8) -> *mut i32 {
    ptr.cast_mut().cast::<i32>()
}
```

| Method | From | To |
|--------|------|-----|
| `.cast::<U>()` | `*T` | `*U` |
| `.cast_mut()` | `*const T` | `*mut T` |
| `.cast_const()` | `*mut T` | `*const T` |
| `.with_addr(usize)` | `*T` | `*T` (keeps provenance) |

## Unions

### union-01: Avoid union except for C interop

Any `union` field read is `unsafe`, destructors don't run, and reading the wrong field is UB. Use `enum` for Rust-only tagged variants; reserve `union` for `#[repr(C)]` FFI or the standard library's `MaybeUninit`-style internals.

```rust
// Bad: union in Rust-only code — easy to read wrong field (UB) and leak String
union Variant {
    string: std::mem::ManuallyDrop<String>,
    number: i64,
}

// Good: enum — compiler tracks the active variant and runs Drop correctly
enum Variant {
    String(String),
    Number(i64),
}

// Good: union only at an FFI boundary, with an explicit tag in the wrapper
#[repr(C)]
union CUnion { i: i32, f: f32 }
#[repr(C)]
pub struct SafeUnion { tag: u8, data: CUnion }
impl SafeUnion {
    pub fn as_int(&self) -> Option<i32> {
        // SAFETY: tag == 0 means the i variant is active
        if self.tag == 0 { Some(unsafe { self.data.i }) } else { None }
    }
}
```

Alternatives: variant types -> `enum`; optional -> `Option<T>`; type punning -> `from_ne_bytes` or `transmute`; uninit memory -> `MaybeUninit<T>`.

### union-02: Do not use union variants across different lifetimes

Union fields share storage. Writing a `&'a T` and reading a `&'b U` bypasses lifetime checking and can hand out dangling references. All reference fields in a union must share a single lifetime.

```rust
// Bad: union laundering a short reference into a longer lifetime — dangling ref
union LifetimeBypass<'a, 'b> {
    short: &'a str,
    long: &'b str,
}
fn bad<'a, 'b>(short: &'a str) -> &'b str {
    let u = LifetimeBypass { short };
    unsafe { u.long } // UB: extends lifetime
}

// Good: all reference fields share the same lifetime parameter
union SafeUnion<'a> {
    str_ref: &'a str,
    bytes_ref: &'a [u8],
}
// Better still: use the safe API
fn better(s: &str) -> &[u8] { s.as_bytes() }
```
