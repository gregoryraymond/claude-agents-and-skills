---
name: solidjs-core
description: "Foundational SolidJS reactivity model — components run once, signals/effects/memos, tracked vs untracked reads, ownership and disposal. Load for any SolidJS task. Agents: architect, ui-developer, reviewer. Keywords: solid, solidjs, solid-js, signal, createSignal, createEffect, createMemo, onCleanup, untrack, batch, createRoot, reactive, reactivity, getter, tracking scope, fine-grained."
globs: ["**/*.jsx", "**/*.tsx", "**/*.solid.*", "**/solid.config.*", "**/app.config.*"]
allowed-tools: ["Read", "Grep", "Glob", "Edit", "Write"]
---

# SolidJS Core Reactivity

Applies to all SolidJS work. Sibling skills layer on top:
`solidjs-components`, `solidjs-state`, `solidjs-architecture`,
`solidjs-performance`, `solidjs-testing`, `solidjs-review`.

## The one rule everything else follows

**A SolidJS component function runs exactly once.** The JSX it returns contains
reactive expressions that re-run on their own. This is *not* React — no re-render,
no render-loop, no `useMemo`-for-correctness. Reactivity lives at the signal
level, not the component level.

Consequence: any code placed in the body of the component runs once at setup
time. To make something react to a signal, it must be inside a **tracking scope**:
JSX, `createEffect`, `createMemo`, `createResource`, render-prop children of
`<For>` / `<Show>`, etc.

```jsx
// ❌ runs once at setup, never updates
const doubled = count() * 2;

// ✅ function = reactive expression, tracked when called inside JSX/effect/memo
const doubled = () => count() * 2;

// ✅ cached derivation, also tracked
const doubled = createMemo(() => count() * 2);
```

## Primitives quick reference

| Primitive | Purpose | Returns |
|---|---|---|
| `createSignal(v)` | Reactive leaf state | `[get, set]` — `get()` is a getter |
| `createMemo(fn)` | Cached derived value | getter `fn()` (memoized) |
| `createEffect(fn)` | Side effect after render | void (runs when deps change) |
| `createRenderEffect(fn)` | Side effect before paint | void (SSR-safe, layout timing) |
| `createResource(src, fetcher)` | Async data + Suspense hook | `[resource, { refetch, mutate }]` |
| `createStore(obj)` | Fine-grained nested state | `[store, setStore]` (proxy) |
| `onMount(fn)` | Run once after initial render | void |
| `onCleanup(fn)` | Register disposer | void |
| `batch(fn)` | Coalesce multiple writes | passthrough |
| `untrack(fn)` | Read without subscribing | `fn()` |

## Derive, don't sync

If state B is a function of state A, **derive** it — don't use an effect to copy
A into B.

```jsx
// ❌ extra signal, extra update, glitchy
const [full, setFull] = createSignal("");
createEffect(() => setFull(`${first()} ${last()}`));

// ✅ derived getter
const full = () => `${first()} ${last()}`;

// ✅ memo when the computation is expensive or read many times
const full = createMemo(() => `${first()} ${last()}`);
```

`createEffect` is for **side effects that leave Solid's graph** — DOM
imperatives, logging, analytics, third-party libs. Almost never for data flow.

## When to reach for `createMemo`

`createMemo` costs: an extra node in the graph. Reach for it when any hold:

1. Computation is expensive (big loops, JSON parse, heavy format).
2. Result is read by multiple tracking scopes and you want one evaluation.
3. The result is **referentially stable** input to `<For>`, a child prop, or
   another memo, and you need identity stability.
4. It acts as a reactivity filter (downstream only re-runs when output changes,
   not on every upstream tick).

Otherwise a plain `() =>` getter is cheaper and idiomatic.

## Tracking scope traps

```jsx
// ❌ signal read in setTimeout is outside any tracking scope
createEffect(() => {
  setTimeout(() => console.log(count()), 1000);
});

// ✅ read once, closure captures the value
createEffect(() => {
  const c = count();
  setTimeout(() => console.log(c), 1000);
});

// ❌ untrack hides the read — effect won't re-run on count changes
createEffect(() => untrack(() => doThing(count())));
```

## `batch` and `untrack`

- `batch(() => { ... })` — multiple signal writes inside collapse to one update
  downstream. Use when a single event causes several related writes.
- `untrack(() => ...)` — read a signal without subscribing to it. Use when an
  effect legitimately needs the *current value* but shouldn't re-run when it
  changes.

```jsx
batch(() => {
  setFirst("Ada");
  setLast("Lovelace");
});  // one downstream update, not two

createEffect(() => {
  const id = userId();          // tracked
  const token = untrack(auth);  // current value, not subscribed
  sendTo(id, token);
});
```

## Ownership, disposal, `createRoot`

Every reactive computation is owned by the nearest parent computation (or
component). When the owner disposes, children dispose too — that's how
`onCleanup` fires.

- Creating signals/effects **outside** any component or `createRoot` leaks them
  and triggers the "computations created outside a `createRoot`" warning.
- Module-level singletons need `createRoot(dispose => { ... })` to anchor their
  graph.
- Use `onCleanup(() => …)` for timers, event listeners, subscriptions — it runs
  when the owning component unmounts or the effect re-runs.

```jsx
function Ticker() {
  const [n, setN] = createSignal(0);
  const id = setInterval(() => setN(n() + 1), 1000);
  onCleanup(() => clearInterval(id));
  return <p>{n()}</p>;
}
```

## Signals vs. stores — the 30-second rule

- `createSignal` for primitives, single values, things you replace wholesale.
- `createStore` for objects/arrays where consumers read individual fields and
  you want field-level reactivity. See `solidjs-state` for depth.

## Common confusions coming from React

| React mental model | Solid reality |
|---|---|
| Component re-renders on state change | Component runs once; JSX expressions re-run |
| `useMemo` for stable references | `createMemo` for caching + identity |
| `useEffect(() => …, [deps])` | `createEffect` — deps auto-tracked, no array |
| `useState` returns `[value, setter]` | `createSignal` returns `[getter, setter]` — `count`, not `count()` |
| `useCallback` | Not needed — functions don't re-create |
| `key` prop on lists | `<For>` is keyed by reference automatically |
| Context triggers re-render | Context is just a signal — no extra re-render |

## Quick triage

1. "My component doesn't update" → a signal read is outside a tracking scope
   (destructured, assigned to a const, used in a timeout, etc.).
2. "My effect fires too often" → `untrack` the reads that shouldn't trigger.
3. "My effect fires once then never" → you're reading props/signals without
   calling them (missing `()`), or you destructured props.
4. "My list re-creates every item" → use `<For>` (keyed) or `<Index>` (by
   position) instead of `.map`.

## Sources

- [Solid Docs — Reactivity](https://docs.solidjs.com/concepts/intro-to-reactivity)
- [Solid Docs — createMemo](https://docs.solidjs.com/reference/basic-reactivity/create-memo)
- [Solid Docs — batch](https://docs.solidjs.com/reference/reactive-utilities/batch)
- [Brenley — Solid.js Best Practices](https://www.brenelz.com/posts/solid-js-best-practices/)
- [OpenReplay — Best Practices for Working with SolidJS](https://blog.openreplay.com/solidjs-best-practices/)
