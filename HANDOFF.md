# HANDOFF.md

Update before you stop. Newest entry on top.

## Status
- Completed: Modules 0-2; Module 3 wiring (track, dashboard command, registry, army skill)
- In flight: dash-server (codex, `scripts/dashboard.ps1` + tests), dash-ui (antigravity, `scripts/dashboard.html`)
- Next command: `trinity wait dash-server`, `trinity wait dash-ui`, then `trinity merge <task> -Yes` each, then `trinity dashboard`
- Blockers: none

## From Claude
- 2026-10-25: Dashboard module. Claude wrote the spec (`docs/dashboard.md`) and the CLI side; Codex builds the server, Antigravity the page, in parallel worktrees. Army skill (`~/.claude/skills/army/SKILL.md`) now routes chunks to Codex/Antigravity via trinity and tells Claude to `track` its own chunk.
- 2026-10-25: Codex wrote its own lookalike "done (...)" status mid-run; closed the hole (done refused for headless tasks, wait checks the runner pid). Suite now 12 cases, runs as the merge gate.
- 2026-10-25: All three harnesses now run the same way: `dispatch codex|antigravity` = headless worker in its own worktree, runner commits, board status, `wait`, `merge` (Codex review gate + Test command), `cancel`. Antigravity uses the `agy` CLI with `--dangerously-skip-permissions` (user's choice); task rules confine it to its worktree. Proven live in MetaStrip: Antigravity wrote `test/ui-hint.test.js`, merged through the gate, 24 tests pass there; the test fails correctly when a format is dropped from the UI hint.
- 2026-10-25: Split MetaStrip into its own repo at `D:\AI\projects\Dev\Projects\MetaStrip`; it uses this toolkit through `trinity init`. This repo is the toolkit only.
- 2026-10-25: Repo scaffolded. Codex reachable via `scripts\codex-*.cmd`.

## From Codex

## From Antigravity
