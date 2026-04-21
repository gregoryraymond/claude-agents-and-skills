---
name: solidjs-components
description: "Building SolidJS components — props handling, control flow (Show/For/Switch/Index/Dynamic), refs, events, children helper, composition patterns. Use when writing or modifying UI components. Primary agent: ui-developer (also relevant to reviewer). Keywords: solidjs component, props, mergeProps, splitProps, children, Show, For, Index, Switch, Match, Dynamic, Portal, ref, forward ref, event handler, onClick, JSX, spread props, render prop."
globs: ["**/*.jsx", "**/*.tsx"]
allowed-tools: ["Read", "Grep", "Glob", "Edit", "Write"]
---

# SolidJS Components & UI Patterns

For the reactivity model underneath, see `solidjs-core`. This skill is about
building components idiomatically.

## The props rule

**Props are a live proxy backed by getters. Destructuring kills reactivity.**

```jsx
// ❌ all of these break reactivity
function Bad(props) {
  const { name, count } = props;
  const { name } = props;
  const name = props.name;           // plain value, frozen at call time
  return <p>{name}</p>;
}

// ✅ read through props, or wrap in a getter
function Good(props) {
  return <p>{props.name} — {props.count}</p>;
}

// ✅ need a local name? make it a getter
function Good2(props) {
  const name = () => props.name;
  return <p>{name()}</p>;
}
```

### `splitProps` — the only safe "destructure"

Use when forwarding rest props or separating out a subset without losing
reactivity.

```tsx
import { splitProps, JSX } from "solid-js";

type Props = JSX.ButtonHTMLAttributes<HTMLButtonElement> & { variant?: "primary" | "ghost" };

function Button(props: Props) {
  const [local, rest] = splitProps(props, ["variant", "class", "children"]);
  return (
    <button
      class={`btn btn-${local.variant ?? "primary"} ${local.class ?? ""}`}
      {...rest}
    >
      {local.children}
    </button>
  );
}
```

### `mergeProps` — defaults without breaking reactivity

```tsx
import { mergeProps } from "solid-js";

function Avatar(props: { size?: number; src: string }) {
  const merged = mergeProps({ size: 40 }, props);
  return <img src={merged.src} width={merged.size} height={merged.size} />;
}
```

Never write `props.size ?? 40` in multiple places — define the default once via
`mergeProps`.

### Passing signals to props

Pass the **value**, not the getter, so the child doesn't need to know it's a
signal:

```jsx
// ✅ call it; Solid re-runs the prop expression reactively
<User id={id()} />

// ❌ forces the child to also call it, leaks signal shape
<User id={id} />
```

## The `children` helper

`props.children` can be a primitive, element, array, or a function (render
prop). Reading it multiple times can re-create nodes. Use the `children` helper
to memoize.

```jsx
import { children } from "solid-js";

function Card(props) {
  const resolved = children(() => props.children);
  return (
    <div class="card">
      <header>{resolved()}</header>
      <footer>{resolved()}</footer>    {/* safe — same nodes */}
    </div>
  );
}
```

Also useful when you need to *inspect* children (e.g., tab list wrapping `<Tab>`
children).

## Control flow — use components, not JS

Solid compiles these to fine-grained updates. Plain JS expressions in JSX force
re-evaluation of the whole subtree.

### `<Show>` — conditional

```jsx
import { Show } from "solid-js";

<Show when={user()} fallback={<Login />} keyed>
  {(u) => <Welcome user={u()} />}
</Show>
```

- `when` accepts truthy values. Uses `!!` coercion.
- `fallback` renders when falsy.
- `keyed` — when `when` is an object, receive it via child render-prop so it
  re-instantiates on identity change. Child is called with `() => value`.

### `<For>` — keyed list (most common)

```jsx
<For each={items()} fallback={<Empty />}>
  {(item, i) => <Row index={i()} data={item} />}
</For>
```

- Keyed by **reference**. Same object in a new position = same DOM node, moved.
- `i` is an accessor for the current index — call `i()`.
- Prefer over `.map()` — `.map()` recreates everything when the array changes.

### `<Index>` — unkeyed, by position

Use when the array is fixed-length or items are primitives that can change
in place (e.g., rendering a heatmap grid).

```jsx
<Index each={scores()}>
  {(score, i) => <Cell score={score()} pos={i} />}
</Index>
```

- `score` is an **accessor**, `i` is a **plain number**.
- Opposite of `<For>`: same *slot* keeps its DOM even if the value changes.

### `<Switch>` / `<Match>` — multi-branch

```jsx
<Switch fallback={<NotFound />}>
  <Match when={status() === "loading"}><Spinner /></Match>
  <Match when={status() === "error"}><Retry /></Match>
  <Match when={data()}>{(d) => <Render value={d()} />}</Match>
</Switch>
```

### `<Dynamic>` — component from a signal

```jsx
<Dynamic component={tag()} class="heading">{text()}</Dynamic>
```

Replaces `createElement(tag, …)` / big switch statements.

### `<Portal>` — render elsewhere in the DOM

```jsx
<Portal mount={document.getElementById("modal-root")!}>
  <Modal />
</Portal>
```

### `<ErrorBoundary>` — catch render / effect errors

```jsx
<ErrorBoundary fallback={(err, reset) => <Fallback err={err} reset={reset} />}>
  <Thing />
</ErrorBoundary>
```

## Refs

Refs are assigned synchronously during the initial render. The variable
declaration pattern is compiler-magic:

```jsx
function Thing() {
  let el!: HTMLDivElement;              // TS: definite assignment
  onMount(() => el.focus());
  return <div ref={el} tabindex="0" />;
}
```

Callback ref form is also supported and composes:

```jsx
<div ref={(node) => {
  observer.observe(node);
  onCleanup(() => observer.unobserve(node));
}} />
```

Forwarding refs: just pass `props.ref` through. Solid handles both forms.

```tsx
function Input(props: { ref?: HTMLInputElement | ((el: HTMLInputElement) => void) }) {
  return <input ref={props.ref} />;
}
```

## Events

- `on:event` delegated (most built-ins): `<button onClick={handler}>` — handler
  gets the native event.
- `on:event` with capture/passive: `<div on:scroll={{ handleEvent, passive: true }}>`.
- `onMount` / `onCleanup` for mount/unmount lifecycle.
- **Don't** bind with `.bind(this)` — no `this` in function components.

Event handler shortcuts:

```jsx
// bound-data pattern — avoids recreating closures in loops
<For each={items()}>
  {(item) => <button onClick={[remove, item.id]}>×</button>}
</For>
// remove is called as remove(item.id, event)
```

## Composition patterns

### Render props / slot pattern

```tsx
function Disclosure(props: { title: string; children: JSX.Element }) {
  const [open, setOpen] = createSignal(false);
  return (
    <div>
      <button onClick={() => setOpen(!open())}>{props.title}</button>
      <Show when={open()}>{props.children}</Show>
    </div>
  );
}
```

### Headless / compound components

Export a set: `<Tabs>`, `<Tabs.List>`, `<Tabs.Tab>`, `<Tabs.Panel>`. Share state
via a private context (see `solidjs-state`).

### Custom primitives (`createX`)

Factor reusable reactive logic into functions that return signals/getters. They
**must** run inside a component (or `createRoot`) because they create
computations that need an owner.

```tsx
function createToggle(initial = false) {
  const [on, setOn] = createSignal(initial);
  return [on, () => setOn((x) => !x)] as const;
}

// usage
const [open, toggle] = createToggle();
```

## TypeScript tips

- `Component<Props>` for function signature; `ParentComponent<Props>` for
  components taking children; `ParentProps<Props>` adds `children` to your
  props type.
- `JSX.IntrinsicElements["button"]` → full native attribute type.
- `Accessor<T>` = `() => T`. `Setter<T>` is Solid's setter type.
- Use `!` definite-assignment for refs: `let el!: HTMLDivElement`.

## Anti-patterns to flag

| Anti-pattern | Fix |
|---|---|
| `const { x } = props` | Use `props.x` or `splitProps` |
| `{cond && <A />}` | `<Show when={cond()}><A /></Show>` |
| `{arr.map(x => <Row x={x} />)}` | `<For each={arr()}>{(x) => <Row x={x} />}</For>` |
| `props.children` read multiple times | Wrap with `children(() => props.children)` |
| Re-creating component instances from a ternary | `<Dynamic component={...}>` |
| Passing `signal` (getter) as a prop | Pass `signal()` instead |
| Binding `this` | There is no `this`; use arrow functions |
| `useRef`-style assignment pattern | Use `let el; <div ref={el}>` |

## Sources

- [Solid Docs — Props](https://docs.solidjs.com/concepts/components/props)
- [Solid Docs — Control Flow](https://docs.solidjs.com/concepts/control-flow/conditional-rendering)
- [Solid Docs — Refs](https://docs.solidjs.com/concepts/refs)
- [Solid Docs — Dynamic](https://docs.solidjs.com/concepts/control-flow/dynamic)
- [LogRocket — Understanding SolidJS props](https://blog.logrocket.com/understanding-solidjs-props-complete-guide/)
