# AGENTS.md

Single source of truth for every agent in this repo: Claude Code, Codex, Antigravity (Gemini).
`CLAUDE.md` and `GEMINI.md` only point here. Edit rules HERE, nowhere else.

Global protocol also applies: `~/.codex/AGENTS.md` = `~/.gemini/AGENTS.md` (parallel-agent board + worktrees).

## Roles

Any of the three can orchestrate. The orchestrator is the agent the user is talking to in the main checkout (one at a time);
every other agent is a worker in its own worktree. Spec: `docs/orchestrator.md`.

| Role | Owns | Does not |
|------|------|----------|
| Orchestrator (Claude by default; Codex or Antigravity when the user drives from there) | Planning, `PLAN.md`/`HANDOFF.md`, shared files, dispatch, merges, commits on `main`, final verification | Edit a worker's files while it runs |
| Worker (dispatched, headless) | Its task, inside its worktree and scope; its final message is the summary | Commit (the runner does), touch `main`, the board, `HANDOFF.md` or `PLAN.md` |

Strengths, for routing work (whoever orchestrates):

| Agent | Best at |
|-------|---------|
| Claude Code | Cross-cutting design, tangled multi-file changes, visual checks of the running app (computer use) |
| Codex | Focused implementation, code review, second opinion, hard algorithm/debug tasks, long background tasks |
| Antigravity (Gemini) | UI work, browser-agent verification (screenshots/video), whole-repo reading, parallel agents |

Orchestrator start: run `trinity status -Brief` (Claude gets it from a SessionStart hook) and check its `orchestrator:` line.
If it names the wrong agent, pass `-Agent codex|antigravity|claude` on `track` or set `TRINITY_ORCHESTRATOR`.
Codex and Antigravity load the playbook from `.agents/skills/trinity/SKILL.md` (Claude: `.claude/skills/army/SKILL.md`).

## Shared memory (agents cannot see each other's chats)

- `PLAN.md`: per-module checklist. Whoever finishes a box ticks it.
- `HANDOFF.md`: what was done, what is in flight, next command, blockers. Update before you stop.
- Agent board: `<git-common-dir>/agent-board.md`, managed by `scripts/agent-task.ps1`. Not committed.
- `docs/failure-log.md`: every failure, error or surprise gets a row (date, where, what, cause, status). Workers put failures in their result file; the orchestrator logs them. Check it before repeating a risky step.

## Parallel work

- One writer per file set. Never two agents editing the same files at once.
- Parallel task = own worktree + branch `agent/<agent>/<task>`. Create and start with `trinity dispatch` (below),
  or create only with `scripts\agent-task.ps1`.
- Worktrees live in `..\Holy trinity.worktrees\`. Main checkout stays on `main`.
- Only the orchestrator (or the user) merges `agent/*` branches into `main`, always through `trinity merge`.
- Commit a checkpoint before handing work to another agent.

## trinity command (one entry point, cmd from repo root)

- From Git Bash (Claude's Bash tool, or any bash shell) run `./trinity.sh <command> ...` instead: started from there, `trinity.cmd` fails on any argument with spaces when the repo path has a space.
- `trinity status` : branch, agent availability (`agents:` line), worktrees, board, HANDOFF status. `orchestrator:` line names who is driving. Runs automatically when a Claude session starts here; Codex and Antigravity run it first themselves.
- `trinity dispatch codex <task> "<prompt>" -Scope "src/x/*"` : worktree + branch, then Codex works headless in the background (workspace-write, inside its worktree only). Board shows running/done; Windows notification when finished. Log, final summary and run metadata (`meta-<task>.json`: model, session, tokens, duration) in `.codex-out\`. Without Codex the task reroutes to Antigravity (and the reverse) with a notice.
- `trinity dispatch antigravity <task> "<prompt>" -Scope "src/ui/*"` : same as Codex, but Antigravity (Gemini, `agy -p` CLI) works headless in the worktree. Permissions are skipped, so the task rules confine it to its worktree; the runner commits.
- `trinity cancel <task>` : remove a task's worktree and branch, mark it cancelled (`-Force` if it has commits).
- `trinity dispatch claude <task> "<prompt>" -Headless` : Claude Code works headless in the worktree (`claude -p`, edits accepted), like Codex and Antigravity; the runner commits. Without `-Headless`: worktree + task file only; open a Claude session there.
- `trinity run <agent> <task> -PromptFile <file>` : dispatch, then wait for it to finish and print summary, commits, diffstat. Use `-PromptFile` for any prompt with quotes.
- `trinity wait <task> [-Timeout 1800]` : block until a task leaves running; exit 0 done, 1 failed, 2 still running.
- `trinity done <task> "<summary>"` : finish a `track`ed chunk, or a task done in an interactive session. Headless workers (any agent): never run this; the runner commits your work and marks the task itself.
- `trinity merge <task>` : review of the branch (Codex, else the fallback reviewer below), blocks on P0/P1 findings, merge into `main`, run the Test command, remove worktree and branch.
  Findings that only concern "Shared files" (Project commands below) on a branch that left them untouched are deferred, not blocking: the orchestrator wires them after the merge (`.codex-out\deferred-<task>.txt`).
  Refuses a task that is still running. Files changed outside the task's `-Scope` block the merge unless `-Force` (`TRINITY_SCOPE_GUARD=block|warn|off`, or `scopeGuard` in `.trinity\trinity.json`).
  `-DryRun`: review, conflict check against the base, tests and scope check only; merges nothing, prints `dry run clean: ...` (the dashboard Review button).
- `trinity config get [key]` / `trinity config set <key> <value>` : per-repo settings in `.trinity\trinity.json` (gitignored; slots, base, test, deadlineMinutes, models, autopilot). Spec: `docs/dashboard-gui.md`. Env vars beat the file.
- `TRINITY_CODEX_MODEL=<model>` / `TRINITY_CODEX_EFFORT=minimal|low|medium|high|xhigh` : model and reasoning effort for every Codex call (dispatch, review, ask), overriding `~/.codex/config.toml`. A low effort there can make workers stop early.
- `trinity init <path>` : install or update this toolkit in another git repo (scripts, `.claude/agents/` subagents, `/army` skill). Toolkit files are refreshed; that repo's docs (AGENTS.md, PLAN.md, ...) are kept unless `-Force`.
- `trinity review [--base <b> | --commit <sha>]` / `trinity ask "<question>"` : read-only review or question. Reviewer: the first of Codex, Claude Code headless (if `claude auth status` is logged in), Antigravity in plan mode that did not write the change (for `review`/`ask`: not the orchestrator); the output starts with `reviewer: <agent>`.
- No ChatGPT plan: everything above works with Claude + Antigravity. `TRINITY_DISABLE=codex` (comma list) turns an agent off; `TRINITY_REVIEWER=codex|claude|antigravity|none` picks the reviewer (`none`: tests alone gate merges).
- `trinity track <task> <note...> [-Agent <a>]` : the orchestrator puts its own chunk on the board under its own name (status `working: <note>`), linked to its session for the dashboard; finish with `trinity done <task> "<summary>"`.
- `trinity dashboard [-Port 7777]` : live page of all three agents across every trinity repo (`http://localhost:7777/`). `-Json` prints the state once, `-Stop` stops the server. Repos are listed in `%USERPROFILE%\.trinity\repos.txt` by `init`/`setup`. Spec: `docs/dashboard.md`.
- `trinity ui` : open Antigravity on the main checkout.
- `trinity setup` : once per clone; enables `.githooks` (pre-commit checks script encoding and secrets) and lists the repo for the dashboard.

## Codex calls (from any shell, cmd syntax)

- These wrappers call `trinity review` / `trinity ask`, so they fall back to Claude or Antigravity when Codex is unavailable.
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
- Test: `tests\run-tests.cmd` (shards default to min(4, cores); set `TRINITY_TEST_JOBS` to 1..64 to override, use 2 under low RAM)
- Run: `trinity help`
- Shared files: `AGENTS.md`, `CLAUDE.md`, `scripts/lib/board.ps1`

## Conventions

- Minimal diffs. No unrelated reformatting. No new dependency without a note in `HANDOFF.md`.
- Never write real keys into committed files. Real keys go in gitignored `.env`.
- Done = exercised in the running app, not just typechecked. Show evidence.
