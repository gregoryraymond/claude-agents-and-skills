---
name: rust-performance
description: "Rust performance — profiling (perf, flamegraph, samply), benchmarking (criterion, cargo bench), reducing allocations, cache-friendly data layout, iterator chains, SIMD, release-mode measurement, rayon parallelism."
user-invocable: false
---

# Rust Performance

Rule zero: **measure before optimizing, measure after optimizing, benchmark in `--release`.** Debug-mode numbers are meaningless for perf work.

## Priority ladder

Work from the top. Lower items rarely matter if higher items are wrong.

| Tier | Leverage | Example |
|---|---|---|
| 1. Algorithm / data structure | 10×–1000× | `HashSet` instead of `Vec::contains`; O(n log n) instead of O(n²) |
| 2. Allocation | 2×–5× | `Vec::with_capacity`, reuse buffers, avoid `.clone()` in loops |
| 3. Cache locality | 1.5×–3× | `Vec<T>` over `LinkedList<T>`; AoS vs SoA |
| 4. Parallelism | up to core count | `rayon::par_iter` |
| 5. SIMD / intrinsics | 2×–8× | Usually via `std::simd` (nightly) or hand-rolled portable SIMD; rare |

## Profile first

| Tool | What it tells you |
|---|---|
| `cargo flamegraph` (Linux/macOS) | Where CPU time goes, visualized |
| `samply` | Cross-platform sampling profiler, views in Firefox profiler UI |
| `perf record` + `perf report` (Linux) | Hardware-counter accuracy |
| Instruments (macOS) | GUI sampler, allocation tracker |
| `dhat` / `heaptrack` | Allocation hotspots |
| `cargo bench` + `criterion` | Reproducible micro-benchmarks with statistics |

Always compile with release profile settings you care about for production — `lto`, `codegen-units = 1`, `opt-level = 3`. Benchmarks with default release settings can be 10–30% off from what ships.

```toml
# Cargo.toml
[profile.release]
lto = "fat"
codegen-units = 1
panic = "abort"       # smaller + faster if you don't use unwinding
```

For perf work specifically, add a separate profile with debug symbols:

```toml
[profile.release-with-debug]
inherits = "release"
debug = true
```

## Measuring correctly

- **No debug mode.** `--release` always.
- **Pin the CPU governor** on Linux (`cpupower frequency-set -g performance`) before benchmarking.
- **Run several times.** Criterion handles this; if you roll your own, look at percentiles, not a single number.
- **Compare like-for-like.** Same input, same warmup, same thread count.
- **Beware `black_box`.** Without it, the compiler will constant-fold or dead-code-eliminate your benchmark body.

## Common wins

### Allocation

| Hot-path smell | Fix |
|---|---|
| `vec.push` in a sized loop | `Vec::with_capacity(n)` |
| `String::new()` then many `push_str` | `String::with_capacity` or `format!` once |
| Building a `Vec` to iterate once | Chain the iterators — `collect` only if you need random access / multiple passes |
| `.clone()` in inner loop | Hoist out, or switch to `&T` / `Cow<'_, T>` |
| `format!` on a known short string | `write!(buf, ...)` into a reused buffer |

### Data layout

- `Vec<T>` beats `LinkedList<T>` in virtually every real-world benchmark.
- Prefer struct-of-arrays (`Vec<A>, Vec<B>`) over array-of-structs for SIMD-friendly hot loops.
- `SmallVec<[T; N]>` avoids heap for common small sizes.
- For tiny sets: linear search in a `Vec` beats `HashSet` up to ~32 elements.
- For fixed-size lookup tables, arrays (`[T; N]`) beat `Vec<T>`.

### Iterator chains

Rust iterator chains compile to the same code as hand-written loops, usually — but only when they're not interrupted by `collect`-and-re-iterate. Fuse into one chain where possible.

### Parallelism

`rayon::prelude::*;` + `par_iter()` is almost free for embarrassingly parallel loops. Don't reach for threads manually until you've tried rayon.

### Async isn't perf

`async` is for I/O concurrency, not CPU performance. Making a CPU loop `async` just adds poll overhead. Use threads or rayon for compute.

## Things that rarely pay off

- Hand-unrolling loops that LLVM already unrolls.
- Manual bit-twiddling where a match on an enum is just as fast and clearer.
- `#[inline(always)]` everywhere — usually makes code bigger without helping; let the compiler decide unless the profile says otherwise.
- Custom allocators (global) — only worth it after you've proven allocation is the bottleneck *and* pool/arena strategies at the call site didn't help.
- Micro-optimizing one function before looking at the flamegraph.

## Anti-patterns

- "I optimized it, should be faster now." — not without a before/after number.
- Benchmarking in debug mode — meaningless.
- Optimizing clone-heavy code by replacing `Vec` with `LinkedList` — makes it slower.
- Adding `unsafe` for performance before trying safe options — usually a rounding error on the profile.
- Premature `SIMD` / `#[target_feature]` — correctness first, always-portable baseline first.
- Parallelizing a memory-bound loop — many cores competing for the same cache line is slower than one.

## When to escalate

| Symptom | Look at |
|---|---|
| Flamegraph dominated by `malloc` / `free` | Allocation; try `with_capacity`, buffer reuse, arenas |
| Flamegraph dominated by one function, flat | Algorithmic — is this O(n²) when O(n) is possible? |
| High CPU, low instructions per cycle | Cache / memory stalls; look at data layout |
| Nothing on the flamegraph is hot | Workload is I/O-bound; perf work is in the I/O path, not the CPU path |
| Parallel version slower than serial | False sharing, or over-subscribed cores, or synchronization overhead exceeding parallelism gain |
