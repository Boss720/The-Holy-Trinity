# Recommendations backlog (2026-10-25)

Army audit of the toolkit at 933b9bf. Seven workers plus a live check:
Codex (reliability, races), Antigravity (dashboard page, alternative layouts),
3x Sonnet (CLI ergonomics, dashboard server, research on comparable tools),
2x Haiku (test coverage and timing, docs drift), Claude (live dashboard, dogfooding the dispatch flow).
Claude spot-checked the key claims against the code and the installed CLIs.
Raw worker reports: `docs/reco/codex-reliability.md`, `docs/reco/antigravity-ui.md`.

Tags: P1 = hurts daily use or safety, P2 = worth doing, P3 = nice to have. S/M/L = effort.
`file:line` refers to main at 933b9bf.

## Top 13, in order

1. **[P1] [S+M] Dashboard responsiveness.** One collect takes 4.1 s warm and 16.4 s cold (spec: under 1 s), on the server's only thread. The page polls every 3 s with no in-flight guard (`dashboard.html:3438`), so requests queue forever: live, 11 polls stacked in 33 s, `/api/state` took 34-75 s, the server sat near 100% CPU, and every abandoned poll was still fully computed (38 "network name is no longer available" errors, `dashboard.ps1:860`). Fix, cheapest first: skip a poll while one is pending; dedupe repos before collecting (the own repo is collected twice); cache Claude session summaries by mtime (60% of the time); then a cached snapshot refreshed single-flight in a background runspace (see "Dashboard server"). [DONE: dash-fix (dash-poll b1d4749, dash-perf b564f19, dash-snap 6165c94)]
2. **[P1] [S] Dashboard is reachable beyond localhost.** The listener prefix `http://localhost:7777/` (`dashboard.ps1:829`) makes http.sys listen on `0.0.0.0` and `[::]` and match on the Host header only; a request to the LAN address with a forged `Host: localhost:7777` reached the app. If the Windows firewall allows inbound 7777, anyone on the network can read agent chats, which may contain code and secrets. Fix: return 403 unless `RemoteEndPoint` is loopback; the `127.0.0.1:$Port` Host entry is dead code (http.sys rejects it), add a `127.0.0.1` prefix or drop it. [DONE: dash-fix (dash-perf 9693931, gui-s1-server a28fb54)]
3. **[P1] [M] Merge gate hardening.** `merge` never checks that the task finished or that its runner is dead (`trinity.ps1:611-623`), so it can merge a branch the worker is still writing. Findings parsing only recognizes `- [P0]` lines (`trinity.ps1:62`); a P1 under a heading or in bold passes. Fix: require a terminal board status, fail closed on unparsed review output, and ask reviewers for JSON (`codex exec --output-schema` and `agy --json-schema` both exist on this machine). Serialize merges and recheck main HEAD right before `git merge`. [DONE: cli-wire merge guards 4444c50, cli-mergebase beff690]
4. **[P1] [M] Runner deadline and stall watchdog.** The runner waits on the agent CLI with no timeout (`trinity.ps1:495-502`); `wait -Timeout` only stops the waiter. Pid liveness alone marks a runner alive (`trinity.ps1:285`), so after a reboot a reused pid looks alive and `cancel` could kill an unrelated process. Fix: per-task deadline (agy has `--print-timeout`), kill the process tree on expiry, mark `stalled` when the log stops growing, store pid + process start time. [DONE: runner-watchdog 42a2a6d/5926096]
5. **[P1] [M] `trinity resume <task> "<feedback>"` and `retry <task>`.** A failed or blocked task today means `cancel -Force` and retyping the prompt; merge says "fix on the branch" with no command for it. Session ids are already saved in `meta-<task>.json`; `codex exec resume <id>` and `agy --conversation <id>` exist here. This unlocks a bounded fix loop: tests or review fail, resume the worker with the findings, max N rounds. [DONE: trinity resume in cli-resume 649f7eb, retry in cli-s5a 788af5b]
6. **[P1] [S] Scope and tamper guard.** `-Scope` is prose in the task file only (`trinity.ps1:333,342`). Antigravity runs with permissions skipped. After each run, compare `git diff --name-only main...branch` with the scope globs and check the main checkout is unchanged; flag or block on violations. [DONE: scope guard in cli-wire 4444c50]
7. **[P1] [S] See a task without merging it.** No `logs`, `show` or per-task `review`: users tail `.codex-out\log-<task>.txt` by hand (the codex-worker agent is told to), and `trinity review` cannot target a task branch from main. Add `trinity logs <task> [-Follow]`, `trinity show <task>` (commits, stat, diff vs base) and `trinity review <task>` / `merge -DryRun`. [DONE: merge -DryRun in cli-wire 4444c50, show in cli-s5a 788af5b]
8. **[P1] [S] Codex sandbox can write the shared git dir.** `--add-dir "$paths.Common"` (`trinity.ps1:499`) gives the Codex worker write access to the common `.git`, which holds the board and every branch ref. Check why it was added (git index writes?) and narrow it to the worktree's own `.git/worktrees/<name>` dir, or drop it. [OPEN: being worked as sandbox-narrow]
9. **[P2] [M] "Needs attention" strip on the dashboard.** One row block at the top, across all repos and ignoring the repo filter: failed runs, done-but-unmerged branches, stalled runs. Live: the saved repo filter (`gemini-live-agent`) hid the two running Holy trinity tasks while the header said "1 run". [DONE: attention strip in gui-s1-server c429105, gui-s1-page f04cc78]
10. **[P2] [S] Housekeeping: `trinity clean` and board pruning.** `.codex-out` holds 156 files (7.5 MB) from 17 tasks; merged sections never leave the board, so `status` prints about 120 lines and the dashboard still lists MetaStrip-era tasks under Holy trinity. Move merged/cancelled artifacts to `.codex-out\archive\` (not delete), prune old board sections, and let `merge` archive its own task. The self-test leaks too: 42 `trinity-selftest-*` dirs in `%TEMP%`. [DONE: clean command in scripts/trinity.ps1, cli-s5a 788af5b]
11. **[P2] [S] Base branch is hard-coded `main`.** `-Base` is used only when the worktree is created (`trinity.ps1:322`); wait, cancel, merge and review use `main` literally (`:308,310,557,584,619-629,652`). Repos set up with `trinity init` on `master`/`develop` break. Resolve once: `-Base`, then repo config, then `origin/HEAD`. [DONE: Get-BaseBranch in cli-mergebase beff690]
12. **[P2] [S] Worktree seeding.** New worktrees lack gitignored files (`.env`, local config), the usual reason a worker cannot run tests. Add `.trinityinclude` (files to copy) plus an optional setup command run before the agent starts, logged to the task log. [DONE: worktree-seed 0205a66/4689f9a]
13. **[P2] [S] CI.** No `.github/workflows`. The suite (31 cases, 3m48s) runs with fakes and should work on `windows-latest`, after making the dashboard cases hermetic (they read the real `~/.codex`, `~/.gemini`, `~/.claude`: `run-tests.ps1:612,629,643,662`) and making skips fail in CI. [DONE: .github/workflows/ci.yml in release-pack 1dcff53]

## Quick wins (S, under an hour each)

- `trinity bogus` prints help and exits 0 (`trinity.ps1:874`). Exit 1 with "unknown command"; add `help <command>`.
- Dispatch prompt from stdin (`-PromptFile -` or a pipe) and a `--` terminator; prompt words like `-Force` or `-Scope` are bound as parameters today (`trinity.ps1:3-16`).
- `status` runs both agent login CLIs every call (about 1.5 s, at every Claude session start, `board.ps1:225-247`). Cache availability for a few minutes under `~\.trinity`.
- Board writes truncate then rewrite (`board.ps1:73-80`) and reads take no lock. Write to a temp file and replace it atomically.
- `wait` prints the worker's result file raw (`trinity.ps1:303`). Strip control characters before printing.
- `wait` returns 3 for a merged task (`trinity.ps1:314-315`); document it or return 0, and pin it in a test.
- Separate `merge -Force` (override findings) from a new `-NoReview`; today skipping review needs `TRINITY_REVIEWER=none`.
- Stale dashboard server: the running server started 17:20, `dashboard.ps1` changed 17:29, and `trinity dashboard` reuses it. Put the script hash in `/api/state`; restart on mismatch, or show a "server outdated" banner.
- Dashboard: show "LIVE" only after the first successful poll, and a loading state instead of "0 run / No tasks" while connecting (that empty state showed for 20+ s on every load).
- Dashboard: the Claude card says "Unavailable: not logged in" in red while the same lane shows active Claude sessions. It means the headless reviewer; say "headless review: not logged in" in amber.
- Dashboard: subagents waiting on a long tool call show FINISHED (the test-map agent showed "FINISHED 3m ago" while it still had 3 minutes to run). Mark finished only on a final message.
- Dashboard: merged tasks show "0 commits" and "runner idle" (the branch is gone). Show the merged commit count; hide runner state on terminal tasks.
- Dashboard: "Copy cancel" next to "Copy merge"; title with live counts, e.g. "(1 run, 1 fail) Trinity".
- Document `CLAUDE_EXE` and `merge -Force`; fix the docs drift list below.

## Reliability and safety (Codex audit + test gaps)

- [P1] [M] Readers see a half-written board: `Get-BoardEntry` reads without the lock while `WriteAllText` rewrites (`board.ps1:73`). Atomic replace fixes both sides.
- [P2] [S] A fast runner can delete its pid file before dispatch writes it (`trinity.ps1:359`), leaving a stale pid. The runner should write its own pid record first thing.
- [P2] [M] A dispatch that fails after the worktree exists (task file write, runner launch) leaves an orphaned worktree and board entry (`trinity.ps1:351`). Roll back what that call created.
- [P2] [S] The board is marked merged before worktree removal (`trinity.ps1:697`); a cleanup error leaves a stale branch that blocks reusing the task name. Record `cleanup-needed` and make cleanup idempotent.
- [P2] [S] Pre-commit secret scan knows a small set of token formats (`.githooks/pre-commit:40`). Broaden or make patterns configurable; document the limits.
- [P2] [S] `init` copies files one by one into the target (`trinity.ps1:733`); an interruption leaves a mixed install. Stage, then swap.
- [P3] [S] `wait` re-parses the whole board every 5 s (`trinity.ps1:276`).
- Untested paths that guard real failures: merge conflict abort (main unchanged, no `MERGE_HEAD`), deferred shared-file findings, killed runner (should fail fast, not wait out `-Timeout`), concurrent board writes, Antigravity-to-Codex reroute, `merge` without `-Yes`, `run`, `dispatch claude`, `ask` from stdin, pre-commit encoding rules, `trinity.sh dispatch/merge` with spaces.

## CLI quality of life and new commands

- [P1] [S] Multi-task `wait t1 t2` / `wait -All`, and `merge -AllDone` (merge done tasks in board order, stop at the first failure). Parallel work today means N blocking calls.
- [P2] [M] `trinity doctor`: hooksPath set, `.codex-out/` ignored, AGENTS.md `Test:` still TBD (merge then skips tests silently), orphan worktrees and pid files, free disk on C: and D:, agent and PowerShell versions.
- [P2] [M] `trinity sync <task>`: merge main into the task worktree and report conflicts; offer it when `merge` hits a conflict (today it says "rebase and retry" and leaves the user to find the worktree).
- [P2] [M] Config file (`.trinity.json` per repo, `~\.trinity\config.json` per user) for base branch, default scope, reviewer, disabled agents, exe paths, model and effort; `dispatch -Model/-Effort` passed through to the CLI. Every knob is an env var today, and cmd env vars are session-local.
- [P2] [M] Batch dispatch from a manifest (`dispatch -Manifest tasks.json`: agent, task, scope, prompt file per row), one summary at the end.
- [P2] [M] Task templates and roles: `.trinity/roles/*.md` (`-Role tests|ui|refactor|reviewer`) mapping to prompt, agent, model, sandbox. Auto-inject the repo's `Test:` and `Shared files:` lines into every task file (merge reads them, workers never see them).
- [P2] [M] `status` as a table (task, agent, state, age, +commits) coloured by state, `-All` for merged tasks, `-Json` for scripts and subagents.
- [P3] [S] Heartbeats with elapsed time and the last log line in `wait` and `merge` (merge is silent for minutes during review); model / duration / tokens footer from `meta-<task>.json` (Codex tokens are never parsed today).
- [P2] [S] Read-only async jobs (found while dogfooding this audit): an audit task had to create a worktree, branch and commit, then be read with `git show` and cancelled with `-Force`. Add `dispatch -ReadOnly` (Codex `--sandbox read-only`, agy `--mode plan`) that only writes `result-<task>.md`, no branch.
- [P2] [S] Concurrency cap (`TRINITY_MAX_PARALLEL`, queued tasks start when a slot frees). This audit ran Codex's test suite, Haiku's test suite and the collector at once; the dashboard went to 75 s per poll. Codex also ran the full suite inside a read-only audit; task rules could say when tests are not wanted.

## New features (comparable tools, checked for Windows/PowerShell fit)

Seen in claude-squad, Conductor, vibe-kanban, ccmanager, uzi, workmux, worktrunk, Orca, Agent Orchestrator, Sculptor, Jules, Cursor background agents, Claude Code agent teams/worktrees.

- [High] [M] Bounded fix loop after each run: run Test in the worktree, review, resume the worker with failures, up to N rounds; mark done only when green (Orca, Agent Orchestrator, Claude `TaskCompleted` hook). Needs `resume`.
- [Med] [S] Pre-merge conflict radar: pairwise `git merge-tree --write-tree` across running/done branches plus scope-glob overlap, shown in `status` and the dashboard (git 2.38+).
- [Med] [M] Best-of-N: same prompt to codex + antigravity (+ claude) in separate worktrees, tests and reviewer rank, `trinity pick <task>-b` cancels the rest (uzi, workmux, Codex cloud attempts). Fits `/army`.
- [Med] [M] Task dependencies: `dispatch -After <task>` queues until the parent is done or merged, then branches from it.
- [Med] [M] Plan-first mode: `-Plan` runs read-only to write `plan.md`, board shows `plan-ready`, `trinity approve <task>` resumes with write access (Jules, Aider architect, agent-teams plan approval).
- [Med] [S] Quota-aware reroute mid-task: when a worker dies on a rate limit, re-dispatch to the next vendor and note `rerouted:` on the board (today's reroute only happens at dispatch time).
- [Med] [S] Per-task port (`TRINITY_PORT`, hashed from the task name) and optional run command, so parallel UI workers and agy's browser never collide (uzi, worktrunk, Conductor).
- [Med] [S] Evidence folder per task (`.codex-out\<task>\evidence\` screenshots, test output), linked on the card; `merge` warns when a UI task has none. Enforces "done = exercised".
- [Med] [M] Lifecycle hooks in the repo config (`pre_merge`, `post_merge`, `on_status`); `on_status` can hit ntfy/Discord when away from the PC.
- [Med] [M] Review ensemble at the gate: correctness, security and test-coverage lenses in parallel; a P0/P1 is confirmed by a second vendor before it blocks.
- [High] [L] Dashboard diff pane per task, later with a feedback box delivered via `resume` (vibe-kanban, Conductor, Crystal). Read-only diff first (M).
- [Low] [M] Claude lane fed by hooks (`Stop`, `SubagentStop`, `Notification` calling `trinity track`) instead of transcript parsing; would also fix the false FINISHED.
- [Low] [M] `trinity fork <task>` from a worker's session (Codex `exec fork`, Claude `--fork-session`).
- [Low] [S] Scheduled tasks via `schtasks` calling `trinity dispatch` (dependency bumps, flaky-test triage).

Patterns to avoid (from the same tools): tmux as the session layer (breaks on Windows Terminal, WSL path pain); auto-approve as the default without a scope guard; heavy agent-to-agent messaging (cost grows per teammate, status lags); hand-dragged board status (vibe-kanban shut down in April 2026, Crystal is deprecated; derive status from activity, as trinity already does).

## Dashboard page (`scripts/dashboard.html`)

Current issues:
- [P1] [M] Every poll empties each lane and rebuilds it (`dashboard.html:3033-3035`): focus, text selection and scroll inside result/log blocks reset every 3 s (`:2715,2729`). Keyed updates, or at least skip re-render when the state hash is unchanged.
- [P1] [S] Chat drawer has no focus trap and does not return focus to its trigger (`:3145,3161`).
- [P1] [S] Task cards are `role="button"` with nested buttons inside (`:2314-2316,2342,2517`); use a plain container plus an expand button.
- [P2] [S] No text search or state filter (`:1876-1892`); add search (`/` hotkey) and state pills (running, failed, done, merged).
- [P2] [S] No URL hash state (`:2005-2012`); repo, expanded card and open chat should survive reload and be linkable.
- [P2] [S] No pause or manual refresh; fixed 3 s interval (`:3438`).
- [P2] [S] Availability detail lives only in a `title` on a non-focusable dot (`:1805,2241-2244`).
- [P2] [S] Long lists: 16 finished subagents from a day ago listed in full; the page was 4787 px tall at 800 px wide. Collapse finished items older than a few hours behind "show N more".
- [P2] [S] Token totals are cumulative prompt tokens including cache (a 15-step Codex run showed 896.5k tok, an older one 11.0M). Show input / cached / output, or an estimated cost.
- [P3] [S] PLAN items in the repo card are cut mid-sentence with no ellipsis, and a 24-item open list dominates the bottom of the page; show the first 5 and a count.
- [P3] [S] Copy button wraps titles at <= 600 px (`:810-824,1364-1368`); manual theme toggle (`:98-177`); empty-repo state should show `trinity init` / `setup` with copy buttons (`:3109-3110`).
- [P3] [M] 1760 of 3443 lines are CSS (`:9-1778`); consolidate card styles and tokens.

Missing: copy-cancel and copy-checkout buttons; copyable fix commands in availability banners; rate-limit bars amber at 80%, red at 95% (`:2661-2665`); files-touched count on the collapsed card; opt-in browser notification on running to done/failed; favicon dot with state colour.

## Alternative UI concepts

Antigravity drew three layouts from fields the contract already has (ASCII wireframes in `docs/reco/antigravity-ui.md`):

1. **Status kanban**: columns Running / Attention needed / Completed instead of one lane per agent. Agent becomes a chip. Serves the orchestrator driving a pipeline. M.
2. **Attention inbox + mini tray**: one header line of agent health, then a dense table: attention queue (failed, mergeable) with action buttons, active runs with elapsed time, last tool and tokens, history collapsed. Fits a narrow side tile next to the editor. S.
3. **Timeline (Gantt) swimlanes**: one row per agent, bars per run over the last hours, red failed, green merged, striped active. Shows idle agents and overlap. L.

Recommendation: build 2 as the default view (small effort, solves the "what needs me now" problem and the page height), keep today's lanes as a "by agent" toggle, and add 3 later as a tab once runs carry reliable start/finish times.

## Dashboard server (`scripts/dashboard.ps1`)

Measured (3 repos, 25 tasks): one collect takes 16.4 s cold and 4.1 s warm (spec target: under 1 s). About 60% of the warm time goes to re-summarizing 76 Claude session/subagent files every poll. The running server used 9.2 s of CPU per 10 s of wall time; `/api/state` took 34-72 s and `/` 84 s while one tab polled. Transcripts on disk: 761 Claude, 448 Codex, 19 Antigravity, 1.2 GB; a cold read of the 58.7 MB rollout added 449 MB of heap. Working set stayed at 114-127 MB over 3.4 h (no leak).

Performance:
- [P1] [M] Every `/api/state` rebuilds everything on the only thread (`dashboard.ps1:838,855`), abandoned requests included. Serve a cached snapshot refreshed single-flight by a background runspace; all queued requests get the same bytes.
- [P1] [S] The toolkit's own repo is collected twice: `Get-RepoState` runs before the dedupe check (`dashboard.ps1:757-768`), so 3 repos cost 4 collects. Resolve the toplevel with `rev-parse` and dedupe first.
- [P1] [M] Claude sessions re-parsed every poll (`dashboard.ps1:335-377,387-393`): 76 summaries, only 5 sessions kept. Pick the 5 newest by mtime first, cache summaries by path + length + mtime.
- [P2] [M] Finished tasks are recomputed every poll (pid check, 64 KB result read, log tail, meta parse, transcript summary, about 25 ms each, `dashboard.ps1:526-650`). Cache terminal tasks by status + file mtimes; recompute only running ones. Pruning the board (Top 10) helps too.
- [P2] [M] Cold path: whole-file read, then string, then split, then a record list (`dashboard.ps1:43-72`); `Get-JsonValue` enumerates `.Keys` (`:28`); the Codex subagent scan reads 64 KB of every rollout in 3 day folders (1,668 reads, 5.6 s cold) and does not cache misses (`:121`, up to 365 `Get-ChildItem` per poll). Read tails or chunks, use `ContainsKey`, cache `parent_thread_id` per path and negative lookups with a TTL.
- [P2] [S] Three git spawns per repo per poll (`dashboard.ps1:545,656,668`); plain `git status` can write the index and collide with a worker's commit. Use `git --no-optional-locks status` and cache git results for about 10 s.
- [P2] [M] The chat drawer re-parses up to 4 MB every 3 s (`dashboard.ps1:417-474`) and blocks `/api/state` meanwhile. Cache per file by length + mtime; accept `since` or an ETag.

Robustness:
- [P1] [S] One bad task takes the whole page OFFLINE: `(Get-Content pid -Raw).Trim()` throws on an empty or locked pid file (`dashboard.ps1:562`, confirmed), and nothing wraps a task or repo in try/catch. Catch per task and per repo, return partial data plus an `errors` list.
- [P2] [S] Any `HttpListenerException` from `GetContext` ends the accept loop silently and leaves the pid file (`dashboard.ps1:840-841`); setting `StatusCode = 500` after headers are sent can throw (`:889-892`). Break only when the listener stopped; guard the catch body.
- [P2] [S] The transcript offset advances before the summary is saved (`dashboard.ps1:49-67,255,325`): a throw loses records, a shrunk file doubles counts. Commit offset and summary together; reset both on shrink.
- [P2] [S] `codex login status` / `claude auth status` and git run inline with no timeout (`dashboard.ps1:479,736`, `board.ps1:215`); one hang freezes the server. Run them in the background with a 5 s kill; keep the last good value.
- [P3] [S] Client aborts are logged as errors (all 38 log entries); skip them, log duration and stack for real faults, return a JSON error body.

Architecture:
- [P2] [L] Poll-only design: each tab pulls 83 KB every 3 s with no ETag/304, gzip or health route; `logTail` and `result` are 34% of the payload and rarely change. Add a revision number with `If-None-Match` (304) or long-poll `?rev=`, a runspace pool, and `/api/health`.
- [P3] [S] `repos.txt` is never pruned or normalized (`board.ps1:148-154`); `ahead-behind:main` breaks repos without `main` (`dashboard.ps1:545`). Same base-branch fix as Top 11.

## Tests and CI

- Suite: 31 passed, 0 failed, 0 skipped, 3m48s. No per-case timing; print duration per case to find the slow ones.
- Hermetic: point `CODEX_HOME`, `TRINITY_AGY_HOME`, `CLAUDE_CONFIG_DIR` at fixture dirs in `Run-Case` (`run-tests.ps1:142`).
- Cleanup: every run leaves `trinity-selftest-*` and a `trinity-selftest-home-*` in `%TEMP%` (42 now; C: has 2.6 GB free).
- Skips exit 0; make them fail when `CI=true`.
- Add the cases listed under "Reliability and safety"; merge-conflict abort and killed-runner first.

## Docs

Drift:
- `AGENTS.md:41` says Antigravity agents run `trinity done`; headless Antigravity tasks are refused there (`trinity.ps1:464`).
- `.claude/agents/codex-worker.md:20` and `antigravity-worker.md:18,22` call `powershell ... trinity.ps1` from Bash, against the `./trinity.sh` rule.
- `codex-worker.md:28` reads `log-<task>.txt`; after a reroute the log is `agy-<task>.log`.
- `README.md:186` says "merge agent/codex/login-form"; `merge` takes the task name.
- `AGENTS.md:40` omits `wait` exit 3 and calls exit 2 "still running" (help says timeout); `AGENTS.md:20` names `agent-task.ps1` as the board manager (it is `lib/board.ps1`); `AGENTS.md:27` hard-codes `Holy trinity.worktrees` though `init` copies the file into other repos.
- `HANDOFF.md:12` says the junk files are still tracked (removed); `HANDOFF.md:9` mentions one user PLAN box, there are two.

Duplication (loaded every session, costs tokens): no-ChatGPT fallback in 4 files (~9 lines), routing table in 3 (~12), `./trinity.sh` rule and merge-then-wire loop in 3 (~8), worker agent steps duplicated across both worker defs (~20 lines per spawn). Keep one copy in AGENTS.md and point to it.

Onboarding: no step puts `trinity` on PATH, so `trinity init D:\...` from another folder fails; login steps (`codex login`, `claude auth login`) and where to get `agy` are missing; README never warns that Antigravity runs with permissions skipped; README has no command table (cancel, run, wait, done, track, ask, review appear only in AGENTS.md); the release section points to steps no doc defines.

## Machine

- C: has 2.6 GB free. `~\.codex\sessions` is 843 MB and `~\.claude\projects` 568 MB, both on C:, and the collector scans them. `doctor` should warn; an opt-in archive of transcripts older than N days to D: would free space and speed up collection.
