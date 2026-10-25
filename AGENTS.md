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
- Parallel task = own worktree + branch `agent/<agent>/<task>`. Create and start with `trinity dispatch` (below),
  or create only with `scripts\agent-task.ps1`.
- Worktrees live in `..\Holy trinity.worktrees\`. Main checkout stays on `main`.
- Only Claude (or the user) merges `agent/*` branches into `main`.
- Commit a checkpoint before handing work to another agent.

## trinity command (one entry point, cmd from repo root)

- `trinity status` : branch, worktrees, board, HANDOFF status. Runs automatically when a Claude session starts here.
- `trinity dispatch codex <task> "<prompt>" -Scope "src/x/*"` : worktree + branch, then Codex works headless in the background (workspace-write, inside its worktree only). Board shows running/done; Windows notification when finished. Log and final summary in `.codex-out\`.
- `trinity dispatch antigravity <task> "<prompt>"` : worktree + branch, then Antigravity opens there with the task loaded in agent mode.
- `trinity dispatch claude <task> "<prompt>"` : worktree + task file; open a Claude session there.
- `trinity run <agent> <task> -PromptFile <file>` : dispatch, then wait for it to finish and print summary, commits, diffstat. Use `-PromptFile` for any prompt with quotes.
- `trinity wait <task> [-Timeout 1800]` : block until a task leaves running; exit 0 done, 1 failed, 2 still running.
- `trinity done <task> "<summary>"` : Antigravity/Claude agents mark their task finished. Codex: never run this; the runner commits your work and marks the task itself.
- `trinity merge <task>` : Codex review of the branch, blocks on P0/P1 findings, merge into `main`, run the Test command, remove worktree and branch.
  Findings that only concern "Shared files" (Project commands below) on a branch that left them untouched are deferred, not blocking: the orchestrator wires them after the merge (`.codex-out\deferred-<task>.txt`).
- `trinity init <path>` : install or update this toolkit in another git repo. Toolkit files are refreshed; that repo's docs (AGENTS.md, PLAN.md, ...) are kept unless `-Force`.
- `trinity review` / `trinity ask "<question>"` : read-only Codex.
- `trinity ui` : open Antigravity on the main checkout.
- `trinity setup` : once per clone; enables `.githooks` (pre-commit checks script encoding and secrets).

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

- Install: none (`trinity setup` once per clone)
- Typecheck/build: none (PowerShell 5.1 scripts; the test suite parse-checks them)
- Test: `TBD` (becomes `tests\run-tests.cmd` once the selftest suite lands)
- Run: `trinity help`
- Shared files: `AGENTS.md`, `CLAUDE.md`, `scripts/lib/board.ps1`

## Conventions

- Minimal diffs. No unrelated reformatting. No new dependency without a note in `HANDOFF.md`.
- Never write real keys into committed files. Real keys go in gitignored `.env`.
- Done = exercised in the running app, not just typechecked. Show evidence.
