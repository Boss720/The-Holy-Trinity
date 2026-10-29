# Changelog

## v0.8.6 - 2026-10-29

### Added
- `docs/reco/mock-6-dark.html`: dark dashboard mock matching the v0.8.5 interface (Inbox, Overview, Board, Tasks, Health and History tabs; Auto, Stop all, Notifications and Dispatch in the header; confirm dialog with Copy cmd; Dispatch dialog). Design reference only, not served by the dashboard.

### Fixed
- Changelog: the v0.8.5 `-Filter` entry names `tests\run-tests.cmd` correctly.

## v0.8.5 - 2026-10-29

### Added
- Dashboard header Auto button (counterpart of Stop all): turns on autopilot and starts the scheduler in every repository where autopilot is off, paused or the scheduler is not alive; confirm dialog first, unpauses first when paused. Warns in sample mode.
- `tests\run-tests.cmd -Filter <wildcard>` runs only matching test cases.
- Docs-only merges (every changed file is plain `.md`) skip the Test command; the review still runs. `TRINITY_DOCS_ONLY_SKIP=0` forces tests.
- Duration-based shard balancing for the test runner.

### Changed
- Codex workers in narrow-sandbox mode get write access to their own worktree git directory only (`--add-dir`), not the shared common git directory.
- Dashboard status group wraps at 375px (no horizontal scroll).
- Docs: README, AGENTS.md, dashboard docs, failure log, PLAN/HANDOFF and recommendations status brought up to date.

### Fixed
- Worktree removal retries on lock failures during cancel and merge.
- Scheduler seeding skips unreadable decision files and no longer persists a partial seed when a source read fails.
- `/api/action` rejection codes (403 origin, 401 token) pinned by tests and documented.

## v0.8.4 - 2026-10-29

### Changed
- Codex workers in narrow-sandbox mode get write access to their own worktree git directory only (`--add-dir`), not the shared common git directory.

## v0.8.3 - 2026-10-29

### Fixed
- Test harness: a shard's temp root is created before its long path is resolved, so an 8.3 short `TEMP` (GitHub runners: `RUNNER~1`) no longer leaks into repository and log paths. v0.8.2 was tagged but not released because of this.

## v0.8.2 - 2026-10-29

### Added
- Dashboard UI merge (ui-shell, ui-fix, dash-base): `window.Trinity` API, drawer Review/Files tabs and action bar, wizard queue mode, notifications, per-repository base resolution, model propagation, queued badge, Resume byte counter.
- `TRINITY_AGY_PREFIX` prepends text (for example `/teamwork-preview`) to the Antigravity prompt.

### Fixed
- Dashboard Stop all also covers already-paused repositories with a live scheduler.
- Dashboard: an unsupported action throws instead of falling through to `merge -Yes`.
- Test harness: per-run temp roots, only run-owned processes are killed, retries for flaky cases.
- Test harness: `TRINITY_TEST_JOBS` overrides the default shard count (min(4, cores)); values outside 1..64 or unparsable fall back to the default instead of failing at parameter binding. Use 2 under low RAM.

## v0.8.1 - 2026-10-29

### Fixed
- Antigravity delegation: agy review and ask output uses the last assistant message instead of the joined interim text; a review with no findings list and no "No findings" line counts as incomplete and blocks the merge.
- Runner kills an Antigravity worker that is only waiting on its own background tasks (`TRINITY_AGY_IDLE_SECONDS`, default 900); the worker prompt tells it to run commands in the foreground.
- Runner watchdog test no longer carries a stray CR in a path.

## v0.8.0 - 2026-10-29

### Added
- Queue and scheduler commands, per-repository configuration, pause controls, autopilot and task history.
- Dashboard API and interface components for task actions, board, settings and history.

### Fixed
- Include scheduler, configuration, sample data and dashboard assets in releases and `trinity init`.
- Keep stalled workers in slot and scope accounting, and stop scheduler dispatch when configuration is unreadable.
- Reject failed or dirty task worktrees at the merge gate. Dry runs require the task branch to include the current base before testing.
- Isolate the temporary repository registry during release verification.

## v0.7.0 - 2026-10-28

### Added
- `trinity resume <task> -Feedback "<text>"` (or `-FeedbackFile`, default: the saved merge review): re-runs a done or failed task with the same agent in its existing worktree and branch; earlier output kept as `*.round<N>.*`, round on the board.
- Runner watchdog: `-DeadlineMinutes` (default 120, env `TRINITY_DEADLINE_MINUTES`) kills a hung worker and marks it `failed (timed out)`; a worker with no log or worktree change shows `running (stalled: no output N min)`; runner liveness checks the exact process, not a reused pid.
- Base branch: `-Base`, else env `TRINITY_BASE`, else `origin/HEAD`, else `main`; used by dispatch, merge, review, wait, show, cancel. `trinity status` prints `base: <name> (<source>)`.
- Self-test runs in 4 parallel shards (`tests/run-parallel.ps1`, `run-tests.ps1 -Shard i/N`): about 3 minutes instead of 9.
- Worktree seeding: a committed `trinity-seed.txt` (`copy <path>`, `run <command>`) copies gitignored files such as `.env` into each new worker worktree and runs one setup command; output in `.codex-out\seed-<task>.log` (`scripts/lib/seed.ps1`).
- Self-test: the dashboard page served by the real server is checked with a real token; extra cases live in `tests/cases/*.ps1`.

### Changed
- `trinity merge` reviews again when the base moved during the review, and blocks on review output that is neither findings nor a clear "no findings" answer (empty, crash, usage limit) unless `-Force`. The review is also saved as `.codex-out\review-<task>.md`.

### Fixed
- `trinity dashboard -Stop` (and start) find an orphan dashboard by its port when the pid file is missing or stale, including HttpListener servers that show as pid 4; any other process on the port is reported and left running.
- Worktree seed `run` commands keep quoted program paths and arguments.

## v0.6.0 - 2026-10-28

### Added
- Any agent can orchestrate: Codex or Antigravity driving the main checkout plan, dispatch, `track`, review and merge like Claude (`docs/orchestrator.md`). Orchestrator is detected from the environment or set with `-Agent` / `TRINITY_ORCHESTRATOR`; `status` prints an `orchestrator:` line; reviews never pick the author or orchestrator when another reviewer can run.
- `trinity dispatch claude <task> -Headless`: Claude Code as a headless worker (`claude -p`) in its own worktree.
- `.agents/skills/trinity/SKILL.md`: orchestrator playbook loaded by Codex and Antigravity, installed by `trinity init`.

## v0.5.0 - 2026-10-28

### Added
- `trinity show <task> [-Json]`: read-only detail of one board task (state, branch, scope, commits ahead, diffstat, result summary, log tail, file paths).
- `trinity retry <task> [-Force]`: re-dispatch a failed or cancelled task with the same agent, scope and prompt; old log/result files are kept as `*.attempt<N>.*`.
- `trinity clean [-OlderThanDays 7] [-Yes]`: lists merged/cancelled board tasks older than N days; with `-Yes` moves their files to `.codex-out\archive\<task>\` and drops the board entry (never deletes branches or files).
- Dashboard GUI step 4: "Dispatch" button and modal (repo, agent with availability, task name, scope, prompt) with live validation, overlap warnings, CLI preview and a confirm step; new `GET /api/dispatch/check` and `dispatch` action.
- Dashboard GUI step 3: task detail tabs Summary, Diff, Log, Merge check (`#task=<repo>/<task>&tab=diff|log|merge`), live log tail, and a merge dry run with blockers (main dirty, conflicts, scope violations, runner alive) behind a "Review merge" button; new read-only endpoints `/api/task/diff`, `/api/task/log`, `/api/task/merge-check`.

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
