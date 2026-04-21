---
name: solidjs-performance
description: "SolidJS performance anti-patterns, reactivity loss, and when to use batch/untrack/memo. Use when diagnosing slowness, unnecessary re-runs, 'component doesn't update' bugs, or reviewing hot paths. Primary agents: ui-developer, reviewer. Keywords: solidjs performance, slow, unnecessary render, not updating, reactivity lost, memo vs function, batch, untrack, For vs Index, keyed, waterfall, bundle size, lazy, Suspense, hydration."
globs: ["**/*.jsx", "**/*.tsx"]
allowed-tools: ["Read", "Grep", "Glob", "Edit", "Write"]
---

# SolidJS Performance & Reactivity Pitfalls

Pair with `solidjs-core`. This skill is a **diagnostic checklist** for "it's
slow" or "it's not updating" in SolidJS code.

## Top 10 anti-patterns (ranked by how often they bite)

### 1. Destructured props

```jsx
// ❌ dead value
function Row({ name, qty }) { return <td>{name} × {qty}</td>; }

// ✅ keep the proxy alive
function Row(props) { return <td>{props.name} × {props.qty}</td>; }
```

### 2. Reading a signal outside a tracking scope

```jsx
// ❌ evaluated once at setup
const label = `Count: ${count()}`;

// ✅ getter — evaluated lazily, tracked in JSX
const label = () => `Count: ${count()}`;
```

### 3. `.map()` instead of `<For>`

```jsx
// ❌ recreates every child on every tick
<ul>{items().map(i => <Row item={i} />)}</ul>

// ✅ keyed, reuses DOM, stable identity
<ul><For each={items()}>{(i) => <Row item={i} />}</For></ul>
```

### 4. Ternary instead of `<Show>`

```jsx
// ❌ re-creates subtree each time `user()` identity changes
{user() ? <Profile u={user()} /> : <Login />}

// ✅ preserves identity, integrates with Suspense
<Show when={user()} fallback={<Login />}>
  {(u) => <Profile u={u()} />}
</Show>
```

### 5. Using `createEffect` for data sync

```jsx
// ❌ extra signal, extra update, risk of glitches
const [full, setFull] = createSignal("");
createEffect(() => setFull(`${first()} ${last()}`));

// ✅ derive directly
const full = () => `${first()} ${last()}`;
```

### 6. Wholesale store replacement

```jsx
// ❌ destroys identity — every consumer re-runs
setCart({ ...cart, items: newItems });

// ✅ targeted set, keeps identity
setCart("items", newItems);

// ✅ or diff against prev
setCart(reconcile(nextCart, { key: "id" }));
```

### 7. Passing a signal getter as a prop

```jsx
// ❌ child has to know it's a signal and call it
<Child value={count} />

// ✅ call it — reactive expression re-runs at the prop site
<Child value={count()} />
```

### 8. Missing `createMemo` on expensive shared derivation

```jsx
// ❌ recomputed per consumer, per tick
const visible = () => items().filter(heavyPredicate);

// ✅ computed once per dep change
const visible = createMemo(() => items().filter(heavyPredicate));
```

Rule: if it's expensive **and** read >1 place, memo it. Otherwise a function
getter is lighter.

### 9. Multiple writes outside `batch`

```jsx
// ❌ two downstream updates
setFirst("Ada"); setLast("Lovelace");

// ✅ one
batch(() => { setFirst("Ada"); setLast("Lovelace"); });
```

Event handlers / async callbacks doing >1 related write almost always want
`batch`.

### 10. Over-reading `props.children`

```jsx
// ❌ re-evaluates the child expression each read
function Layout(props) {
  return <>{props.children}{condition() && props.children}</>;
}

// ✅ memoize via helper
function Layout(props) {
  const c = children(() => props.children);
  return <>{c()}<Show when={condition()}>{c()}</Show></>;
}
```

## `<For>` vs `<Index>` — choose correctly

| Situation | Use |
|---|---|
| List of objects that can be reordered / added / removed | `<For>` (keyed by reference) |
| Fixed-length positional data (heatmap, matrix, page cells) | `<Index>` |
| Primitives that change in-place and order is stable | `<Index>` |
| Need the index as a reactive accessor | `<For>` (`i()`) |
| Want plain numeric index | `<Index>` (`i`) |

Using `<For>` where `<Index>` fits (or vice-versa) wastes DOM work — one
creates/destroys nodes, the other updates text content in place.

## `createMemo` — when it's worth it

Reach for `createMemo` when:

1. The derivation is **expensive** (O(n) over big arrays, deep formatting,
   JSON work).
2. The same derivation is **read by multiple tracking scopes**.
3. You need **referential stability** (downstream memos, `<For>` keys, props
   passed to children that compare by identity).
4. It acts as a **reactivity filter**: upstream signal flips often, but the
   derived result flips rarely — memo dedupes downstream updates.

Don't memo cheap pure expressions — a plain getter is lighter, no graph node.

## Async performance

### Waterfalls

A waterfall happens when request B only starts after A resolves because B
reads A's data. Use `Promise.all` in a single fetcher, or hoist independent
`createResource` calls to the same component.

```tsx
// ❌ waterfall
const [user] = createResource(fetchUser);
const [orders] = createResource(() => user()?.id, fetchOrders);

// ✅ parallel when the dep isn't real
const [user] = createResource(fetchUser);
const [orders] = createResource(fetchAllOrders); // fetches concurrently
```

### Preloading

In SolidStart, export a `route.preload` (or use route-level `query` preload)
so data fetching overlaps with code loading.

### Lazy components

```tsx
import { lazy } from "solid-js";
const Heavy = lazy(() => import("./Heavy"));
// wrap the consumer in <Suspense> for the loading state
```

Split at: route boundaries, rarely-used modals, admin-only panels, anything
with heavy deps (charts, editors, WYSIWYG).

## Hydration / SSR footguns

- Module-level signals leak state across SSR requests — wrap in a provider or
  `createRoot`.
- Rendering random values (`Math.random`, `Date.now`) causes mismatch —
  compute on the server only, or wrap with `<ClientOnly>` / `isServer`.
- `onMount` / `onCleanup` fire only on the client — do SSR-relevant work in
  the component body or `createRenderEffect`.

## Measuring

1. **Solid DevTools** (`solid-devtools` package) — shows the graph, marks
   re-runs, tracks tick counts.
2. Browser perf tab — Solid's work shows up as tiny ticks between DOM updates;
   compare before/after.
3. `console.log` inside `createEffect` — if it fires more than you expect,
   check which signals are tracked. Use `untrack()` to exclude ones that
   shouldn't.

## Bundle size

Solid starts small (~7–10 KB). To keep it that way:

- Prefer standard library primitives over heavy frameworks for forms/state.
- Tree-shake `solid-js/store`, `solid-js/web` etc. by importing subpaths.
- Code-split route bundles; lazy-load rarely hit routes.
- Audit with `vite-bundle-visualizer` or `rollup-plugin-visualizer`.

## Diagnostic flowchart

```
"Something re-runs too often"
  → wrap offending reads in untrack(), or
  → filter upstream with createMemo, or
  → move the effect's work inside a batch()

"Something doesn't update"
  → check for destructured props
  → check for signal read outside JSX/effect/memo
  → check prop is called (props.x not x)
  → check store update used path, not wholesale replace

"List is janky on reorder"
  → likely using .map() — switch to <For>
  → or using <For> where <Index> would keep DOM stable

"Slow first paint"
  → preload critical data in route.preload
  → lazy-load non-critical components
  → verify Suspense boundaries are at the right level

"Memory grows over time"
  → missing onCleanup for timers / listeners / subscriptions
  → signals created outside createRoot at module scope
```

## Sources

- [Solid Docs — createMemo](https://docs.solidjs.com/reference/basic-reactivity/create-memo)
- [Solid Docs — batch](https://docs.solidjs.com/reference/reactive-utilities/batch)
- [Solid Docs — For vs Index](https://docs.solidjs.com/concepts/control-flow/list)
- [Brenley — Solid.js Best Practices](https://www.brenelz.com/posts/solid-js-best-practices/)
- [OpenReplay — Best Practices for Working with SolidJS](https://blog.openreplay.com/solidjs-best-practices/)
- [DEV — The zen of state in Solid.js](https://dev.to/lexlohr/the-zen-of-state-in-solidjs-22lj)
