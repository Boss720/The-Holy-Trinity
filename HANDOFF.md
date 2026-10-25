# HANDOFF.md

Update before you stop. Newest entry on top.

## Status
- Completed: Modules 0-3 (dashboard live: `trinity dashboard`)
- In flight: none
- Next command: `trinity dashboard` to watch; `trinity init <repo>` to add a repo to it
- Blockers: none (one PLAN box needs the user: notification seen on screen)

## From Claude
- 2026-10-25: Dashboard merged. Gate caught two real failures in Codex's tests (em-dash in a result file read as ANSI became a bare quote in the JSON; tests read the real `~/.trinity` registry); fixed on the worker branch, then merged 16/16. agy's `-p` stdout includes `<SYSTEM_MESSAGE>` background notices; one became the `dash-ui` commit subject (705517b, left in history). Runner now strips them; fake agy emits one so the suite guards it.
- 2026-10-25: Dashboard module. Claude wrote the spec (`docs/dashboard.md`) and the CLI side; Codex builds the server, Antigravity the page, in parallel worktrees. Army skill (`~/.claude/skills/army/SKILL.md`) now routes chunks to Codex/Antigravity via trinity and tells Claude to `track` its own chunk.
- 2026-10-25: Codex wrote its own lookalike "done (...)" status mid-run; closed the hole (done refused for headless tasks, wait checks the runner pid). Suite now 12 cases, runs as the merge gate.
- 2026-10-25: All three harnesses now run the same way: `dispatch codex|antigravity` = headless worker in its own worktree, runner commits, board status, `wait`, `merge` (Codex review gate + Test command), `cancel`. Antigravity uses the `agy` CLI with `--dangerously-skip-permissions` (user's choice); task rules confine it to its worktree. Proven live in MetaStrip: Antigravity wrote `test/ui-hint.test.js`, merged through the gate, 24 tests pass there; the test fails correctly when a format is dropped from the UI hint.
- 2026-10-25: Split MetaStrip into its own repo at `D:\AI\projects\Dev\Projects\MetaStrip`; it uses this toolkit through `trinity init`. This repo is the toolkit only.
- 2026-10-25: Repo scaffolded. Codex reachable via `scripts\codex-*.cmd`.

## From Codex

## From Antigravity
