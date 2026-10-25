# AGENTS.md

Single source of truth for every agent in this repo: Claude Code, Codex, Antigravity (Gemini).
`CLAUDE.md` and `GEMINI.md` only point here. Edit rules HERE, nowhere else.

Global protocol also applies: `~/.codex/AGENTS.md` = `~/.gemini/AGENTS.md` (parallel-agent board + worktrees).

## Roles

| Agent | Owns | Does not |
|-------|------|----------|
| Claude Code (desktop) | Orchestration, planning, main edits, tests, git commits, final verification | Bulk whole-repo reading when Gemini is free |
| Codex | Code review, second opinion, hard algorithm/debug tasks, long background tasks | Commit to `main` |
| Antigravity (Gemini) | UI work, browser-agent verification (screenshots/video), whole-repo reading, parallel agents | Commit to `main` |

## Shared memory (agents cannot see each other's chats)

- `PLAN.md`: per-module checklist. Whoever finishes a box ticks it.
- `HANDOFF.md`: what was done, what is in flight, next command, blockers. Update before you stop.
- Agent board: `<git-common-dir>/agent-board.md`, managed by `scripts/agent-task.ps1`. Not committed.

## Parallel work

- One writer per file set. Never two agents editing the same files at once.
- Parallel task = own worktree + branch `agent/<agent>/<task>`. Create with:
  `powershell -ExecutionPolicy Bypass -File scripts\agent-task.ps1 -Agent codex -Task login-form -Scope "src/auth/*"`
- Worktrees live in `..\Holy trinity.worktrees\`. Main checkout stays on `main`.
- Only Claude (or the user) merges `agent/*` branches into `main`.
- Commit a checkpoint before handing work to another agent.

## Codex calls (from any shell, cmd syntax)

- `scripts\codex-review.cmd` : review uncommitted changes, read-only.
- `scripts\codex-review.cmd --base main` : review branch vs main.
- `scripts\codex-ask.cmd "question"` : one-shot read-only answer, saved to `.codex-out\codex-last.md`.
- From Git Bash (Claude's Bash tool) pipe the prompt instead, quoted args break on the space in this path:
  `echo "question" | ./scripts/codex-ask.cmd`
- Wrappers always force `--sandbox read-only`. Global Codex config is `danger-full-access`; never call bare `codex exec` from an agent.

## Environment

- Windows 11, user shell cmd.exe. PowerShell scripts target PS 5.1: UTF-8 BOM, CRLF, ASCII only.
- C: drive is nearly full. Keep builds, caches, `node_modules` on D:.

## Project commands

Fill these in when code lands. Every agent runs them before claiming done.

- Install: `TBD`
- Typecheck/build: `TBD`
- Test: `TBD`
- Run: `TBD`

## Conventions

- Minimal diffs. No unrelated reformatting. No new dependency without a note in `HANDOFF.md`.
- Never write real keys into committed files. Real keys go in gitignored `.env`.
- Done = exercised in the running app, not just typechecked. Show evidence.
