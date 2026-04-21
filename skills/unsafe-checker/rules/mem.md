# Memory Layout

Rules covering struct/enum layout, cross-process and foreign-allocator boundaries, reentrancy of C calls, bitfield handling, and uninitialized memory. Apply these when interfacing with C, packing binary data, or managing memory that Rust's allocator did not produce.

### mem-01: Choose appropriate data layout

Rust's default layout is unspecified. Use `#[repr(C)]` for FFI, `#[repr(transparent)]` for newtypes, `#[repr(packed)]` (carefully) for no padding, `#[repr(align(N))]` for alignment, and `#[repr(u8)]` etc. for enum discriminants.

```rust
// Bad: default repr gives no layout guarantees; &packed field creates unaligned ref (UB)
struct BadFFI { a: u8, b: u32, c: u8 }

#[repr(packed)]
struct Dangerous { a: u8, b: u32 }
fn bad(d: &Dangerous) -> &u32 { &d.b } // UB: unaligned reference

// Good: repr(C) fixes field order; read_unaligned for packed access
#[repr(C)]
struct GoodFFI { a: u8, b: u32, c: u8 }

#[repr(transparent)]
struct Wrapper(u32);

#[repr(C, packed)]
struct PackedData { header: u8, value: u32 }
impl PackedData {
    fn value(&self) -> u32 {
        let ptr = std::ptr::addr_of!(self.value);
        unsafe { ptr.read_unaligned() }
    }
}

#[repr(u8)]
enum Status { Ok = 0, Error = 1 }
```

### mem-02: Do not modify memory of other processes or dynamic libraries

Other processes have separate address spaces; their pointers are meaningless in ours. Use proper IPC, shared-memory primitives, or documented FFI entry points instead of poking raw addresses or mutable library statics.

```rust
// Bad: foreign pointer in our address space; mutating a library's static breaks its invariants
fn bad_cross_process(ptr: *mut i32) {
    unsafe { *ptr = 42; } // UB or crash
}
extern "C" { static mut LIBRARY_INTERNAL: i32; }
fn bad_lib() { unsafe { LIBRARY_INTERNAL = 100; } }

// Good: use IPC / the library's own API
use std::io::Write;
use std::os::unix::net::UnixStream;
fn ipc() -> std::io::Result<()> {
    let mut s = UnixStream::connect("/tmp/socket")?;
    s.write_all(b"message")
}

mod ffi { extern "C" { pub fn library_set_value(v: i32); } }
fn proper() { unsafe { ffi::library_set_value(42); } }
```

### mem-03: Do not let String/Vec/Box auto-drop foreign memory

`String`, `Vec`, and `Box` call Rust's global deallocator on drop. Constructing them from `malloc`'d, mmap'd, or otherwise foreign memory causes UB when they drop. Copy the data, or use a wrapper whose `Drop` calls the correct free function.

```rust
// Bad: String/Vec/Box will free with the wrong allocator
extern "C" { fn c_get_string() -> *mut std::os::raw::c_char; }
fn bad() -> String {
    unsafe {
        let ptr = c_get_string();
        String::from_raw_parts(ptr as *mut u8, 0, 0) // Rust allocator will free C memory
    }
}
fn bad_box(shared: *mut u8) -> Box<u8> { unsafe { Box::from_raw(shared) } }

// Good: copy into a Rust allocation, or wrap with a correct Drop
use std::ffi::CStr;
extern "C" { fn c_free_string(s: *mut std::os::raw::c_char); }
fn good() -> String {
    unsafe {
        let ptr = c_get_string();
        let out = CStr::from_ptr(ptr).to_string_lossy().into_owned();
        c_free_string(ptr);
        out
    }
}

struct COwned { ptr: *mut std::os::raw::c_char }
impl Drop for COwned {
    fn drop(&mut self) { unsafe { c_free_string(self.ptr); } }
}
```

### mem-04: Prefer reentrant C APIs and syscalls

Many C functions (`strtok`, `localtime`, `rand`, `strerror`, `readdir`, `gethostbyname`) use static buffers or global state and race across threads. Use the `_r` variants, or better, a Rust standard-library / crate equivalent.

```rust
// Bad: non-reentrant C calls race in multithreaded code
extern "C" {
    fn strtok(s: *mut i8, d: *const i8) -> *mut i8;
    fn rand() -> i32;
}
fn bad(s: &mut [i8]) {
    let d = b" \0".as_ptr() as *const i8;
    unsafe { strtok(s.as_mut_ptr(), d); } // static buffer
}

// Good: reentrant variants, or Rust stdlib
extern "C" {
    fn strtok_r(s: *mut i8, d: *const i8, save: *mut *mut i8) -> *mut i8;
    fn rand_r(seed: *mut u32) -> i32;
}
fn good(s: &mut [i8]) {
    let d = b" \0".as_ptr() as *const i8;
    let mut save: *mut i8 = std::ptr::null_mut();
    unsafe { strtok_r(s.as_mut_ptr(), d, &mut save); }
}
fn best_random() -> u32 {
    use rand::Rng;
    rand::thread_rng().gen() // thread-safe
}
```

### mem-05: Use third-party crates for bitfields

Manual shift/mask code is easy to get wrong (offsets, masks, endianness). Use `bitflags` for flag sets, `modular-bitfield` or `packed_struct` for packed fields, `bitvec` for arbitrary bit arrays, `deku` for binary parsing.

```rust
// Bad: hand-rolled masks are error-prone (easy to forget the !, wrong shift)
struct Flags(u32);
impl Flags {
    const READ: u32 = 1 << 0;
    fn clear_read(&mut self) { self.0 &= !Self::READ; }
    fn version(&self) -> u8 { ((self.0 >> 24) & 0xFF) as u8 }
}

// Good: type-safe, tested abstractions
use bitflags::bitflags;
bitflags! {
    #[derive(Debug, Clone, Copy, PartialEq, Eq)]
    struct Flags: u32 {
        const READ    = 1 << 0;
        const WRITE   = 1 << 1;
        const EXECUTE = 1 << 2;
    }
}

use modular_bitfield::prelude::*;
#[bitfield]
#[repr(C)]
struct PackedHeader {
    tag: B8,
    flags: B16,
    version: B8,
}
```

### mem-06: MaybeUninit (clippy: uninit_assumed_init, uninit_vec)

Use `MaybeUninit<T>` for delayed initialization. `mem::uninitialized()` is deprecated UB; `mem::zeroed()` is UB for any type where the all-zero bit pattern is invalid (references, `NonZero*`, `bool`, enums). Never `set_len` on a `Vec` past initialized elements.

```rust
// Bad: deprecated uninitialized; zeroed on types with invalid zero; set_len over uninit
fn bad_uninit<T>() -> T { unsafe { std::mem::uninitialized() } }
fn bad_zeroed() -> &'static str { unsafe { std::mem::zeroed() } } // null ref: UB
fn bad_vec() -> Vec<String> {
    let mut v = Vec::with_capacity(10);
    unsafe { v.set_len(10); } // elements uninit: UB on drop
    v
}

// Good: MaybeUninit to stage, then assume_init after every slot is written
use std::mem::MaybeUninit;
fn good_array() -> [String; 10] {
    let mut arr: [MaybeUninit<String>; 10] = [const { MaybeUninit::uninit() }; 10];
    for (i, elem) in arr.iter_mut().enumerate() {
        elem.write(format!("item {}", i));
    }
    // SAFETY: every slot was written above
    unsafe { MaybeUninit::array_assume_init(arr) }
}

fn good_vec() -> Vec<u8> {
    let mut v = Vec::with_capacity(1024);
    v.resize(1024, 0); // or write into spare_capacity_mut then set_len
    v
}
```
