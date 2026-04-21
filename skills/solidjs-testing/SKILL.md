---
name: solidjs-testing
description: "Testing SolidJS apps with Vitest + @solidjs/testing-library — setup, rendering, async/Suspense, testing custom primitives, router/context wrappers. Use when writing or fixing component and primitive tests. Primary agents: ui-developer, reviewer. Keywords: solidjs test, vitest, testing-library, solid-testing-library, renderHook, jsdom, fireEvent, user-event, solidjs router test, context test, mock fetch, async test, Suspense test."
globs: ["**/*.test.*", "**/*.spec.*", "**/vitest.config.*", "**/vite.config.*"]
allowed-tools: ["Read", "Grep", "Glob", "Edit", "Write", "Bash"]
---

# SolidJS Testing

Uses Vitest + `@solidjs/testing-library`. Pairs with `solidjs-components`
(what you're testing) and `solidjs-review` (what reviewers expect).

## Install

```bash
npm i -D vitest jsdom @solidjs/testing-library @testing-library/user-event @testing-library/jest-dom
```

## `vite.config.ts` — the one important gotcha

Solid must load **once** per test run. Misconfigured deps cause dispose=undefined
errors or router singleton issues.

```ts
import { defineConfig } from "vitest/config";
import solid from "vite-plugin-solid";

export default defineConfig({
  plugins: [solid()],
  test: {
    environment: "jsdom",
    globals: true,
    setupFiles: ["./vitest.setup.ts"],
    server: { deps: { inline: [/solid-js/, /@solidjs\/.*/] } },
  },
  resolve: {
    conditions: ["development", "browser"],
  },
});
```

`vitest.setup.ts`:

```ts
import "@testing-library/jest-dom/vitest";
```

`package.json`:

```json
{ "scripts": { "test": "vitest", "test:run": "vitest run" } }
```

## Rendering a component

`render` takes a **function** returning a component — not the component itself.

```tsx
import { render, screen } from "@solidjs/testing-library";
import userEvent from "@testing-library/user-event";
import { Counter } from "./Counter";

test("increments", async () => {
  const user = userEvent.setup();
  render(() => <Counter />);
  const btn = screen.getByRole("button", { name: /increment/i });
  await user.click(btn);
  expect(screen.getByText("1")).toBeInTheDocument();
});
```

Key differences from React:

- **No `rerender`.** Solid doesn't re-render — you trigger updates by
  interacting with the component or mutating signals/stores the test controls.
- **Updates are synchronous.** For most assertions `expect(...)` works
  immediately after an action. Use `findBy*` / `waitFor` only for Suspense,
  resources, transitions, and router navigation.
- **Automatic cleanup** is registered — no need to call `cleanup()`.

## Async: resources and Suspense

```tsx
test("loads user", async () => {
  render(() => (
    <Suspense fallback={<p>Loading…</p>}>
      <Profile id="42" />
    </Suspense>
  ));
  expect(screen.getByText(/loading/i)).toBeInTheDocument();
  expect(await screen.findByText(/Ada Lovelace/)).toBeInTheDocument();
});
```

Use `findBy*` (returns a promise) to wait for the resource to resolve. Mock
the fetch/fetcher at the module boundary:

```ts
import { vi } from "vitest";
vi.mock("~/server/users", () => ({
  getUser: vi.fn().mockResolvedValue({ id: "42", name: "Ada Lovelace" }),
}));
```

## Testing custom primitives (`createX`) with `renderHook`

Primitives create computations that need an owner. `renderHook` provides one
and returns `dispose` for explicit teardown.

```tsx
import { renderHook } from "@solidjs/testing-library";
import { createToggle } from "./createToggle";

test("toggle flips", () => {
  const { result } = renderHook(() => createToggle(false));
  const [on, toggle] = result;
  expect(on()).toBe(false);
  toggle();
  expect(on()).toBe(true);
});
```

## Testing with Context / Providers

Wrap with a custom render helper that mounts the providers your tree needs:

```tsx
// test/renderWithCart.tsx
import { render } from "@solidjs/testing-library";
import { CartProvider } from "~/features/cart/CartContext";
import type { JSX } from "solid-js";

export function renderWithCart(ui: () => JSX.Element) {
  return render(() => <CartProvider>{ui()}</CartProvider>);
}
```

```tsx
renderWithCart(() => <AddToCartButton item={item} />);
```

## Testing with the Router

```tsx
import { Router, Route } from "@solidjs/router";

test("route renders", () => {
  render(() => (
    <Router>
      <Route path="/users/:id" component={UserPage} />
    </Router>
  ), { location: "/users/42" });
});
```

- The Solid testing-library `render` accepts `{ location }` and sets up the
  router memory history.
- For actions/queries, stub them out with `vi.mock` so tests don't hit the
  server.

## Events: `fireEvent` vs `userEvent`

- `fireEvent` — synchronous, low-level. Good for synthetic events not easily
  produced by the user (e.g., `transitionend`, programmatic `change`).
- `userEvent` — asynchronous, simulates real user flows (click sequences,
  typing with timing, keyboard navigation). Default to this.

## Assertions

`@testing-library/jest-dom` adds matchers: `toBeInTheDocument`,
`toHaveAttribute`, `toBeDisabled`, `toHaveAccessibleName`, etc. Prefer
role-based queries (`getByRole`) for a11y coverage.

## Coverage

```ts
// vitest.config.ts → test:
coverage: {
  provider: "v8",
  reporter: ["text", "html"],
  include: ["src/**/*.{ts,tsx}"],
  exclude: ["src/**/*.test.*", "src/entry-*.tsx"],
}
```

Cover every exported primitive at least once; cover happy path + one edge
case per component.

## Common pitfalls

| Symptom | Cause | Fix |
|---|---|---|
| `TypeError: dispose is not a function` | Two copies of `solid-js` loaded | Add `solid-js` to `server.deps.inline` |
| Effect doesn't run in a test | Test finished before microtask | `await Promise.resolve()` or use `findBy*` |
| `renderHook` signals leak across tests | Didn't dispose | Call the returned `dispose()` or let cleanup run |
| Router test throws `No Router` | Missing `<Router>` wrapper | Use the router in the render call |
| Resource never resolves | Mock returns a never-resolving promise | Use `mockResolvedValue` or `vi.fn().mockResolvedValue(...)` |
| `window`/`document` undefined | Missing `environment: "jsdom"` | Set it in `vitest.config.ts` |

## What to test

- **Behavior, not implementation.** Assert on rendered output and accessible
  names; don't reach into `createSignal` internals.
- **Contracts, not coverage.** A single test per component for the happy
  path; add tests when fixing bugs (regression tests).
- **Primitives independently.** Business logic in `createX` is easiest to
  test via `renderHook`.
- **A11y.** Prefer `getByRole` / `getByLabelText` — if those fail, the
  component likely has an a11y bug.

## Sources

- [Solid Docs — Testing](https://docs.solidjs.com/guides/testing)
- [@solidjs/testing-library GitHub](https://github.com/solidjs/solid-testing-library)
- [@solidjs/testing-library on npm](https://www.npmjs.com/package/@solidjs/testing-library)
- [Testing Library — Solid intro](https://testing-library.com/docs/solid-testing-library/intro/)
- [DEV — Testing a SolidJS Component Using Vitest](https://dev.to/mbarzeev/testing-a-solidjs-component-using-vitest-2h35)
