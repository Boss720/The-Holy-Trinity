# The Holy Trinity

A coordination toolkit that makes three coding agents work on one repo as a team, without stepping on each other:

- **Claude Code** (desktop): orchestrator. Plans, splits work, delegates, merges, verifies.
- **Codex**: headless worker in its own worktree, and the reviewer gate before every commit and merge.
- **Antigravity** (Gemini): UI work and browser-agent verification.

All three read the same rules file (`AGENTS.md`) and talk to each other through files, because none of them can see the others' chats.

This repo is the toolkit itself. Install it into any project with `trinity init <path>` (see "Use it in another project").

## Requirements

- Windows 10/11, git
- [Claude Code desktop](https://claude.com/claude-code)
- Codex desktop app (the scripts use the `codex.exe` it ships with; set `CODEX_EXE` to override)
- Antigravity CLI (`agy`, used headless for dispatched tasks; set `AGY_EXE` to override) and optionally Antigravity IDE (`antigravity-ide`, for `trinity ui`)

## Repo layout

| Path | Purpose |
|---|---|
| `AGENTS.md` | Single source of truth for rules, roles, commands. Edit rules here only. |
| `CLAUDE.md` | Imports `AGENTS.md` and adds Claude-only rules. |
| `GEMINI.md`, `.agent/rules/` | Point Antigravity to `AGENTS.md`. |
| `PLAN.md` | Per-module checklist of what to build. |
| `HANDOFF.md` | What was done, what is next, blockers. Each agent writes its own section. |
| `CHANGELOG.md` | Release notes. |
| `scripts/codex.cmd` | Runs the Codex CLI bundled with the Codex app. |
| `scripts/codex-review.cmd` | Codex code review, forced read-only. |
| `scripts/codex-ask.cmd` | One-shot read-only Codex question. |
| `trinity.cmd`, `scripts/trinity.ps1` | One command for status, dispatch, merge, review, ask. |
| `scripts/lib/board.ps1` | Shared board/worktree helpers. |
| `.githooks/pre-commit` | Encoding and secret checks (enabled by `trinity setup`). |
| `.claude/settings.json` | Session-start hook that shows `trinity status`. |
| `scripts/agent-task.ps1` | Creates a worktree + branch per parallel task and registers it on the agent board. |
| `.claude/agents/` | Claude subagents that drive Codex and Antigravity (`codex-worker`, `codex-reviewer`, `antigravity-worker`). |
| `tests/` | End-to-end self-test of the trinity CLI against throwaway repos with a fake Codex (`tests\run-tests.cmd`). |

## Use it in another project

```bat
trinity init D:\code\myapp
```

Copies the toolkit (trinity CLI, Codex wrappers, subagent definitions, pre-commit hook) and writes `AGENTS.md`, `CLAUDE.md`, `GEMINI.md`, `PLAN.md`, `HANDOFF.md` if missing. Then fill in "Project commands" in that repo's `AGENTS.md`: the `Test` line is what `trinity merge` runs, and `Shared files` lists files only Claude edits (registries, `package.json`). Commit, and open a new Claude session there so the subagents load.

Rerun `init` to update an install: toolkit files are refreshed, the project's own docs are kept (`-Force` replaces them). Example install: the MetaStrip app (`D:\AI\projects\Dev\Projects\MetaStrip`).

## Quick start (automatic mode)

One command, `trinity`, drives everything. Run once per clone:
```bat
trinity setup
```

Hand a task to Codex. It gets its own worktree and branch, works headless in the background, and a Windows notification pops up when it finishes:
```bat
trinity dispatch codex add-search "Add a search command with tests" -Scope "src/search/*"
```

Hand a UI task to Antigravity. Same flow as Codex: it works headless (Gemini via the `agy` CLI) in its own worktree, and the runner commits when it finishes:
```bat
trinity dispatch antigravity polish-ui "Make the settings page responsive" -Scope "src/ui/*"
```

See who is doing what (Claude also sees this automatically at session start):
```bat
trinity status
```

When a task shows `done`, review, merge, test, and clean up in one step:
```bat
trinity merge add-search
```

`merge` blocks if Codex's review finds P0/P1 issues, and aborts the merge if the project's Test command (in `AGENTS.md`) fails.

What runs by itself:

| Trigger | What happens |
|---|---|
| Claude session starts | `trinity status -Brief` is injected (via `.claude/settings.json` hook) |
| Claude is about to commit | Codex review runs first (rule in `CLAUDE.md`) |
| Any `git commit` | `.githooks/pre-commit` checks `.ps1`/`.cmd` encoding and blocks likely secrets |
| Dispatched Codex or Antigravity finishes | Its changes are committed on its branch (Codex's sandbox keeps `.git` read-only, so the runner commits, using Codex's summary as the message), board status set to done/failed, result saved to `.codex-out\`, Windows notification |

### Auto-delegation (Claude drives the other two)

You talk to Claude only. Claude routes work to Codex and Antigravity through three subagents in `.claude/agents/` (loaded when a Claude session starts):

| Subagent | Wraps | Gets |
|---|---|---|
| `codex-worker` | `trinity dispatch codex` + `trinity wait` | Self-contained coding tasks with a clear file scope |
| `codex-reviewer` | `scripts\codex-review.cmd` / `codex-ask.cmd` | Review before every commit and merge, second opinions |
| `antigravity-worker` | `trinity dispatch antigravity` + `trinity wait` | UI/frontend code and big-context tasks, headless via the `agy` CLI |

The routing table and rules live in `CLAUDE.md`. Typical run: Claude splits a feature by files, launches several `codex-worker`s at once, keeps working itself, then runs `trinity merge <task> -Yes` per branch and wires shared files (registries, `package.json`) itself. Workers never touch shared files, so a review finding like "handler not registered" on a worker branch is expected. `merge` defers P0/P1 findings that mention a shared file when the branch left shared files untouched, writes them to `.codex-out\deferred-<task>.txt`, and Claude wires them on `main`. Every other P0/P1 still blocks.

First real run (in MetaStrip, before it moved to its own repo): two Codex workers built GIF and ODF stripping in parallel; Codex review then caught two real bugs that Claude fixed on `main`.

---

## How to use it (manual mode)

All commands below are for cmd, run from the repo root.

### Part 1: One-time checks

1. Open the folder in Antigravity and click **Yes, I trust the authors**. In Restricted Mode its agent features are off.
2. Optional: turn on Windows Developer Mode so `mklink` works without an admin window.
   ```bat
   start ms-settings:developers
   ```

### Part 2: Normal loop (one task at a time)

1. **Open Claude Code** on this folder.
2. **Give Claude the task** in plain words, for example "Build a Python CLI todo app with tests."
   Claude adds a checklist to `PLAN.md`, writes the code, fills in "Project commands" in `AGENTS.md`, and runs the tests.
3. **Codex reviews automatically.** `CLAUDE.md` requires a Codex review before every commit. Claude runs it in the background, fixes the real findings, and reports what changed.
4. **Claude commits.** Say "push" when you want it on GitHub.
5. **If the change has a UI**, Claude writes in `HANDOFF.md` what Antigravity should check. Open Antigravity on the folder:
   ```bat
   antigravity-ide .
   ```
   Then paste this into Antigravity's agent panel:
   > Read HANDOFF.md. Do the checks listed for Antigravity. Write results under "From Antigravity". Don't commit.
6. **Back in Claude**, say: "Read HANDOFF.md and fix what Antigravity found."

### Part 3: Ask Codex yourself

Review uncommitted changes:
```bat
scripts\codex-review.cmd
```

Review a whole branch against `main`:
```bat
scripts\codex-review.cmd --base main
```

Ask a one-off question (the answer is also saved to `.codex-out\codex-last.md`):
```bat
scripts\codex-ask.cmd "Why does the save test fail? Give file:line."
```

From Git Bash, pipe the prompt instead of quoting it. Quoted arguments break when the repo path contains a space:
```bash
echo "Why does the save test fail?" | ./scripts/codex-ask.cmd
```

### Part 4: Parallel loop (several agents at once)

1. **Split the work by files.** Two agents must never edit the same files.
2. **Create one worktree per task.**

   Codex works on authentication:
   ```bat
   powershell -ExecutionPolicy Bypass -File scripts\agent-task.ps1 -Agent codex -Task login-form -Scope "src/auth/*"
   ```
   Antigravity works on the UI and opens its window automatically (`-Open`):
   ```bat
   powershell -ExecutionPolicy Bypass -File scripts\agent-task.ps1 -Agent antigravity -Task ui-pass -Scope "src/ui/*" -Open
   ```
   Worktrees are created next to the repo, in `<repo-folder>.worktrees\<agent>-<task>`, on branch `agent/<agent>/<task>`.
3. **Start each agent in its own folder.**
   - **Codex:** in the task's worktree, run `scripts\codex.cmd`, or open that folder in the Codex app.
   - **Antigravity:** already open if you used `-Open`.
   - **Claude:** start a new session on the task's worktree.
4. **Give each agent this prompt:**
   > Read the agent board and AGENTS.md. Do your task within your scope. Commit on your branch. Update the board when done.
5. **See who is doing what:**
   ```bat
   powershell -ExecutionPolicy Bypass -File scripts\agent-task.ps1 -List
   ```
6. **Merge when the agents are done.** In your main Claude session, say "Review and merge agent/codex/login-form." Claude reviews the branch with Codex, merges it into `main`, and runs the tests.
7. **Clean up** after merging:
   ```bat
   git worktree remove "..\<repo-folder>.worktrees\codex-login-form"
   ```
   ```bat
   git branch -d agent/codex/login-form
   ```

### Part 5: Release

Tell Claude "Cut release v0.2.0." It updates `CHANGELOG.md`, gets a Codex review, commits, tags, pushes, and creates the GitHub release.

---

## How it works

### Rule loading

Each tool reads its own file automatically when it starts:

| Tool | Reads | Which leads to |
|---|---|---|
| Claude | `CLAUDE.md` | `AGENTS.md` (via the `@AGENTS.md` import line) |
| Codex | `AGENTS.md`, `~/.codex/AGENTS.md` | Project rules, plus your global rules |
| Antigravity | `GEMINI.md`, `.agent/rules/`, `~/.gemini/AGENTS.md` | `AGENTS.md`, plus your global rules |

Every path ends at `AGENTS.md`, so rules are edited in one place.

If you share one global rules file between tools with a symlink, create it with `mklink` from cmd, not `ln -s` from Git Bash or WSL. Those create Linux-style links that native Windows apps such as Codex and Antigravity cannot read.

### Shared memory

Agents cannot see each other's chats. They communicate through `PLAN.md` (what to build), `HANDOFF.md` (what is done and what is next), and git commits, which carry both files to everyone.

### Codex wrappers

- `codex.cmd` finds the newest `codex.exe` installed with the Codex desktop app (it is not on PATH) and always runs from the repo root of the checkout it lives in.
- `codex-review.cmd` and `codex-ask.cmd` force a **read-only** sandbox, whatever your global Codex config says. Codex can read and report, never edit.

### Worktrees and the board

- A git worktree is a second checkout of the same repo on its own branch, sharing the same history. Agents in separate worktrees cannot overwrite each other's files.
- The agent board lives at `.git/agent-board.md`. Every worktree sees the same board, and it is never committed.
- A lock file serializes board writes, so two agents starting tasks at the same moment cannot clobber each other's entries.

### Who merges

Only Claude (or you) merges into `main`. Codex and Antigravity work on `agent/*` branches, so `main` only receives reviewed code.
