---
name: rust-errors
description: "Rust error handling — Result / Option / ? / unwrap / expect / panic, thiserror for libraries, anyhow for applications, error context, and domain-level concerns (retry, backoff, circuit breaker, fallback, transient vs permanent errors, user-facing vs internal errors)."
user-invocable: false
---

# Rust Error Handling

Two layers to keep straight:

- **Language mechanics** — `Result`, `Option`, `?`, `panic!`, `thiserror`, `anyhow`.
- **Domain strategy** — who sees the error, whether to retry, what context to carry.

Most "error handling is painful" pain is actually a design issue in the first layer — an over-broad `Err` type, or a missing context.

## Decide the shape first

| Question | If yes → |
|---|---|
| Can this fail during normal operation? | `Result<T, E>` |
| Is the failure "value is absent" only? | `Option<T>` |
| Is this a bug / invariant violation? | `panic!` / `assert!` / `unreachable!` |
| Is this dev-only or a test? | `unwrap()` / `expect("msg")` is fine |

`unwrap()` in library or app code is almost never the right answer — use `expect("why this cannot be None here")` so the panic message documents the invariant.

## Library vs. application

| Context | Use | Why |
|---|---|---|
| Library crate | `thiserror` | Gives callers an enum they can match on |
| Application / binary | `anyhow` | You're the final consumer; ergonomics win |
| Library with internal helpers | `thiserror` at the boundary, `anyhow` inside | Common and fine |

### thiserror (library)

```rust
#[derive(thiserror::Error, Debug)]
pub enum ParseError {
    #[error("invalid header: {0}")]
    Header(String),

    #[error("I/O error while parsing")]
    Io(#[from] std::io::Error),

    #[error("unexpected EOF at byte {pos}")]
    UnexpectedEof { pos: usize },
}
```

- Use `#[from]` for transparent conversions when the inner error fully explains the failure.
- Use `#[source]` (not `#[from]`) when the outer variant adds its own context and you don't want bare `?` to widen every caller's error type.
- Don't conflate unrelated failure modes into one variant — variants are how callers decide what to do.

### anyhow (application)

```rust
use anyhow::{Context, Result};

fn load_config(path: &Path) -> Result<Config> {
    let bytes = std::fs::read(path)
        .with_context(|| format!("reading config at {}", path.display()))?;
    toml::from_slice(&bytes).context("parsing config as TOML")
}
```

- Add `.context()` / `.with_context()` at every layer where the error crosses a meaningful boundary.
- Use `anyhow!(...)` to construct ad-hoc errors, `bail!(...)` for early returns.
- `anyhow::Error` can wrap any `E: Error + Send + Sync + 'static`.

## Propagation with `?`

```rust
// ? requires the function to return Result<_, E> or Option<T>,
// and the error to be convertible via From.
let config = load_config(path)?;
```

Common hiccups:

| Symptom | Cause | Fix |
|---|---|---|
| "cannot use the `?` operator in a function that returns `()`" | Signature returns `()` | Change return to `Result<(), E>` (or `anyhow::Result<()>`) |
| "`?` couldn't convert" | Missing `From` impl | Implement `From`, use `#[from]` in thiserror, or `.map_err` |
| Errors lose context | Bare `?` everywhere | `.context("...")` at layer boundaries |
| Error enum has 40 variants | Leaking internal failures | Collapse into fewer variants, or use `#[source]` wrapping |

## Panic with care

Valid reasons to panic:

- Invariant violation — something that *cannot* be false if the program is correct.
- `unreachable!()` in exhaustive matches where a variant is statically impossible.
- Early-boot failure where there's nothing meaningful to do (missing config, bad CLI args at startup).

Not valid:

- Network errors, parse errors, missing files — these are `Result`.
- "I'll handle it later." Returning a typed error now is cheaper than removing a panic later.

## Domain-level strategy

Once the mechanics are sound, the design questions are about recovery and audience.

### Classify the failure

| Category | Audience | Recovery | Typical source |
|---|---|---|---|
| Validation | end user | fix input | invalid email, bad JSON |
| Transient | automation | retry | network blip, 503, timeout |
| Permanent | operator / developer | investigate | corrupted data, bad config |
| System | ops / SRE | alert | DB down, disk full |

Encode the category in the error type so callers can branch on it without string-matching:

```rust
#[derive(thiserror::Error, Debug)]
pub enum AppError {
    #[error("invalid input: {0}")]
    Validation(String),

    #[error("upstream temporarily unavailable")]
    Transient(#[source] reqwest::Error),

    #[error("internal error")]
    Internal(#[source] anyhow::Error),
}

impl AppError {
    pub fn is_retryable(&self) -> bool {
        matches!(self, Self::Transient(_))
    }
}
```

### User-facing vs. internal

- Never surface internal errors to end users verbatim — wrap them. The user sees "something went wrong, request id X"; the logs get the full chain.
- Never drop the chain on the way to logging. `tracing::error!(error = ?err, "context")` preserves it.

### Retry / backoff

- Retry **only** transient errors. Validation and permanent errors should fail once, loudly.
- Always cap attempts and bound total wait.
- Exponential backoff + jitter is the default (`tokio-retry`, `backon`, or roll your own).

```rust
// sketch
let mut delay = Duration::from_millis(100);
for attempt in 0..5 {
    match call().await {
        Ok(v) => return Ok(v),
        Err(e) if e.is_retryable() && attempt < 4 => {
            tokio::time::sleep(delay + jitter()).await;
            delay = (delay * 2).min(Duration::from_secs(10));
        }
        Err(e) => return Err(e),
    }
}
```

### Circuit breaker / bulkhead / timeout

Mostly "use a crate" territory:

- **Timeout** — `tokio::time::timeout(d, fut)` around every outbound call.
- **Circuit breaker** — `failsafe`, or a simple counter around the retry logic.
- **Bulkhead** — separate `Semaphore`s or worker pools per dependency so a slow DB doesn't starve HTTP handlers.
- **Fallback** — cache or default value; make sure the caller knows they got the degraded answer.

## Anti-patterns

- `unwrap()` scattered in hot paths — production panics. `expect` with a reason, or `?`.
- `Box<dyn Error>` as a library's public error type — callers can't match on it.
- Returning `anyhow::Error` from a library — leaks `anyhow` as a public dependency and erases types.
- Swallowing errors (`let _ = ...`) without a comment saying why it's safe.
- One `AppError::Internal(String)` variant doing all the work — you've just reinvented stringly-typed errors.
- Retrying validation or permanent errors — wasted budget, no chance of success.
- Exposing stack traces / internal paths to end users.

## When to escalate

| Symptom | Likely real problem |
|---|---|
| Every function returns `Result<_, MyError>` with identical variants | Error type is too broad; split by layer |
| `.context()` strings are identical at every call site | Wrong layer of abstraction — push context into the type |
| Errors need to carry a retry policy | Move policy to the caller; errors describe *what*, not *how* |
| Test code is full of `.unwrap()` noise | Add a small `unwrap_or_panic!` helper or use `anyhow::Result` in tests |
