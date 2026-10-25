# Changelog

## v0.1.0 - 2026-10-25

First release: shared workspace for Claude Code, Codex, and Antigravity (Gemini).

### Added
- `AGENTS.md` as the single rules file for all three agents; `CLAUDE.md` imports it, `GEMINI.md` and `.agent/rules/` point to it.
- `PLAN.md` and `HANDOFF.md` as cross-agent shared memory.
- `scripts/codex.cmd`: runs the Codex CLI bundled with the Codex desktop app (not on PATH).
- `scripts/codex-review.cmd`: Codex code review of uncommitted changes, a branch, or a commit, forced read-only.
- `scripts/codex-ask.cmd`: one-shot read-only Codex question; prompt as argument or stdin.
- `scripts/agent-task.ps1`: isolated worktree + `agent/<agent>/<task>` branch per parallel task, registered on a lock-protected shared board.
