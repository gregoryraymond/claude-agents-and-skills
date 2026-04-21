---
name: rust-concurrency
description: "Rust concurrency and async — threads vs async, Send / Sync, tokio, channels (mpsc / oneshot / broadcast / watch), Mutex / RwLock / Atomic, tokio::spawn / spawn_local / spawn_blocking, Future not Send errors, deadlock / lock-across-await, rayon for CPU parallelism."
user-invocable: false
---

# Rust Concurrency & Async

Two broad regimes — **threads** (`std::thread`, `rayon`) for CPU-bound work, and **async** (`tokio`, rarely `async-std` / `smol`) for I/O-bound work. Don't mix metaphors: don't `thread::sleep` in async code, don't run a CPU-heavy loop inside an async task.

## Pick the regime

| Workload | Choose | Why |
|---|---|---|
| CPU-bound (compute, parsing, codec) | `std::thread` or `rayon` | No async value — work is never idle |
| I/O-bound (network, disk, DB) | `async` + `tokio` | Thousands of concurrent awaits on one thread |
| Mixed (async with occasional CPU bursts) | `tokio` + `spawn_blocking` | Keep the async runtime responsive |
| Embarrassingly parallel on a `Vec` | `rayon` (`par_iter`) | Data-parallel, zero-ceremony |

## Send and Sync

- **`Send`** — value can be transferred to another thread.
- **`Sync`** — `&T` can be shared across threads (equivalent to `&T: Send`).
- Both are auto-traits: they're derived automatically unless something inside opts out.
- Common opt-outs: `Rc<T>` (`!Send`, `!Sync`), `RefCell<T>` (`!Sync`), raw pointers (`!Send` / `!Sync`).

Typical errors and what they really mean:

| Error | Real problem | Fix |
|---|---|---|
| `Rc<T>` cannot be sent between threads | You put an `Rc` in an `async` task or a spawned thread | Use `Arc<T>` |
| `RefCell<T>` cannot be shared between threads | You put a `RefCell` in an `Arc` | Use `Arc<Mutex<T>>` or `Arc<RwLock<T>>` |
| future is not `Send` | Something `!Send` lives across a `.await` | Drop it before `.await`, scope it tighter, or use `tokio::task::spawn_local` on a LocalSet |
| `MutexGuard<'_, T>` cannot be sent | You held a lock across `.await` | Release the lock before `.await` |

## Shared state

| Pattern | When |
|---|---|
| Nothing shared — each task owns its data | Default; aim for this |
| `Arc<T>` | Shared immutable data (config, tables) |
| `Arc<Mutex<T>>` | Shared mutable, general purpose |
| `Arc<RwLock<T>>` | Shared mutable, many readers / few writers |
| `Arc<AtomicUsize>` etc. | Counters, flags, sequence numbers |
| `tokio::sync::Mutex` | Lock must be held across `.await` |
| `tokio::sync::RwLock` | Same, read-heavy |
| Channels | Pass ownership around instead of sharing |

Reach for channels before `Arc<Mutex<_>>` — often the cleanest refactor.

### Lock across await: don't

```rust
// Bad — std::sync::MutexGuard is !Send, future isn't Send either
let guard = mutex.lock().unwrap();
fetch(&guard.url).await;

// Fix 1: drop the guard first
let url = { mutex.lock().unwrap().url.clone() };
fetch(&url).await;

// Fix 2: use tokio::sync::Mutex if the lock genuinely needs
// to stay held across awaits (rarely the right answer).
```

## Channels (tokio)

| Channel | Shape | Use when |
|---|---|---|
| `mpsc` | many producers, one consumer | Work queue, task funnel |
| `oneshot` | one value, one time | Request/response, cancellation |
| `broadcast` | many producers, many consumers, every receiver sees every message | Event fan-out |
| `watch` | many producers, many consumers, only latest value | Config/state propagation |

For `std::sync::mpsc`, use only in sync code.

## Spawning in tokio

| API | Use for |
|---|---|
| `tokio::spawn(fut)` | Default. `Send` future goes on any worker. |
| `tokio::task::spawn_local(fut)` | `!Send` future; requires a `LocalSet`. |
| `tokio::task::spawn_blocking(f)` | Sync/CPU work called from async; moves to the blocking pool. |
| `tokio::task::block_in_place(f)` | Rare; run blocking code on the current worker (multi-thread runtime only). |

Never call `std::thread::sleep` or blocking I/O directly inside an async task — you stall the whole executor.

## CPU parallelism with rayon

```rust
use rayon::prelude::*;
let sum: u64 = data.par_iter().map(|x| expensive(x)).sum();
```

Rayon is great for data-parallel workloads. It's not a replacement for async — if your bottleneck is I/O, rayon doesn't help.

## Deadlocks — how to avoid

- **Consistent lock order.** If any code path locks `A then B`, no path may lock `B then A`.
- **Hold locks for the minimum time.** Copy out what you need, drop the guard, then do the expensive work.
- **Avoid callbacks under a lock.** User code called while holding a lock is the most common deadlock source.
- **Never acquire two locks in async without thinking.** Each `.await` is a scheduling point.

## Quick decision tree

```
Is the work CPU-bound?
├─ yes → rayon::par_iter / std::thread
└─ no
   │
   I/O-bound? (network, disk, DB)
   ├─ yes → tokio async
   └─ mixed → tokio + spawn_blocking for CPU bits
```

## Anti-patterns

- `Arc<Mutex<HashMap<_, _>>>` as a global app-state — almost always a message-passing task would be cleaner.
- `thread::sleep` inside an async task — stalls the whole runtime worker.
- Holding any lock across `.await` — turns a parallel program into an accidentally serial one.
- `spawn_blocking` for work that's not actually blocking — wastes blocking-pool threads.
- `block_on` inside async code — deadlocks when the reactor is needed.
- `Rc<RefCell<T>>` reached for by reflex in async code — use `Arc<Mutex<T>>` *or* restructure to not share.
- Implementing your own futures / pollers — 99% of the time, combinators + channels are enough.
- Using `async-std` in new code — `tokio` is the de-facto standard; async-std is effectively unmaintained.

## When to escalate

| Symptom | Likely real problem |
|---|---|
| "future is not `Send`" after every change | `!Send` type being held across awaits — search for `Rc` / `RefCell` / `MutexGuard` near `.await` |
| Lock contention dominating profile | Sharing too much; split data, move to message passing, or per-task state |
| Async tasks stalling each other | Something blocking is running in an async context — move it to `spawn_blocking` |
| Deadlock under load | Inconsistent lock order; add logging around `lock()` calls, then fix the ordering |
