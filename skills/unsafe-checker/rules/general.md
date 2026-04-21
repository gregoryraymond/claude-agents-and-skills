# General Principles

Foundational principles governing when and why to reach for `unsafe`. These apply before any specific technical rule: unsafe is a last resort, not a convenience or a performance shortcut, and its presence must remain visible in APIs.

### general-01: Do not abuse unsafe to escape compiler safety checks

Unsafe Rust is not an escape hatch from the borrow checker. Using it to bypass safety mechanisms defeats Rust's guarantees and invites undefined behavior; legitimate uses are FFI, low-level abstractions, and measured performance work.

```rust
// Bad: unsafe used to fabricate aliasing &mut references (UB)
let ptr = data.as_mut_ptr();
unsafe {
    let ref1 = &mut *ptr;
    let ref2 = &mut *ptr;
    *ref1 = 10;
    *ref2 = 20;
}

// Good: work with the borrow checker, or use interior mutability
data[0] = 10;
data[0] = 20;

let data = RefCell::new(vec![1, 2, 3]);
data.borrow_mut()[0] = 10;
```

### general-02: Do not blindly use unsafe for performance

Don't assume `unsafe` is faster. LLVM often removes bounds checks on safe iteration, and unsafe can actually inhibit optimization by breaking aliasing assumptions. Benchmark and profile the safe version first.

```rust
// Bad: unnecessary unsafe; iter-based sum is at least as fast
fn sum_bad(slice: &[i32]) -> i32 {
    let mut sum = 0;
    for i in 0..slice.len() {
        unsafe { sum += *slice.get_unchecked(i); }
    }
    sum
}

// Good: idiomatic safe version the optimizer handles well
fn sum_good(slice: &[i32]) -> i32 {
    slice.iter().sum()
}
```

### general-03: Do not create aliases for types/methods named "unsafe"

The word `unsafe` signals that extra scrutiny is required. Hiding it behind type aliases, safe-looking wrappers, or renamed re-exports makes review harder and invites misuse.

```rust
// Bad: unsafety hidden behind friendly names
type SafePointer = *mut u8;
pub fn get_value(ptr: *const i32) -> i32 { unsafe { *ptr } }
pub use std::mem::transmute as convert;

// Good: unsafe stays visible, or a real safety contract is enforced
pub unsafe fn get_value_unchecked(ptr: *const i32) -> i32 { *ptr }

pub fn get_value_checked(ptr: *const i32) -> Option<i32> {
    if ptr.is_null() { None }
    // SAFETY: null-checked above
    else { Some(unsafe { *ptr }) }
}

type RawHandle = *mut c_void; // "Raw" signals potential unsafety
```
