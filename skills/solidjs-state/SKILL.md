---
name: solidjs-state
description: "State management in SolidJS — stores (createStore/produce/reconcile), Context, createResource, createAsync, actions, queries. Use when deciding where state lives, fetching data, or wiring up cross-component state. Primary agents: architect, ui-developer. Keywords: createStore, setStore, produce, reconcile, unwrap, createContext, useContext, Provider, createResource, createAsync, action, query, data loading, Suspense, ErrorBoundary, global state, prop drilling."
globs: ["**/*.jsx", "**/*.tsx", "**/store*.ts", "**/stores/**", "**/context*.ts"]
allowed-tools: ["Read", "Grep", "Glob", "Edit", "Write"]
---

# SolidJS State Management

Pair with `solidjs-core` (reactivity) and `solidjs-components` (context
consumption). This skill answers: **where should this state live and how is it
shaped?**

## Decision flow

```
Is it one value?                        → createSignal
Is it a nested object/array?            → createStore
Is it async (fetch/read)?               → createResource / createAsync
Shared between siblings, few levels?    → lift to common parent
Shared across many components/levels?   → Context (containing signals/stores)
Server data with caching + revalidation → SolidStart query + action
```

Default to **local first**. Promote to context only when two components that
don't share an obvious parent both need it.

## Signals vs. stores

| | Signal | Store |
|---|---|---|
| Created by | `createSignal(v)` | `createStore(obj)` |
| Get | call getter: `x()` | read property: `s.x` |
| Set | `setX(v)` | `setS("x", v)` / path set |
| Reactivity granularity | whole value | per-property, nested |
| Good for | primitives, single objects replaced wholesale | nested objects, arrays, forms |
| Identity | new value each set | mutates in place via proxy |

```tsx
import { createStore, produce, unwrap } from "solid-js/store";

const [cart, setCart] = createStore({
  items: [] as Item[],
  coupon: null as string | null,
});

// path-based set
setCart("coupon", "SAVE10");
setCart("items", 0, "qty", (q) => q + 1);
setCart("items", (i) => i.id === 42, "qty", 3);

// unwrap for logging or sending to server
console.log(unwrap(cart));
```

## `produce` — mutable edits, immutable ergonomics

`produce` lets you write imperative mutations; the store applies them as a
single batched update.

```tsx
import { produce } from "solid-js/store";

setCart(produce((c) => {
  const hit = c.items.find((i) => i.id === id);
  if (hit) hit.qty += 1;
  else c.items.push({ id, qty: 1 });
  c.total = c.items.reduce((s, i) => s + i.qty, 0);
}));
```

Use when:

- Many related writes in one go (avoids repeated `setStore` calls).
- Complex nested updates that `setStore(path, …)` would make unreadable.

## `reconcile` — merge server data without wrecking identity

Replacing a store with a fresh object blows away identity and forces everything
to re-render. `reconcile` diffs and applies only the changes.

```tsx
import { reconcile } from "solid-js/store";

async function refresh() {
  const fresh = await fetchCart();
  setCart(reconcile(fresh, { key: "id", merge: false }));
}
```

- `key` tells it how to identify array items (default `"id"`).
- Use for any "replace the whole store with the latest server response" flow.
- Pairs great with `createResource` + store: feed the resource result through
  `reconcile`.

## Context pattern (avoid prop drilling)

Contexts in Solid are just signals/stores with a Provider. No extra re-render
cost — the context holder is a signal, so only consumers of what actually
changed react.

```tsx
// src/features/cart/CartContext.tsx
import { createContext, useContext, ParentComponent } from "solid-js";
import { createStore } from "solid-js/store";

type CartState = { items: Item[]; total: number };
type CartCtx = readonly [CartState, { add(i: Item): void; clear(): void }];

const Ctx = createContext<CartCtx>();

export const CartProvider: ParentComponent = (props) => {
  const [cart, setCart] = createStore<CartState>({ items: [], total: 0 });
  const api = {
    add(i: Item) { setCart(produce((c) => { c.items.push(i); c.total += i.price; })); },
    clear()     { setCart({ items: [], total: 0 }); },
  };
  return <Ctx.Provider value={[cart, api] as const}>{props.children}</Ctx.Provider>;
};

export function useCart() {
  const c = useContext(Ctx);
  if (!c) throw new Error("useCart must be used inside <CartProvider>");
  return c;
}
```

Patterns:

- Always export a `useX` hook that asserts the provider is present.
- Keep the tuple shape `[state, actions]` — mirrors `createSignal` ergonomics.
- Put provider near the root (or feature boundary), not inside a list.

## `createResource` — async data with Suspense integration

```tsx
const [user] = createResource(() => userId(), async (id) => {
  const res = await fetch(`/api/users/${id}`);
  if (!res.ok) throw new Error("load failed");
  return res.json();
});
```

- First arg is a **source signal** (or `true`/`false`). When it changes, the
  fetcher re-runs. When `false`/null/undefined, fetcher is skipped.
- `user()` — current value (undefined until loaded).
- `user.loading` — true during fetches.
- `user.error` — last error (auto-caught by `<ErrorBoundary>`).
- `refetch()`, `mutate(next)` — imperative controls.

Wrap with `<Suspense>` + `<ErrorBoundary>`:

```tsx
<ErrorBoundary fallback={(e, retry) => <ErrorPanel e={e} retry={retry} />}>
  <Suspense fallback={<Spinner />}>
    <Profile id={userId()} />
  </Suspense>
</ErrorBoundary>
```

## `createAsync` (Solid Router) — preferred for most fetches

From `@solidjs/router`. Simpler ergonomics, auto-tracks, throws promises for
Suspense, integrates with navigation.

```tsx
import { createAsync, query } from "@solidjs/router";

const getUser = query((id: string) => fetch(`/api/users/${id}`).then(r => r.json()), "user");

function Profile(props: { id: string }) {
  const user = createAsync(() => getUser(props.id));
  return <Show when={user()}>{(u) => <h1>{u().name}</h1>}</Show>;
}
```

## SolidStart: queries + actions

The data-layer idiom for SolidStart apps:

```tsx
// src/server/posts.ts
"use server";
import { query, action, revalidate } from "@solidjs/router";

export const getPosts = query(async () => {
  return db.post.findMany();
}, "posts");

export const createPost = action(async (formData: FormData) => {
  const title = String(formData.get("title"));
  await db.post.create({ data: { title } });
  throw revalidate(getPosts.key);
});
```

```tsx
// src/routes/posts.tsx
import { createAsync, useAction } from "@solidjs/router";
import { getPosts, createPost } from "~/server/posts";

export default function Posts() {
  const posts = createAsync(() => getPosts());
  const submit = useAction(createPost);
  return (
    <>
      <form onSubmit={(e) => { e.preventDefault(); submit(new FormData(e.currentTarget)); }}>
        <input name="title" /> <button type="submit">Add</button>
      </form>
      <Suspense fallback={<p>Loading…</p>}>
        <For each={posts()}>{(p) => <li>{p.title}</li>}</For>
      </Suspense>
    </>
  );
}
```

- **Queries** = cached reads keyed by argument. Deduped across components.
- **Actions** = mutations that can `throw revalidate(key)` to invalidate queries.
- `preload` on a route calls the query early so data is warming while JS loads.

## Global state: just a module-level context

For truly global state (auth, theme, feature flags), a context at the app root
is the right answer. Do **not** create signals at module top-level unless
wrapped in `createRoot` — that leaks and fails under SSR.

```tsx
// ❌ SSR trap: module-level signal shared across requests
const [user, setUser] = createSignal<User | null>(null);

// ✅ provider at the app root, local per request on the server
```

## Forms

Two common shapes:

1. Uncontrolled + `FormData` (best with SolidStart actions).
2. Store-backed controlled fields for complex validation:

```tsx
const [form, setForm] = createStore({ name: "", email: "", errors: {} as Record<string, string> });

<input value={form.name} onInput={(e) => setForm("name", e.currentTarget.value)} />
```

For non-trivial forms, reach for a library: `@modular-forms/solid` or
`felte` — both integrate with Solid's store model.

## Common mistakes

| Mistake | Fix |
|---|---|
| `setCart({ ...cart, items: [...] })` (wholesale replace) | Use path set or `produce` — preserves identity |
| Syncing two signals with `createEffect` | Derive or use a memo |
| Storing derived values in the store | Derive with a getter/memo |
| Reading context without a provider check | Throw in `useX` if `useContext` is undefined |
| Module-level `createStore` used in SSR | Put it in a provider |
| Fetching in `createEffect` | Use `createResource` / `createAsync` |
| Fetching inside a component that returns the JSX synchronously | Wrap with `<Suspense>` and let the resource throw |

## Sources

- [Solid Docs — Stores](https://docs.solidjs.com/concepts/stores)
- [Solid Docs — Complex state management](https://docs.solidjs.com/guides/complex-state-management)
- [Solid Docs — reconcile](https://docs.solidjs.com/reference/store-utilities/reconcile)
- [Solid Docs — createResource](https://docs.solidjs.com/reference/basic-reactivity/create-resource)
- [Solid Router — createAsync](https://docs.solidjs.com/solid-router/reference/data-apis/create-async)
- [Solid Docs — Fetching data](https://docs.solidjs.com/guides/fetching-data)
