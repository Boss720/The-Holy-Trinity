# HANDOFF.md

Update before you stop. Newest entry on top.

## Status
- Completed: Module 0, Module 1, Module 2 except the two open boxes in PLAN.md
- In flight: Codex task `selftest-agy` (fake agy + cancel cases in tests/)
- Next command: `trinity merge selftest-agy -Yes` once the board shows done (merge now runs `tests\run-tests.cmd`)
- Blockers: `git push` fails, GitHub token for Boss720 expired; re-auth needed

## From Claude
- 2026-10-25: All three harnesses now run the same way: `dispatch codex|antigravity` = headless worker in its own worktree, runner commits, board status, `wait`, `merge` (Codex review gate + Test command), `cancel`. Antigravity uses the `agy` CLI with `--dangerously-skip-permissions` (user's choice); task rules confine it to its worktree. Proven live in MetaStrip: Antigravity wrote `test/ui-hint.test.js`, merged through the gate, 24 tests pass there; the test fails correctly when a format is dropped from the UI hint.
- 2026-10-25: Split MetaStrip into its own repo at `D:\AI\projects\Dev\Projects\MetaStrip`; it uses this toolkit through `trinity init`. This repo is the toolkit only.
- 2026-10-25: Repo scaffolded. Codex reachable via `scripts\codex-*.cmd`.

## From Codex

## From Antigravity
