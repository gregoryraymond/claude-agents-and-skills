---
name: solidjs-review
description: "Code-review checklist for SolidJS changes — reactivity correctness, props handling, control flow, data loading, structure, a11y, tests. Use when reviewing a PR or auditing SolidJS code. Primary agent: reviewer. Keywords: solidjs review, pr review, code review, checklist, audit, sign off, solidjs lint, does this look right, anti-pattern, regressions."
globs: ["**/*.jsx", "**/*.tsx"]
allowed-tools: ["Read", "Grep", "Glob"]
---

# SolidJS Reviewer Checklist

Use as the punch list when reviewing SolidJS / SolidStart PRs. Cross-reference
`solidjs-core`, `solidjs-components`, `solidjs-state`, `solidjs-performance`,
and `solidjs-testing` for depth on any item.

## 1. Reactivity correctness (block if broken)

- [ ] **No destructured props.** `const { x } = props` or `function C({ x })`
      is a reactivity leak. Allowed exception: `splitProps`.
- [ ] **Signals are called as getters** everywhere they're read
      (`count()`, not `count`). Flag any `<Child prop={signal}>` where the
      child clearly expects a value.
- [ ] **Signal reads live inside tracking scopes** — JSX, `createEffect`,
      `createMemo`, `createResource`, control-flow component children. No
      reads in plain `const` initializers or outside callbacks.
- [ ] **Derived values are derived**, not synced via effects. `createEffect`
      that only calls `setOther(…)` = refactor to a function or `createMemo`.
- [ ] **Stores are updated by path or via `produce`**, not wholesale spread
      replacement.

## 2. Control flow

- [ ] Conditional rendering uses `<Show>` (with `fallback`, `keyed` as needed),
      not `cond && <X/>` or ternaries that change component identity.
- [ ] Lists use `<For>` (keyed, object identity) or `<Index>` (positional,
      primitives). Flag `.map()` in JSX.
- [ ] Multi-branch logic uses `<Switch>` / `<Match>`.
- [ ] Dynamic component tags use `<Dynamic>`.

## 3. Component hygiene

- [ ] Component function body has no imperative DOM work outside
      `onMount` / effects / refs.
- [ ] `props.children` is wrapped in the `children()` helper when read more
      than once or inspected.
- [ ] Defaults applied with `mergeProps`, not scattered `?? default` at each
      read site.
- [ ] Custom primitives named `createX` / `useX`; they run inside a component
      or `createRoot`.
- [ ] Refs declared as `let el!: HTMLXxxElement; <div ref={el}>`; callback
      refs dispose via `onCleanup`.
- [ ] Event handlers use `onClick={...}` (not `on:click` unless delegation
      needs to be bypassed). Bound-data form `onClick={[fn, arg]}` used in
      loops to avoid re-closures where sensible.

## 4. Side effects & cleanup

- [ ] Every `setInterval` / `setTimeout` / `addEventListener` /
      `new IntersectionObserver` / subscription has an `onCleanup`.
- [ ] `createEffect` is used only for side effects (DOM, logging,
      third-party). Data fetching uses `createResource` or `createAsync`.
- [ ] No `await` directly in a component body — use Suspense + resources.

## 5. Data layer

- [ ] Async data uses `createResource` / `createAsync`; consumers wrapped in
      `<Suspense>` and `<ErrorBoundary>`.
- [ ] Server-data merge uses `reconcile` — identity preserved, granular
      updates.
- [ ] SolidStart actions use `query` / `action`; mutations revalidate the
      right keys.
- [ ] Module-level `createStore` / `createSignal` has a `createRoot` or is
      inside a provider (SSR safety).
- [ ] Context consumers assert the provider is present (`useX` throws if
      missing).

## 6. SSR / hydration (SolidStart)

- [ ] No `Math.random` / `Date.now` / locale-dependent rendering outside of
      effects or `<ClientOnly>`.
- [ ] Server-only code is under `server/` or `.server.ts`, or starts with
      `"use server"`. No secrets in client-visible modules.
- [ ] Client-only APIs (`window`, `document`, `localStorage`) guarded by
      `isServer` or placed in `onMount`.

## 7. Structure (also see `solidjs-architecture`)

- [ ] No deep imports into another feature's internals; only its public
      `index.ts`.
- [ ] Presentation components don't fetch data — that's a route / container
      concern.
- [ ] Lib has no JSX. Server-only code is visibly tagged.
- [ ] File placement matches the feature vs. shared-ui decision.

## 8. Types (TypeScript)

- [ ] `Component<P>` or `ParentComponent<P>` used instead of hand-rolled
      function types.
- [ ] Accessor types: `Accessor<T>`, `Setter<T>` where appropriate.
- [ ] No `any` on props, events, or store shapes.
- [ ] Public APIs (actions, queries, stores) exported with explicit types.

## 9. Accessibility

- [ ] Interactive elements are real `<button>` / `<a>` / form controls; no
      click handlers on bare `<div>`.
- [ ] Forms have labels (`<label for=…>` or wrapping), required/invalid
      states reflected via `aria-*`.
- [ ] Focus management after navigation / modal open (ref + `el.focus()` in
      `onMount`).
- [ ] Keyboard support for custom controls (Enter/Space on role="button",
      arrow keys on listbox/menu).
- [ ] Color is not the sole carrier of meaning.

## 10. Performance (spot-check)

- [ ] Long lists use `<For>`; fixed-length uses `<Index>`; keys match intent.
- [ ] Expensive derivations read by multiple consumers are `createMemo`.
- [ ] Multi-write handlers wrapped in `batch`.
- [ ] Heavy components lazy-loaded with `lazy()`.
- [ ] Route-level `preload` used for critical fetches.

## 11. Testing (see `solidjs-testing`)

- [ ] New components have at least one rendering test (happy path).
- [ ] Async behavior tested with `findBy*` / `waitFor` through Suspense or
      resource states.
- [ ] Custom primitives (`createX`) tested via `renderHook`.
- [ ] No mocking of `solid-js` internals.

## 12. Observability & UX

- [ ] `<ErrorBoundary>` at least at the route level (or feature root).
- [ ] Loading states are explicit (`<Suspense fallback={…}>`), not silent.
- [ ] User-facing errors are meaningful, not raw stack traces.

## Quick ripgrep sweeps

Fast heuristics — each is a *candidate* for discussion, not an automatic
failure.

```bash
# Destructured props
rg -n --type=ts --type=tsx 'function\s+\w+\s*\(\s*\{[^}]*\}\s*(:|\))' src
rg -n 'const\s*\{\s*\w+.*\}\s*=\s*props' src

# .map( in JSX — likely should be <For>
rg -n '\{\s*\w+\(\)\.map\(' src

# Signal used without calling it as a prop
rg -n -P 'prop\w*=\{\w+\}' src | rg -v '\(\)'

# createEffect that only calls a setter (data sync smell)
rg -n -C2 'createEffect\(\s*\(\s*\)\s*=>\s*set[A-Z]' src

# Module-level createSignal/createStore (SSR leak)
rg -n '^\s*const\s*\[[^\]]+\]\s*=\s*create(Signal|Store)' src
```

## Review tone

- Link every comment to the concept, not to taste. Cite the relevant skill
  section (e.g., "see `solidjs-components` § props rule").
- Separate **block-merge** items (broken reactivity, SSR leaks, missing
  cleanup) from **suggestions** (perf, style).
- Approve fast on small, well-scoped PRs; push back on sprawling ones with a
  split request.

## Sources

- [Solid Docs — Components & Props](https://docs.solidjs.com/concepts/components/props)
- [Brenley — Solid.js Best Practices](https://www.brenelz.com/posts/solid-js-best-practices/)
- [OpenReplay — Best Practices for Working with SolidJS](https://blog.openreplay.com/solidjs-best-practices/)
- [Solid Docs — Testing](https://docs.solidjs.com/guides/testing)
