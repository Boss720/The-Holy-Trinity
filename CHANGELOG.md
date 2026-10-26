# Changelog

## v0.4.0 - 2026-10-26

### Added
- Release install: GitHub releases now ship `trinity-vX.Y.Z.zip` + `.sha256` (built by `scripts\build-release.ps1`, published by `.github/workflows/release.yml` on a `vX.Y.Z` tag, CI in `ci.yml`). `install.cmd` checks prerequisites, can install Git with winget (`-InstallGit`), put `trinity` on the user PATH (`-AddToPath`) and run `trinity init` (`-Init <path>`). `docs/claude-install-prompt.md` is the same install as a prompt for Claude Code. `INSTALL.md` has the steps and a troubleshooting table.
- `trinity doctor [-Json]` checks Windows, PowerShell, git (2.31+), git identity, Claude/Codex/Antigravity CLIs and logins, PATH, repo hooks and disk, and prints the exact fix for each problem. `trinity version`, `VERSION` file.
- Dashboard GUI step 1 (read-only): Inbox view (default) with a needs-attention list and running tasks, Health view, `#task=<repo>/<task>` deep links, data-age chip, "server outdated" banner. `/api/state` gains `server`, `attention` and `health`. Spec: `docs/reco/gui-step1.md`.
- Dashboard: "Copy merge" button on finished tasks; dashboard request errors logged to `%USERPROFILE%\.trinity\dashboard-errors.log`.
- `trinity init` merges the SessionStart hook into a kept `.claude\settings.json` (original saved to `.codex-out\settings.json.bak`) and upgrades the old hook command.

### Fixed
- `install.cmd -AddToPath` / `-RemoveFromPath` edit the User PATH in the registry as an expandable value: `%VAR%` entries survive, the previous value is saved to `%USERPROFILE%\.trinity\user-path-backup.txt`, and a failure is reported instead of being swallowed.
- `trinity dispatch` in a repo with no commits, or without a `main` branch, says what to do (first commit, `git branch -m main` or `-Base`) instead of a raw git error.
- A release copy of the toolkit (no `.git`) works: `help`, `version`, `doctor` and `init` no longer need a repo, and every other command uses the git repo of the current folder instead of failing with "not inside a git repo". A repo that merely contains the extracted folder is not mistaken for the project.
- Codex CLI installed by the official standalone installer (`%LOCALAPPDATA%\Programs\OpenAI\Codex\bin\codex.exe`) is found by `Find-CodexExe` and `scripts\codex.cmd`.
- SessionStart hook works when Claude starts in a subfolder (resolves the repo root with git).
- Pre-commit hook also checks renamed and type-changed files, and fails if it cannot list staged files.
- `agy.cmd` / `agy.bat` on PATH count as Antigravity.
- `trinity track` validates task names; a task name still on the board cannot be dispatched again, while a merged or cancelled name is reused without leaving a stale board section.
- `GEMINI.md`: headless Antigravity tasks put findings in their final message, not `HANDOFF.md`.
- Dashboard: dark-mode muted text contrast; 44px touch targets on phones.
- Dashboard page polls with one request in flight (next poll after the reply, backoff on errors, paused while the tab is hidden) and shows "connecting" instead of zero counts before the first reply; the chat drawer skips a live tick while a fetch is pending.
- Dashboard server answers loopback clients only (http.sys listened on every interface); the dead `127.0.0.1` Host entry is gone.
- Dashboard server deduplicates registry paths, reads only the 5 newest Claude sessions and caches their summaries by size and write time: warm `/api/state` 3.9 s -> 1.1 s on three repos.
- Dashboard server builds the state once in a background runspace and serves the same snapshot to every client (header `X-Snapshot-Age-Ms`; idles with no clients). Six open tabs: median reply 7.9 s -> 13 ms.
- Removed two empty junk files (`Read`, `[-Force]'`).
- Antigravity commit subjects and results come from the agent's final message. `agy -p` joins every turn's text into its answer, so a run that paused for background tests was committed as "Running tests to verify...". The runner now reads the final turn from the session transcript.
- `trinity.sh`: Git Bash entry point, installed by `init`. `trinity.cmd` started from Git Bash failed on any argument with spaces when the repo path had a space (`'D:\...\Holy' is not recognized`), because Windows runs a .cmd through `cmd /c`, which strips the outer quotes. It converts only drive paths (`/c/...`), so an argument such as `/army ...` is no longer rewritten into a Git install path.
- Self-test counts skipped cases separately (`31 passed, 0 failed, 1 skipped`) instead of as passes.

## v0.3.0 - 2026-10-25

### Added
- `/army` skill packaged in `.claude/skills/army/`; `trinity init` installs and refreshes it in every trinity repo.

## v0.2.0 - 2026-10-25

### Added
- Dashboard detail v3 for every agent: context in use, steps, thinking steps, per-tool call counts, last tool, files touched, background tasks (tool bars and file list in the task drawer). Antigravity tasks without a meta file or CLI log are found by their task file in the agy transcripts, so older runs show model, tokens, tools, duration and chat too.
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
- `TRINITY_HOME` overrides `%USERPROFILE%\.trinity` (registry, dashboard pid); the self-test isolates itself with it.

- Dashboard v2 (`docs/dashboard.md`): per task model, effort, tokens, context window, tool calls, rate limits, duration, last activity; agent availability; Claude Code sessions with their subagents; chat drawer for Codex, Antigravity, Claude sessions and Claude/Codex subagents (`GET /api/chat`, redacted, host-guarded).
- No-Codex mode: availability check (`codex login status`, `claude auth status`, agy on PATH); `dispatch codex` reroutes to Antigravity (and the reverse); `review`/`ask`/`merge` fall back to Claude Code headless, then Antigravity plan mode, then tests alone. `TRINITY_DISABLE`, `TRINITY_REVIEWER`.
- Runner writes `.codex-out\meta-<task>.json` (model, session, tokens, duration) for Codex and Antigravity runs.

### Fixed (dashboard)
- Antigravity background tasks are counted by distinct task id, not by every `manage_task` status call.
- Codex subagent chats: matched by `parent_thread_id`, child id from the file name (its `session_id` is the parent's), next-day folders scanned, list refreshed while the task runs. Rollout day-folder lookup used `yyyy\MM\dd`, which formats as `2026M10d25`.
- Claude session card no longer blanks model and context when one big tool result fills the read window.
- Chat drawer keeps the reader's scroll position and ignores stale responses; subagent running state uses the collector's `active` flag.
- `trinity review --commit` / `--base` without a value fails with usage instead of reviewing uncommitted changes.
- Antigravity runs: the runner strips `agy -p` background `<SYSTEM_MESSAGE>` notices from the result before using it as the commit message, and reads results as UTF-8.

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
