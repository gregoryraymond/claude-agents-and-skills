---
name: solidjs-architecture
description: "Project structure, module boundaries, and folder layout for SolidJS and SolidStart apps. Use when scaffolding a new app, reorganizing folders, deciding where code lives, or reviewing a PR that touches structure. Primary agent: architect (also relevant to reviewer). Keywords: solidjs structure, project layout, folder, scaffolding, SolidStart, routes, file-based routing, feature folder, module boundary, lib, components, entry-client, entry-server, app.config, barrel, monorepo."
globs: ["**/app.config.*", "**/vite.config.*", "**/src/routes/**", "**/src/components/**", "**/src/lib/**", "**/entry-client.*", "**/entry-server.*"]
allowed-tools: ["Read", "Grep", "Glob", "Edit", "Write"]
---

# SolidJS Architecture & Project Structure

Pair with `solidjs-core` for reactivity rules. This skill covers **where code
lives**, not how it behaves.

## Baseline: SolidStart default layout

SolidStart is the recommended full-stack meta-framework. The generated tree:

```
my-app/
├─ public/              # static assets served verbatim (favicon, images, fonts)
├─ src/
│  ├─ app.tsx           # root shell component — HTML skin for client + server
│  ├─ entry-client.tsx  # hydration entry; rarely edit
│  ├─ entry-server.tsx  # SSR entry; rarely edit
│  ├─ app.css           # global styles
│  └─ routes/           # file-based routes — one file = one URL segment
├─ app.config.ts        # SolidStart config (adapter, middleware, Vite opts)
├─ tsconfig.json
└─ package.json
```

`~/*` is aliased to `src/*`. Import as `import X from "~/components/X"`.

## Standard folders to add

SolidStart ships minimal on purpose. Conventionally add:

```
src/
├─ components/          # reusable presentational / generic UI
├─ lib/                 # framework-agnostic helpers, utils, API clients
├─ server/              # "use server" modules, DB access, server-only code
├─ stores/              # global stores (contexts, signals)
├─ styles/              # shared CSS / tokens
└─ types/               # shared TS types
```

Rules of thumb:

- `components/` holds reusable UI that is **not a page**. A page goes in
  `routes/`.
- `lib/` is for code with no JSX — pure TypeScript utilities.
- `server/` (or `.server.ts` suffix) makes it explicit what must never ship to
  the client. Pair with `"use server"` or server-only imports.
- Stores that are not app-wide should live next to the feature that owns them.

## File-based routing cheat sheet (SolidStart + Solid Router)

| Path | URL |
|---|---|
| `src/routes/index.tsx` | `/` |
| `src/routes/about.tsx` | `/about` |
| `src/routes/users/[id].tsx` | `/users/:id` |
| `src/routes/users/[...rest].tsx` | `/users/*` (catch-all) |
| `src/routes/(marketing)/pricing.tsx` | `/pricing` (group; no URL segment) |
| `src/routes/users.tsx` + `src/routes/users/index.tsx` | `/users` layout + page |
| `src/routes/api/hello.ts` | `GET /api/hello` (API route) |

- Layouts: a file at `routes/foo.tsx` that renders `props.children` wraps all
  routes under `routes/foo/`.
- `route.preload` exports run on navigation intent to warm up data.

## Feature-folder layout (scales better past ~20 components)

Colocate everything a feature owns:

```
src/features/checkout/
├─ components/
│  ├─ CartLine.tsx
│  └─ PayButton.tsx
├─ hooks/
│  └─ useCart.ts        # custom primitives (prefix: createX, useX)
├─ server/
│  └─ orders.ts         # "use server" actions + queries
├─ store.ts             # feature-scoped context / store
├─ types.ts
└─ index.ts             # public API — only what other features import
```

Then `src/routes/checkout.tsx` is thin — it composes from `~/features/checkout`.

Guidelines:

- **One public `index.ts` per feature.** Everything else is private.
- Features should not import each other's internals. Cross-feature needs go up
  to `src/lib` or a shared store.
- A feature can import from `lib/`, `components/`, `stores/`; not the reverse.

## Components: what goes where

| Kind | Location |
|---|---|
| Design-system primitive (Button, Input) | `src/components/ui/` |
| App-wide layout (Header, Footer, Shell) | `src/components/layout/` |
| Page (rendered by a route) | `src/routes/...` |
| Feature-scoped component | `src/features/<feat>/components/` |

Keep presentational components free of data fetching. Move
`createResource`/`createAsync` calls up to routes or feature-level containers.

## Module boundaries

Draw layers and enforce the arrows:

```
routes/       →  features/       →  lib/    →  types/
                      ↓
                 components/ (ui) ←  (leaf, depends on nothing app-specific)
```

- Routes orchestrate. Features encapsulate. Lib is leaf.
- A change in `components/ui` should never force a change in `routes/`.
- If two features keep needing each other, extract a third shared feature or
  hoist into `lib/`.

## Naming conventions

| Thing | Convention | Example |
|---|---|---|
| Component files | PascalCase | `CartLine.tsx` |
| Reactive primitive helper | `createX` | `createCartTotals.ts` |
| Plain helper/hook | `camelCase` | `formatCurrency.ts` |
| Context | `XContext` / provider `XProvider` | `CartContext` |
| Server-only module | `.server.ts` suffix or `server/` folder | `orders.server.ts` |
| Types | `PascalCase` in `types.ts` | `CheckoutState` |

## Client vs. server code

In SolidStart:

- `"use server"` at the top of a function or file forces server-only execution
  and exposes it as an RPC.
- Put sensitive code (DB, secrets, service clients) under `src/server/` or with
  a `.server.ts` suffix so a stray client import is obvious.
- Never put secrets in components or in `lib/` unless gated by a server marker.

## Config files that matter

- `app.config.ts` — SolidStart config (adapter, middleware, SSR mode).
- `vite.config.ts` (non-Start apps) — uses `vite-plugin-solid`.
- `tsconfig.json` — set `jsx: "preserve"` and `jsxImportSource: "solid-js"`.
- `.gitignore` — ensure `.solid/`, `.output/`, `.vinxi/` are ignored.

## When NOT to use SolidStart

If the app is pure SPA with no SSR / no server routes (e.g., embedded dashboard,
Electron renderer), use Vite + `vite-plugin-solid` directly and skip the
`routes/` file-based convention. Use `@solidjs/router` manually.

## Architect's review checklist (structure)

1. Every feature has one public `index.ts`; deep imports are violations.
2. No component under `components/ui/` imports from a feature.
3. Server-only code is visually obvious (`server/` or `.server.ts`).
4. Routes are thin — no inline data shaping, no business logic.
5. `lib/` has no JSX.
6. Global stores are justified; prefer feature-local stores when possible.
7. Barrel files don't re-export everything — only the feature's public API.

## Sources

- [Solid Docs — SolidStart Getting Started](https://docs.solidjs.com/solid-start/getting-started)
- [Solid Docs — SolidStart Project Structure (Building Your App)](https://docs.solidjs.com/solid-start/building-your-application/project-structure)
- [Solid Router Docs](https://docs.solidjs.com/solid-router)
- [LogRocket — Getting started with SolidStart](https://blog.logrocket.com/getting-started-solidstart-solid-js-framework/)
- [Solid Start GitHub](https://github.com/solidjs/solid-start)
