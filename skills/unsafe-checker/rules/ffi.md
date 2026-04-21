# FFI & I/O Safety

Rules for safely interoperating with C and other foreign code, plus I/O-safety rules for raw OS handles. These cover string conversion, memory ownership, panic boundaries, layout stability, thread safety, and related pitfalls.

## FFI

### ffi-01: Avoid passing Rust strings directly to C

Rust `String`/`&str` is UTF-8 and not null-terminated, so it cannot be used as a C string. Use `CString` for passing strings to C and `CStr` for receiving them.

```rust
// Bad: not null-terminated, may read past buffer
fn bad_print(s: &str) {
    unsafe { c_print(s.as_ptr() as *const c_char); }
}

// Good: CString adds null terminator and checks for interior nulls
fn good_print(s: &str) -> Result<(), std::ffi::NulError> {
    let c_string = CString::new(s)?;
    unsafe { c_print(c_string.as_ptr()); }
    Ok(())
}
```

### ffi-02: Read std::ffi documentation carefully

`std::ffi` types have subtle differences (ownership, lifetime, encoding). Read the docs; common pitfalls are dangling `CString::as_ptr()`, calling `CStr::from_ptr` on null, and assuming valid null-termination.

```rust
// Bad: CString dropped at end of function; pointer dangles
fn bad_ptr() -> *const c_char {
    let s = CString::new("hello").unwrap();
    s.as_ptr()
}

// Good: keep the CString alive for the pointer's lifetime
fn good_ptr(s: &CString) -> *const c_char {
    s.as_ptr()
}
```

### ffi-03: Implement Drop for Rust types wrapping memory-managing C pointers

When a Rust type owns a C-allocated resource, implement `Drop` to call the matching C free function, and prevent `Clone`/`Copy` so you don't double-free.

```rust
// Bad: no Drop, memory leaks
struct Handle { ptr: *mut Resource }
impl Handle {
    fn new() -> Self { Self { ptr: unsafe { create_resource() } } }
}

// Good: NonNull wrapper with Drop calling the C free
struct Handle { ptr: NonNull<Resource> }
impl Handle {
    fn new() -> Option<Self> {
        NonNull::new(unsafe { create_resource() }).map(|ptr| Self { ptr })
    }
}
impl Drop for Handle {
    fn drop(&mut self) {
        // SAFETY: ptr came from create_resource and hasn't been freed
        unsafe { free_resource(self.ptr.as_ptr()); }
    }
}
```

### ffi-04: Handle panics at FFI boundaries (clippy: panic_in_result_fn)

Unwinding through `extern "C"` is UB. Wrap bodies in `catch_unwind` and return error codes, or use `extern "C-unwind"` only when both sides are Rust.

```rust
// Bad: unwrap can unwind into C, which is UB
#[no_mangle]
pub extern "C" fn parse(path: *const c_char) -> i32 {
    let p = unsafe { CStr::from_ptr(path) }.to_str().unwrap();
    std::fs::read_to_string(p).unwrap();
    0
}

// Good: catch_unwind + error codes keep unwinding inside Rust
#[no_mangle]
pub extern "C" fn parse(path: *const c_char) -> i32 {
    let r = catch_unwind(AssertUnwindSafe(|| -> Result<(), Box<dyn std::error::Error>> {
        let p = unsafe { CStr::from_ptr(path) }.to_str()?;
        std::fs::read_to_string(p)?;
        Ok(())
    }));
    match r { Ok(Ok(())) => 0, Ok(Err(_)) => -1, Err(_) => -99 }
}
```

### ffi-05: Use portable C type aliases

C types like `int` and `long` have platform-dependent sizes. Use `std::os::raw::c_*` or `libc` aliases, not Rust primitives, in `extern` signatures and `#[repr(C)]` structs.

```rust
// Bad: assumes C int == i32, C long == i64 (wrong on some platforms)
extern "C" { fn c_function(x: i32, y: i64) -> i32; }

// Good: portable aliases that match the C ABI
use std::os::raw::{c_int, c_long};
extern "C" { fn c_function(x: c_int, y: c_long) -> c_int; }
```

### ffi-06: Ensure C-ABI compatibility for strings

Agree on encoding, null-termination, and ownership on both sides of the boundary. Be explicit about who allocates and who frees.

```rust
// Bad: passes &str pointer; not null-terminated, ownership unclear
fn rust_to_c(s: &str) {
    unsafe { c_process_string(s.as_ptr() as *const c_char); }
}

// Good: CString owns null-terminated memory until scope end
fn rust_to_c(s: &str) -> Result<(), std::ffi::NulError> {
    let c = CString::new(s)?;
    unsafe { c_process_string(c.as_ptr()); }
    Ok(())
}
```

### ffi-07: Do not implement Drop for types passed to external code

If external code takes ownership and frees the type, a Rust `Drop` impl causes a double-free. Either skip `Drop` or track ownership with a flag / `ManuallyDrop`.

```rust
// Bad: C library frees EventHandler, but Rust Drop also frees -> double free
impl Drop for EventHandler {
    fn drop(&mut self) { unsafe { libc::free(self.user_data); } }
}

// Good: no Drop; wrapper tracks whether Rust still owns it
struct RegisteredHandler { ptr: *mut EventHandler, registered: bool }
impl Drop for RegisteredHandler {
    fn drop(&mut self) {
        if self.registered {
            unsafe { unregister_handler(self.ptr); }
        } else {
            unsafe { drop(Box::from_raw(self.ptr)); }
        }
    }
}
```

### ffi-08: Use C-compatible error handling in FFI

`Result`/`Option` have no stable C layout. Return integer codes and use out-parameters or thread-local last-error for details.

```rust
// Bad: Result is not C-ABI compatible
#[no_mangle]
pub extern "C" fn open(path: *const c_char) -> Result<Handle, Error> { todo!() }

// Good: error code + out parameter
#[no_mangle]
pub extern "C" fn open(path: *const c_char, out: *mut *mut Handle) -> c_int {
    if path.is_null() || out.is_null() { return 1; }
    // ... fill *out on success, return 0 ...
    0
}
```

### ffi-09: Prefer references over raw pointers in safe wrappers

In the safe API, use `&T`/`&mut T`/`&[T]` (which guarantee non-null and valid length). Keep raw pointers in the unsafe FFI layer only.

```rust
// Bad: exposes raw pointer in the safe API; caller could pass null
pub fn process(data: *const u8, len: usize) {
    unsafe { c_process(data, len); }
}

// Good: slice reference guarantees non-null and valid length
pub fn process(data: &[u8]) {
    unsafe { c_process(data.as_ptr(), data.len()); }
}
```

### ffi-10: Exported functions must be thread-safe

C callers may invoke your `extern "C"` functions from any thread. Synchronize global state with atomics/`Mutex`/`OnceLock`, and document any functions that are not thread-safe.

```rust
// Bad: unsynchronized global, data race UB under concurrent callers
static mut COUNTER: i32 = 0;
#[no_mangle]
pub extern "C" fn increment() -> i32 {
    unsafe { COUNTER += 1; COUNTER }
}

// Good: atomic global
static COUNTER: AtomicI32 = AtomicI32::new(0);
#[no_mangle]
pub extern "C" fn increment() -> i32 {
    COUNTER.fetch_add(1, Ordering::SeqCst) + 1
}
```

### ffi-11: Packed repr fields (clippy: unaligned_references)

Creating a reference (even implicitly, via method call or `match`) to a field of a `#[repr(packed)]` struct is UB if misaligned. Use `addr_of!`/`addr_of_mut!` plus `read_unaligned`/`write_unaligned`.

```rust
#[repr(C, packed)]
struct Packet { header: u8, value: u32 }

// Bad: &p.value produces a misaligned reference -> UB
fn bad(p: &Packet) -> &u32 { &p.value }

// Good: unaligned pointer read avoids creating a reference
fn good(p: &Packet) -> u32 {
    unsafe { std::ptr::addr_of!(p.value).read_unaligned() }
}
```

### ffi-12: Document invariants assumed of C-provided parameters

State which invariants (non-null, alignment, validity, length, lifetime, thread-safety) you trust the C caller to uphold, and verify what you can at runtime.

```rust
// Bad: silently assumes non-null, aligned, valid Data, static lifetime
fn bad() -> &'static Data {
    unsafe { &*get_data() }
}

// Good: verify null, document the rest, return Option
/// # Invariants (not verified)
/// - Pointer is aligned for `Data` and points to an initialized value
/// - Returned reference lives as long as the library
fn good() -> Option<&'static Data> {
    let p = unsafe { get_data() };
    if p.is_null() { return None; }
    Some(unsafe { &*p })
}
```

### ffi-13: Use repr(C) for FFI types

Default Rust layout is unspecified and may reorder fields. Any type crossing the FFI boundary must use `#[repr(C)]` (or `#[repr(transparent)]` for newtypes).

```rust
// Bad: default repr may reorder fields; C layout mismatch
struct BadStruct { a: u8, b: u32, c: u8 }

// Good: repr(C) guarantees C-standard layout with padding
#[repr(C)]
struct GoodStruct { a: u8, b: u32, c: u8 }
```

### ffi-14: Types used in FFI should have stable layout

Never put `Vec`, `String`, `HashMap`, or other std generics with unstable layout in FFI signatures/structs. Use raw pointer + length + capacity, fixed-size arrays, or custom stable wrappers.

```rust
// Bad: Vec/String layouts are not stable, not C-compatible
#[repr(C)]
struct BadMixed { id: c_int, data: Vec<u8> }

// Good: explicit pointer + length + capacity
#[repr(C)]
struct GoodBuffer { ptr: *mut u8, len: usize, cap: usize }
```

### ffi-15: Validate non-robust external values

Data from FFI, files, or the network may violate Rust invariants (valid enum discriminants, UTF-8, bounded sizes). Use `TryFrom` and explicit validation instead of `transmute` or `unwrap`.

```rust
// Bad: transmute of unchecked u8 is UB when raw > 2
fn bad() -> Status { unsafe { std::mem::transmute(get_status()) } }

// Good: TryFrom validates the discriminant
impl TryFrom<u8> for Status {
    type Error = InvalidStatus;
    fn try_from(v: u8) -> Result<Self, Self::Error> {
        match v {
            0 => Ok(Status::Active),
            1 => Ok(Status::Inactive),
            2 => Ok(Status::Pending),
            _ => Err(InvalidStatus(v)),
        }
    }
}
```

### ffi-16: Separate data and code when passing closures to C

C callbacks are bare function pointers with no captured state. Use the trampoline pattern: pass a non-capturing `extern "C"` thunk plus a `*mut c_void` user-data pointing at the closure.

```rust
// Bad: closures with captures are not function pointers; transmute is UB
fn bad() {
    let m = 2;
    let closure = |x: i32| x * m;
    // set_callback(closure) // won't compile, and transmute would be UB
}

// Good: trampoline forwards from C to the captured closure via user_data
fn register<F: FnMut(i32) -> i32>(closure: &mut F) {
    extern "C" fn trampoline<F: FnMut(i32) -> i32>(v: c_int, ud: *mut c_void) -> c_int {
        let f = unsafe { &mut *(ud as *mut F) };
        f(v as i32) as c_int
    }
    let ud = closure as *mut F as *mut c_void;
    unsafe { set_callback(trampoline::<F>, ud); }
}
```

### ffi-17: Use dedicated opaque types instead of c_void

`*mut c_void` is interchangeable with any other `c_void` pointer; distinct handle types should be distinct Rust types so the compiler catches mix-ups.

```rust
// Bad: both handles are *mut c_void; wrong one compiles silently
extern "C" {
    fn create_database() -> *mut c_void;
    fn create_connection() -> *mut c_void;
    fn close_connection(c: *mut c_void);
}

// Good: zero-sized opaque structs give each handle a distinct type
#[repr(C)] pub struct Database { _p: [u8; 0], _m: PhantomData<(*mut u8, PhantomPinned)> }
#[repr(C)] pub struct Connection { _p: [u8; 0], _m: PhantomData<(*mut u8, PhantomPinned)> }
extern "C" {
    fn create_database() -> *mut Database;
    fn create_connection(db: *mut Database) -> *mut Connection;
    fn close_connection(c: *mut Connection);
}
```

### ffi-18: Do not pass trait objects across FFI

`dyn Trait` is a fat pointer (data + vtable) with Rust-specific, unstable layout. Use a function pointer + `user_data` (trampoline) or a manually-built `#[repr(C)]` vtable struct.

```rust
// Bad: dyn Trait is a fat pointer; layout is not C-compatible
extern "C" { fn set_handler(h: *const dyn Handler); }

// Good: function pointer + user_data trampoline
type HandlerFn = extern "C" fn(data: c_int, user_data: *mut c_void);
extern "C" { fn set_handler(handler: HandlerFn, user_data: *mut c_void); }

fn register<H: Handler + 'static>(handler: H) {
    extern "C" fn trampoline<H: Handler>(d: c_int, ud: *mut c_void) {
        let h = unsafe { &*(ud as *const H) };
        h.handle(d as i32);
    }
    let ud = Box::into_raw(Box::new(handler)) as *mut c_void;
    unsafe { set_handler(trampoline::<H>, ud); }
}
```

## I/O Safety

### io-01: Use OwnedFd/BorrowedFd instead of RawFd

Raw file descriptors and handles carry no ownership or validity guarantees. Since Rust 1.63, use `OwnedFd`/`BorrowedFd` (and the Windows `OwnedHandle`/`BorrowedHandle` equivalents) so the type system tracks closing and lifetime.

```rust
// Bad: RawFd has no ownership; caller could have closed it
fn bad_read(fd: RawFd) -> std::io::Result<Vec<u8>> {
    let mut buf = vec![0u8; 1024];
    let n = unsafe { libc::read(fd, buf.as_mut_ptr() as *mut _, buf.len()) };
    if n < 0 { Err(std::io::Error::last_os_error()) } else { buf.truncate(n as usize); Ok(buf) }
}

// Good: BorrowedFd guarantees validity for the borrow's lifetime
fn good_read(fd: BorrowedFd<'_>) -> std::io::Result<Vec<u8>> {
    let mut buf = vec![0u8; 1024];
    let n = unsafe { libc::read(fd.as_raw_fd(), buf.as_mut_ptr() as *mut _, buf.len()) };
    if n < 0 { Err(std::io::Error::last_os_error()) } else { buf.truncate(n as usize); Ok(buf) }
}
```
