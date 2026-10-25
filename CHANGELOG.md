# Changelog

## Unreleased

### Added
- `trinity` command: `status`, `dispatch` (Codex headless in background, Antigravity opened with the prompt, Claude task file), `merge` (review, merge, test, cleanup), `review`, `ask`, `ui`, `setup`.
- Windows notification and board status update when a dispatched Codex task finishes.
- Claude Code session-start hook showing `trinity status -Brief`.
- `.githooks/pre-commit`: `.ps1`/`.cmd` encoding checks and secret scan.
- README: quick start for automatic mode.
- Auto-delegation: `.claude/agents/` subagents `codex-worker`, `codex-reviewer`, `antigravity-ui`; routing rules in `CLAUDE.md`.
- `trinity run` (dispatch + wait), `trinity wait`, `trinity done`.
- `trinity init <path>`: install or update the toolkit in another repo.
- `merge` defers findings about "Shared files" (AGENTS.md) on branches that did not touch them.
- `tests/`: end-to-end self-test with a fake Codex; it is the repo's Test command.
- Antigravity dispatch runs headless through the `agy` CLI, same lifecycle as Codex.
- `trinity cancel <task>`: stops the runner, removes worktree and branch.
- `init` removes retired toolkit files from installs.
- `trinity dashboard`: local read-only page (`scripts/dashboard.ps1` server + `scripts/dashboard.html`) with one lane per agent across every repo in `%USERPROFILE%\.trinity\repos.txt`; `-Json`, `-Stop`, `-Port`.
- `trinity track <task> <note>`: Claude's own work shows on the board and dashboard next to its workers.
- `init` and `setup` register the repo for the dashboard.

### Changed
- MetaStrip, the first test project, moved to its own repo. This repo is now only the toolkit.
- Subagent definitions use the current repo root instead of a hardcoded path.
- Board and worktree logic moved to `scripts/lib/board.ps1`; `agent-task.ps1` uses it.

### Fixed
- `trinity wait` returned on a bare `done` before the Codex runner had committed.

## v0.1.0 - 2026-10-25

First release: shared workspace for Claude Code, Codex, and Antigravity (Gemini).

### Added
- `AGENTS.md` as the single rules file for all three agents; `CLAUDE.md` imports it, `GEMINI.md` and `.agent/rules/` point to it.
- `PLAN.md` and `HANDOFF.md` as cross-agent shared memory.
- `scripts/codex.cmd`: runs the Codex CLI bundled with the Codex desktop app (not on PATH).
- `scripts/codex-review.cmd`: Codex code review of uncommitted changes, a branch, or a commit, forced read-only.
- `scripts/codex-ask.cmd`: one-shot read-only Codex question; prompt as argument or stdin.
- `scripts/agent-task.ps1`: isolated worktree + `agent/<agent>/<task>` branch per parallel task, registered on a lock-protected shared board.
