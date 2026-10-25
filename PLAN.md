# PLAN.md

Per-module checklist. Owner = claude | codex | antigravity.

## Module 0: Setup
- [x] Shared rules (`AGENTS.md`, `CLAUDE.md`, `GEMINI.md`) - claude
- [x] Codex wrappers (`scripts\codex-review.cmd`, `scripts\codex-ask.cmd`) - claude
- [x] Worktree + board script (`scripts\agent-task.ps1`) - claude

## Module 1: Automation
- [x] `trinity` CLI: status, dispatch, run, wait, done, merge, review, ask, ui, setup - claude
- [x] Codex runner commits for Codex (sandbox keeps .git read-only) - claude
- [x] Session-start hook, pre-commit hook - claude
- [x] Proven on a real project: MetaStrip, now its own repo - claude + codex

## Module 2: Unison (one team, three harnesses)
- [x] Claude subagents that drive Codex and Antigravity (`.claude/agents/`) - claude
- [x] `wait` race fix: Codex tasks finish only on runner status - claude
- [x] Shared-file findings deferred at merge instead of forcing - claude
- [x] Portable subagent defs; `trinity init <path>` installs into any repo - claude
- [x] End-to-end self-test with fake Codex (`tests/`, 7 cases) - codex (task selftest)
- [x] Antigravity headless via `agy -p` (IDE `chat` never started an agent); live run in MetaStrip merged - claude + antigravity
- [x] `trinity cancel` stops the runner tree; verified live - claude
- [x] Self-test covers Antigravity, cancel, forged done (12 cases) - codex + claude (task selftest-agy)
- [x] Only the runner can finish a headless task (done refused, live runner pid = pending) - claude
- [ ] Windows notification seen on screen (code runs without error; not visually confirmed) - user
