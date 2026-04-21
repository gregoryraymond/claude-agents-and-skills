set shell := ["bash", "-uc"]

default:
    @just --list

# Copy agents and skills into ~/.claude/
sync: sync-agents sync-skills

# Copy agent files into ~/.claude/agents/
sync-agents:
    mkdir -p "$HOME/.claude/agents"
    cp -R agents/. "$HOME/.claude/agents/"

# Copy skill directories into ~/.claude/skills/
sync-skills:
    mkdir -p "$HOME/.claude/skills"
    cp -R skills/. "$HOME/.claude/skills/"
