---
name: ui
description: Guide for building and modifying game UI in Bevy. Covers the AAA grand strategy visual language, design tokens, component patterns, spawn helpers, and code conventions. Apply when creating, restyling, or debugging any UI element — menus, HUD, panels, buttons, overlays.
user-invocable: true
allowed-tools: Read, Grep, Bash, Edit, Write, Agent, Glob
---

# UI Style Guide — Kingdoms of Europe

All UI work (Penpot designs and Bevy code) must follow this guide. The game uses an AAA grand strategy visual language inspired by Civ VI, CK3, EU4, Total War, and AoE IV.

The canonical style reference is `STYLE_GUIDE.md` at the repo root. This skill summarizes the key rules, tokens, and code patterns for implementation.

---

## Design Philosophy

- **Left-anchored menus** — buttons float at ~120px from left edge, no containing panel. 70%+ of screen is open for the map background.
- **Atmospheric layering** — dark base, map tint, scrims, vignettes, warm glow. Depth through overlay, not boxes.
- **Text-only navigation** — Cinzel headings as interactive elements. No filled button rectangles for primary nav.
- **Sharp corners everywhere** — never rounded (border-radius 0).
- **Gold used sparingly** — title, divider ornament, hover states, panel edge accents. Not as fill color.
- **Warm cream text** — `#E8DCC8` instead of pure white. Softer, more period-appropriate.

### What NOT to Do

- No rounded corners on panels or buttons
- No pure white `#FFFFFF` text — use cream `#E8DCC8`
- No filled button rectangles for primary navigation
- No "web app" centered dark modals (old style — has been removed)
- No gold as a fill/background color — gold is for accents only

---

## Design Tokens (Code)

All tokens live in `crates/europe-zone-control/src/game/ui_style.rs`. **Never use raw `Color::srgb()` or hardcoded `font_size` values** — import from `ui_style`.

### Core Color Tokens

| Token const | Hex | Usage |
|---|---|---|
| `BASE_BG` | `#080810` | Fullscreen dark base layer |
| `PANEL_BG` | `#0A0A14` at 88% | Info panels, overlays |
| `GOLD` | `#D4A843` | Titles, hover text, active indicators |
| `GOLD_DIM` | `#9A7B3C` | Dividers, edge accents, subtle strokes |
| `CREAM` | `#E8DCC8` | Primary body/button text |
| `DIM_CREAM` | `#B0A68E` | Secondary text |
| `MUTED` | `#8A7E62` | Tertiary labels |
| `DIM_TEXT` | `#555555` at 40% | Disabled text, version strings |
| `CYAN` | `#7AB8D4` | Room codes, links, info highlights |
| `READY_GREEN` | `#4D9E4D` | Ready status, researched tech |
| `DANGER_RED` | `#CC5544` | Surrender, danger actions |
| `CELL_BG` | `#111118` at 30% | Subtle containers, grid cells |
| `CTA_BG` | `#111118` at 50% | CTA button background |
| `CTA_BORDER` | `#9A7B3C` at 40% | CTA button border |
| `CTA_ACCENT` | `#D4A843` at 60% | CTA gold accent line |

### Resource Colors

| Token | Color | Resource |
|---|---|---|
| `RES_POP` | Light blue | Population |
| `RES_FOOD` | Green | Food |
| `RES_WOOD` | Brown | Wood |
| `RES_METAL` | Amber | Metal |

### Slider Colors

| Token | Color | Slider |
|---|---|---|
| `SLIDER_REBELLION` | Red | Rebellion |
| `SLIDER_PIETY` | Lavender | Piety |
| `SLIDER_AUTHORITY` | Gold | Authority |
| `SLIDER_PLURALISM` | Teal | Pluralism |
| `SLIDER_CORRUPTION` | Purple | Corruption |
| `SLIDER_COHERENCE` | Cyan | Coherence |

### Typography Size Tokens

| Token const | Size | Usage |
|---|---|---|
| `TITLE_SIZE` | 38px | Screen titles (Cinzel Bold) |
| `SUBTITLE_SIZE` | 22px | Subtitles (Cinzel) |
| `BTN_PRIMARY_SIZE` | 18px | Primary nav buttons (Cinzel) |
| `BTN_SECONDARY_SIZE` | 14px | Secondary buttons (Source Sans Pro) |
| `BODY_SIZE` | 15px | Body text (Source Sans Pro) |
| `SMALL_BODY_SIZE` | 13px | Status lines, subtle info |
| `HINT_SIZE` | 12px | Hints, footers |
| `CTA_SIZE` | 16px | CTA button text (Cinzel) |
| `STAT_VALUE_SIZE` | 20px | Resource numbers |
| `TIMER_SIZE` | 24px | Turn timer |
| `ACTION_TEXT_SIZE` | 11px | Action buttons, queue text |
| `TAB_SIZE` | 10px | Province tabs, stat labels |
| `LABEL_SIZE` | 9px | Leaderboard titles, rank badges |
| `MICRO_SIZE` | 8px | Unit labels, radar labels |

### Layout Constants

| Token | Value | Usage |
|---|---|---|
| `MENU_LEFT_OFFSET` | 120px | Left menu X offset from screen edge |
| `MENU_ITEM_GAP` | 12px | Vertical gap between menu items |

### HUD Element Colors

The `ui_style.rs` module also contains ~40 specialized HUD tokens: `ACTION_BTN_BG`, `UNIT_CARD_BG`, `PROVINCE_PANEL_BG`, `TAB_ACTIVE_BG`, `TOOLTIP_BG`, `MOVE_PANEL_BG`, `HUD_PANEL_BG`, `SUMMARY_PANEL_BG`, `RADAR_BG`, `RANK_BADGE_BG`, `PAUSE_BACKDROP`, etc. See the file for full list.

---

## Fonts

Two font families, loaded in `load_fonts()` and stored in `GameFonts` resource:

| Field | Font | Usage |
|---|---|---|
| `fonts.heading` | Cinzel | Titles, buttons, headings, HUD values |
| `fonts.body` | Source Sans Pro | Body text, descriptions, labels, hints |

Access via `Res<GameFonts>` in systems.

---

## Component Patterns

### Atmospheric Background (menu screens)

Every fullscreen menu/overlay uses 6 layers. Use `ui_style::spawn_atmospheric_bg(parent)`:
1. Base dark fill (`BASE_BG`)
2. Map tint right half (`MAP_TINT`)
3. Left scrim wide (`SCRIM_WIDE`)
4. Left scrim core (`SCRIM_CORE`)
5. Top + bottom vignettes (`VIGNETTE`)
6. Warm glow (`WARM_GLOW`)

### Heraldic Shield Ornament

`ui_style::spawn_heraldic_shield(parent)` — rect-based shield with gold cross and crown points. Used on Main Menu above the title.

### Tapered Gold Divider

`ui_style::spawn_gold_divider(parent)` — horizontal line: transparent -> gold -> transparent with diamond at center. Separates title from navigation.

### Text-Only Buttons (primary nav)

`ui_style::spawn_text_button(parent, fonts, label, enabled, marker)`:
- Idle: Cinzel 18px, cream, no background
- Hover: gold text (handled by `update_menu_text_button_hover` system + `MenuTextButton` component)
- No filled rectangle, no border

With subtitle: `spawn_text_button_with_desc(parent, fonts, label, desc, enabled, marker)`

### CTA Buttons (confirmations)

`ui_style::spawn_cta_button(parent, fonts, label, enabled, marker)`:
- Subtle dark bg (`CTA_BG`), thin gold border (`CTA_BORDER`), gold accent line (`CTA_ACCENT`)
- Text: Cinzel 16px, gold
- Used for "Start Game", "Lock In", confirmations

### Panel Edge Accents

`ui_style::spawn_edge_accent(parent, EdgeSide::Left|Right)` — thin 2px vertical gold line on panel edges.

### Info Panels

`ui_style::spawn_info_panel(parent, width, accent_side, marker, |panel| { ... })` — standard dark panel with optional edge accent.

### Form Input Fields

`ui_style::spawn_input_field(parent, fonts, label, value, focused, marker)` — labeled input with dark bg and gold border.

### Status Text

`ui_style::spawn_status_text(parent, fonts, text, color)` — body font, small size.

### Section Headings

`ui_style::spawn_section_heading(parent, fonts, text)` — Cinzel subtitle size, cream.

---

## Bevy Layout Rules

1. **Use FlexBox** for all layouts (`Display::Flex`, `FlexDirection`, `JustifyContent`, `AlignItems`)
2. **Prefer `Val::Px`** for sizing
3. **Handle resize** — use relative positioning where possible, absolute only for top-level HUD anchors
4. **All border radius must be 0** (sharp corners) unless specifically a progress indicator
5. **All components in a dialog must be aligned** relative to one another
6. **Font references from `GameFonts`** — never load fonts ad-hoc

---

## Code Files

| File | Purpose |
|---|---|
| `src/game/ui_style.rs` | Design tokens (colors, sizes, layout) + spawn helpers |
| `src/game/ui_spawn.rs` | HUD spawn, panel spawn, action buttons |
| `src/game/ui_update.rs` | HUD update systems (resources, turn, scoreboard, hover) |
| `src/game/lobby.rs` | Lobby menu screens (main menu, player count, waiting room, join) |
| `src/game/draft.rs` | Nation draft UI, AI vote panel |
| `src/game/components.rs` | UI component/marker definitions |

### Interaction Pattern

All 17 button handlers use `Changed<Interaction>` queries (legacy pattern). No observer-based `Trigger<Pointer<Click>>` is used. The hover system for text-only buttons is `update_menu_text_button_hover` in `ui_update.rs`, keyed on the `MenuTextButton` marker component.

---

## Screen Inventory

All 15 non-HUD screens have been restyled to AAA. The In-Game HUD has been tokenized but not fully redesigned in Penpot.

### Menu / Lobby Screens
- Main Menu (left-anchored text buttons + heraldic shield)
- Player Count Selection (left-anchored number buttons)
- Waiting Room (player list + room code)
- Join Game (input field + game list)
- Host Game (settings panel)
- Nation Draft (grid + nation info panel)
- Nation Select (large nation info)
- AI Vote (model selection grid)
- Pause Menu (overlay with resume/settings/surrender)
- End Game Summary (stats + rankings)

### In-Game HUD Elements
- Resource stat cards (top area)
- Radar chart (center-top)
- Leaderboard panel (left sidebar)
- End Day button (bottom-right)
- Province detail panel (right sidebar)
- Action buttons (province actions)
- Unit cards (army display)
- Tech tree panel (overlay)
- Combat resolution panel (overlay)
- Turn summary panel (overlay)
- Move panel (army movement)
- Map color mode buttons

---

## Penpot Design Workflow

The game's UI is designed in Penpot (self-hosted) using the MCP plugin before implementing in Bevy code. The Penpot file is "New File 1". See `STYLE_GUIDE.md` for full design tokens, component patterns, screen inventory, and MCP working notes.

### Penpot Pages

1. **Design System** (page 1) — Color palette, typography, buttons, panels, tokens, and 6 screen designs
2. **Main Menu / Lobby** (page 2) — 6 overlay/panel screen designs

### Screen Status

All 10 menu/overlay screens have been redesigned in AAA style (see `STYLE_GUIDE.md` for full inventory). The **In-Game HUD** board at (2100,850) on the Design System page is the next to be redesigned.

### MCP Working Notes

- `createBoard()` is broken — use `existingBoard.clone()` instead
- Z-order: higher child index = visually in front; use `insertChild(children.length, shape)`
- Text alignment: use `.align` not `.textAlign`; set `growType: 'fixed'` and `resize()` BEFORE `verticalAlign: 'center'`
- All coordinates are absolute page coordinates, not relative to board

---

## Checklist: Before Submitting UI Changes

1. All colors use tokens from `ui_style.rs` — no raw `Color::srgb()` / `Color::srgba()`
2. All font sizes use tokens — no hardcoded `font_size` values
3. Fonts come from `GameFonts` resource (Cinzel for headings, Source Sans Pro for body)
4. Sharp corners (border-radius 0) on all panels and buttons
5. Text is warm cream `#E8DCC8`, not pure white
6. Gold is used sparingly — accents only, not fill
7. FlexBox layout used throughout
8. Components handle window resize
9. `cargo check -p europe-zone-control` passes
