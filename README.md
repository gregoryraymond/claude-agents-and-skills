# claude-agents-and-skills

A personal collection of [Claude Code](https://claude.com/claude-code) agents and skills covering Rust, Bevy game development, and SolidJS/SolidStart web development.

## Layout

```
agents/   # Subagent definitions (.md with frontmatter)
skills/   # Skills, each in its own directory with a SKILL.md
```

## What's in here

### Agents

Specialized subagents invoked via the `Agent` tool.

| Agent | Purpose |
|---|---|
| `code-reviewer` | Reviews Rust/Bevy code — clippy, ECS patterns, performance, safety |
| `geometry-engineer` | Terrain / mesh / coastline geometry work |
| `ui-designer` | Bevy UI design and implementation |
| `ui-reviewer` | Reviews Bevy UI changes |
| `solidjs-architect` | Project structure and module boundaries for SolidJS apps |
| `solidjs-ui-developer` | Builds SolidJS components, forms, reactive primitives |
| `solidjs-reviewer` | Reviews SolidJS PRs for reactivity and correctness |

### Skills

Skills are grouped by domain. Each directory contains a `SKILL.md` with frontmatter describing when to load it.

**Bevy / game dev** — `ecs`, `animation`, `assets`, `audio`, `camera`, `input`, `materials`, `networking`, `testing`, `ui`, `combat-ui`, `game-state`, `ai-strategy`

**Geometry & rendering** — `geometry`, `geometry-*` (marching cubes, dual contouring, SDF, triangulation, mesh stitching, decimation, extrusion, polygon offset, smoothing/subdivision, terrain architecture, coastal transitions, vertex-color shader, screenshot iteration, Blender mesh debug, debugging), `shader-debugging`, `wgsl-shaders`, `texture-debugging`, `vram-debugging`

**Rust** — `rust-ownership`, `rust-types`, `rust-errors`, `rust-idioms`, `rust-concurrency`, `rust-performance`, `rust-ecosystem`, `rust-learner`, `rust-skill-creator`, `unsafe-checker`

**SolidJS** — `solidjs-core`, `solidjs-components`, `solidjs-state`, `solidjs-architecture`, `solidjs-performance`, `solidjs-testing`, `solidjs-review`

**Meta** — `find-skills` (helps discover and install skills from this repo)

## Using these in Claude Code

Claude Code looks for agents and skills in `~/.claude/agents/` and `~/.claude/skills/` (user scope) or the project's `.claude/` directory (project scope).

To install everything globally, symlink or copy the contents:

```bash
# Unix-like
ln -s "$PWD/agents"/* ~/.claude/agents/
ln -s "$PWD/skills"/* ~/.claude/skills/
```

```powershell
# Windows (PowerShell, as admin for symlinks)
Get-ChildItem agents  | ForEach-Object { New-Item -ItemType SymbolicLink -Path "$HOME\.claude\agents\$($_.Name)" -Target $_.FullName }
Get-ChildItem skills  | ForEach-Object { New-Item -ItemType SymbolicLink -Path "$HOME\.claude\skills\$($_.Name)" -Target $_.FullName }
```

Or pick just the ones you want — each skill directory and each agent file is self-contained.

## Skill format

Every skill is a directory with at minimum a `SKILL.md`:

```markdown
---
name: my-skill
description: One-line trigger description — keywords matter, Claude reads this to decide when to load.
user-invocable: true          # optional — makes it available as /my-skill
allowed-tools: Read, Edit, Grep
---

# My Skill

Body content — guidance, examples, references.
```

Some skills (e.g. `unsafe-checker`) split rules and examples into subfiles alongside `SKILL.md`.

## Agent format

Agents are single Markdown files with frontmatter:

```markdown
---
name: my-agent
description: When to invoke this agent.
model: opus
tools:
  - Read
  - Bash
  - Grep
---

System prompt for the agent...
```
