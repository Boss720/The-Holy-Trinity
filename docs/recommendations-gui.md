# Recommendations as GUI (2026-10-25)

Every item from `docs/recommendations.md`, converted to a GUI way to do it. Contract: `docs/reco/gui-foundation.md`. Wireframes: `docs/reco/gui-wireframes.md`.
Converted by the army: Antigravity (wireframes and page items), Sonnet x2 (Top 13 and quick wins; reliability, CLI, features), Haiku (server, tests, docs, machine). Merged, deduplicated and checked by Claude.

Principle: the CLI stays the source of truth. The GUI runs the same `trinity` commands through an allowlisted action API and always offers "Show command". Internal fixes (caches, locks, parsing) get no control of their own; they show up as a Health row or a chip.

Format: `item -> surface / control: what you see and click | backend | effort`.

## The GUI in one picture

- **Control panel** (the dashboard page, `http://localhost:7777/`), views: **Inbox** (default: needs attention + running), **Tasks** (cards or table, multi-select), **Repos**, **Schedule**, **Health**, **Housekeeping**, **Settings**, **Help**. Header: agent cards, data-age chip, slots chip (`3/4`), "New task" button, command palette.
- **Task drawer**: tabs Summary | Diff | Log | Chat | Review | Evidence. Action bar: Merge, Review, Resume, Retry, Fork, Cancel, Open folder, Open in editor, Copy branch.
- **Dispatch form**: agent (with availability), task name (validated live), scope picker (file tree, glob preview, overlap and conflict warning), prompt editor, role, model + effort, base branch chip, options (read-only, plan first, best of N, run after, fix-loop rounds, deadline, schedule instead), seed files chip. "Add another task" turns it into a batch table with Import/Export JSON.
- **Merge review screen**: diff, review findings as severity chips grouped by lens, blockers (runner alive, not done, main moved, scope violation, conflicts, failing tests, no evidence), Dry run, Merge / Resume with findings / Cancel.
- **Tray icon** (`scripts/tray.ps1`, WinForms NotifyIcon, no new dependency): colour = worst state; balloon on done/failed; menu: Open control panel, Needs attention (N), Merge ready tasks, Start/stop dashboard, Quit. Tooltip "(1 run, 1 fail) Trinity".
- **Toasts**: click opens the control panel at `#task=<repo>/<task>`.

## Build order

1. **Foundations, still read-only**: Top 1-2 fixes (in flight), data-age chip, CONNECTING state, Health view with read-only rows, deep links (`#task=`), Inbox view built from existing state.
2. **Action API** with token, Origin and loopback checks, jobs with output files under `.codex-out\jobs\`, per-task lock shared with the CLI, `actions.log`. First actions: cancel, merge, review-task, open-folder (the ones the CLI already has).
3. **Task drawer tabs** Diff and Log, Merge review screen with blockers and Dry run.
4. **Dispatch form** (single task), then roles and batch.
5. **New CLI commands, each with its button**: resume/retry, show/logs, clean/archive, doctor, sync, config. Each lands as a CLI command first, then a control.
6. **Tray icon**.
7. **Features**: fix loop, conflict radar, plan first, run after, best of N, schedule, hooks.

## Top 13

1. Dashboard responsiveness -> no GUI of its own: header data-age chip ("updated 2 s ago, collect 0.8 s", spinner while a poll is in flight) and Health row "Dashboard server" (last/avg collect, cache hits, pass/warn against 1 s, Restart server button) | state: `collectMs`, `serverStartedAt` | S+M
2. Reachable beyond localhost -> Health row "Listening on loopback only" (green after self-check), Restart server button; toast "Blocked a non-local request from <ip>" | state: `listenerScope`, `blockedRemoteCount`; action: `restart-dashboard` | S
3. Merge gate hardening -> Merge review screen: Merge disabled with reason chips ("runner still alive", "not done", "main moved, re-review"); findings as severity chips from JSON; red "Review output unparsed, merge blocked" with Re-run review; second merge shows "queued behind <task>" | state: `mergeBlockers[]`, `reviewParse`, `mainHeadAtReview`; actions: `merge`, `review-task` | M
4. Runner deadline and stall watchdog -> Dispatch form "Deadline" (default 45 min); card chips "running 12 of 45 min", "STALLED (no output 8 min)", "TIMED OUT"; stalled/timed-out go to Inbox with Resume / Retry / Cancel; "runner dead (pid reused)" instead of a false alive | state: `deadlineAt`, `lastLogGrowthAt`, `runnerAlive` | M
5. resume / retry -> Task drawer "Resume with feedback" (textarea, prefilled with review findings when blocked) and "Retry" (original prompt); Merge review "Resume with findings"; card "round 2 of 3" | new commands: `resume <task> -Feedback`, `retry <task>`; state: `sessionId`, `fixRound` | M
6. Scope and tamper guard -> Dispatch scope picker; drawer "Scope check" row with out-of-scope files as red chips, "main checkout modified" banner; task goes to Inbox, Merge disabled until "Accept out-of-scope files" (confirm) or Resume; Settings toggle Flag / Block | state: `scopeGlobs[]`, `scopeViolations[]`, `mainTampered` | S
7. See a task without merging -> drawer tabs Log (live tail, Follow, search), Diff (stat + per-file), Review (run review on the branch); Merge review "Dry run" | new commands: `logs`, `show`, `review <task>`, `merge -DryRun` | S
8. Codex sandbox writes the shared git dir -> Health row "Codex sandbox scope" (warn) with "Narrow sandbox" Fix; drawer Summary "Writable paths" per Codex task | state: `codexWritableDirs[]` | S
9. Needs attention strip -> Inbox view and the top strip on every view, all repos, ignores the filter; reason chips (failed, done-not-merged, stalled, scope violation, review-blocked) with inline Merge / Resume / Retry / Cancel / Dismiss; tray "Needs attention (N)"; note "N tasks hidden by filter" | state: `attention[]`, `hiddenByFilterCount` | M
10. Housekeeping -> Housekeeping view: artifacts and board sections per task with size and age, select, "Archive selected" (moves to `.codex-out\archive\`), "Prune merged board sections older than N days", "Self-test leftovers (42)" row; merge checkbox "Archive artifacts after merge" (on) | new command: `clean`; state: `artifacts[]`, `boardSections[]` | S
11. Base branch hard-coded `main` -> Settings "Base branch" (branch dropdown + "auto from origin/HEAD"); Dispatch "Base: develop" chip with override; Health row "Base branch resolved" with its source | state: `baseBranch`, `baseBranchSource`; action: `set-config` | S
12. Worktree seeding -> Settings "Worktree seeding": files to copy (pick from gitignored files) + setup command; Dispatch chip "Seed: .env + setup" with toggle; setup output first in the Log tab | state: `seedFiles[]`, `seedSetupCommand` | S
13. CI -> Health rows "CI workflow" (Create CI workflow Fix) and "Tests hermetic"; "Run tests now" streams the suite in a job toast | actions: `run-tests`, `create-ci` | S

## Quick wins

- Unknown command exits 0 -> header command palette listing every command with help; the GUI only sends allowlisted actions, so the fix shows as exit 1 in a job toast if the API is misused | S
- Prompt from stdin / `--` -> Dispatch prompt editor sends the prompt as a file, so `-Force` in prompt text is never a flag | S
- `status` login probes every call -> agent cards "checked 3 min ago" with refresh icon; TTL in Settings | action: `refresh-availability` | S
- Board truncate-then-write -> no GUI: board never flashes empty; Health row "Board readable" with "Clear stale lock" Fix | S
- `wait` prints raw result -> drawer shows control characters as visible escapes | S
- `wait` exit 3 for merged -> card "Merged" chip with time and commit count | S
- Split `merge -Force` / `-NoReview` -> Merge review: separate "Override findings" and "Skip review" checkboxes, each confirmed with the exact command; "Review skipped" chip | S
- Stale dashboard server -> header banner "Server outdated, restart to load the latest code" + Restart server; Health row with start time and script hash | state: `scriptHash`, `scriptHashOnDisk` | S
- LIVE before first poll -> grey CONNECTING chip and skeleton cards, LIVE after the first reply, OFFLINE with Retry after failures (in flight: `dash-poll`) | S
- Claude "unavailable" while sessions run -> Claude card: "Sessions: 2 active" (green) and "Headless review: not logged in" (amber, "How to log in") | state: `claudeHeadlessReview` | S
- Subagent FINISHED while still running -> "RUNNING (waiting on tool, 3 min)" until a final message | state: `subagentWaitingOnTool` | S
- Merged "0 commits", "runner idle" -> "Merged: 4 commits, <sha>", runner row hidden on terminal tasks | state: `mergedCommitCount`, `mergeSha` | S
- Copy cancel, live title -> real Cancel and Merge buttons next to "Copy command"; tab title and tray tooltip with counts | S
- Document `CLAUDE_EXE`, `merge -Force` -> Settings "Claude executable" with Browse and Test; help "?" on Override; Health row "Docs in sync" | S

## Reliability

- Half-written board reads -> no GUI: cards never blank mid-write; Health row "Board lock stale" with Fix | M
- Pid file race -> no GUI: no phantom running card; a real stale pid shows "runner dead" with Repair (mark failed, clear pid) | action: `repair-task` | S
- Dispatch fails after worktree exists -> form stays open with the error and "Rolled back worktree and board entry"; partial rollback appears in Housekeeping as an orphan with Remove | state: `orphans` | M
- Marked merged before cleanup -> amber "cleanup needed" chip with "Finish cleanup" (idempotent); Dispatch name check flags names blocked by a stale branch | state: `cleanupNeeded` | S
- Secret scan formats -> Settings "Secret patterns" table with Add and "Test against sample text"; Health row "Secret scan: N patterns, hook on" | S
- `init` partial install -> Repos view "Install toolkit into repo" (staged, job toast "Updated 24 files" or "Rolled back"); Health row "Toolkit install" with Repair | action: `init-repo` (confirm) | S
- `wait` re-parses the board -> no GUI (the page does not use `wait`) | S
- Untested paths -> Health "Self-test" row with Run button, counts and failing names; behaviours surface as "merge aborted, main unchanged" on the Merge review screen and "runner dead" on cards | M

## CLI quality of life

- Multi-task wait / `merge -AllDone` -> Tasks view checkboxes, "Select all done", bulk bar "Merge selected" (board order, stops at first failure, one toast with per-task rows) and "Wait for selected"; tray "Merge ready tasks" | S
- `doctor` -> Health view: pass/warn/fail rows (hooks, `.codex-out/` ignored, `Test:` still TBD, orphans, free disk, versions), Run checks, Fix per safe row; red rows badge the Health tab and add an Inbox item | new command: `doctor -Json` | M
- `sync <task>` -> Merge review on conflict: conflicting files, "Sync with main", Open folder / Open in editor | M
- Config file, `-Model/-Effort` -> Settings view with User / Repo toggle, diff preview before Save; Dispatch model/effort default from it | new command: `config get/set` | M
- Manifest dispatch -> Dispatch form batch rows, Import/Export JSON, "Dispatch all", "Retry failed rows" | M
- Templates and roles -> Settings "Roles" editor; Dispatch "Role" dropdown pre-fills agent, model, prompt; drawer box "Merge will check: Test, Shared files" | M
- `status` as table, `-All`, `-Json` -> Tasks view table toggle (sortable, coloured state), "Show merged", "Copy JSON" | S
- Heartbeats and footer -> live timer and last log line on cards, "Merging... reviewer codex, 2 min" in the job toast, model / duration / tokens footer (Codex tokens parsed) | S
- Read-only async jobs -> Dispatch option "Read-only (no branch)"; card "read-only" chip, no Merge, result rendered with Copy and Save | S
- Concurrency cap -> Settings "Max parallel"; header "3/4 slots"; queued cards "queued #2" with "Start now"; Dispatch note "will queue" | M

## Features

- Bounded fix loop -> Dispatch "Fix loop: up to N rounds"; drawer round history (tests, findings per round); card "fixing"; after N rounds an Inbox item | M
- Conflict radar -> "Conflicts" strip and red chips on affected cards ("conflicts with api-tests: src/x.ps1"); same warning in the scope picker | S
- Best of N -> Dispatch agent checkboxes; one stacked card "task (3 variants)" with results per variant; "Pick this one" merges it and cancels the rest after confirm | M
- Task dependencies -> Dispatch "Run after" picker (after done / after merged); card "waiting for <parent>"; parent drawer lists dependents | M
- Plan first -> Dispatch option; plan-ready task in Inbox; drawer renders `plan.md` with Approve and run / Edit plan / Reject | M
- Quota-aware reroute -> amber "rerouted: codex -> antigravity (rate limit)" chip, toast; Settings "Auto-reroute" toggle | S
- Per-task port and run command -> drawer "Port 4217" chip with Open, run command field with Start/Stop; Settings "Port range" | S
- Evidence folder -> drawer Evidence tab (thumbnails, Open folder); card count; Merge review warns "UI task has no evidence" (tick to merge anyway) | S
- Lifecycle hooks -> Settings "Hooks": command, enabled, "Test fire"; ntfy/Discord preset; last hook result on Merge review | M
- Review ensemble -> Merge review findings grouped by lens with "confirmed by <vendor>"; Settings lens checkboxes and "Require second vendor for P0/P1" | M
- Diff pane with feedback -> drawer Diff tab (read-only first), then "Send feedback" that runs resume | L
- Claude lane fed by hooks -> no GUI: accurate Claude cards; Health row "Claude hooks installed" with Fix | M
- Fork -> drawer "Fork" (new name, extra prompt, agent); card "forked from <parent>" | M
- Scheduled tasks -> Schedule view: table (name, repo, agent, when, next run, last result) with New, Pause, Run now, Remove; Dispatch "Schedule instead of run now"; backed by `schtasks` entries `trinity-<name>` | S

## Dashboard page and alternative layouts

Antigravity's layout (`docs/reco/gui-wireframes.md`): views Inbox (default) | Tasks (toggle By agent = today's lanes, By state = kanban, Timeline) | Repos | Health | Housekeeping | Settings, a persistent top bar (live/paused, Pause and Refresh, agent pills, `/` search, "+ New task"), and wireframes for every screen including 375 px.

- Polling resets focus and scroll -> no GUI: keyed updates; focus, selection and scroll survive polls | M
- Drawer focus trap, nested button roles, focusable availability pill -> accessibility fixes, no new control | S
- Search and state filter -> top bar search (`/`) plus pills Running / Attention / Done / Merged | S
- URL hash state -> `#inbox`, `#tasks`, `#task=<repo>/<task>`, `#chat=<id>` | S
- Pause and manual refresh -> top bar Pause / Refresh, interval 3 s / 10 s / manual | S
- Long subagent lists -> 5 newest, "Show N more" | S
- Cumulative token totals -> segmented chip input / cached / output / reasoning, optional cost | S
- PLAN items cut mid-sentence -> Repos view: ellipsis with tooltip, "+19 more" | S
- Copy button wrapping on phones -> 32 px icon button under 600 px | S
- CSS bulk -> no GUI: shared tokens and classes | M
- Cancel, copy branch, fix-login buttons -> drawer action bar and availability popover (Fix login runs or copies the login command) | S
- Rate-limit bars -> amber at 80%, red at 95% | S
- Browser notifications, live title and favicon -> Settings toggle; "(1 run, 1 fail) Trinity" title and coloured favicon dot | S-M
- Files-touched count -> "N files" chip on the collapsed card | S
- Empty repo list -> guide box with copyable `trinity init <path>` and `trinity setup` | S
- Kanban (concept 1) -> Tasks view "By state" toggle; cards are not draggable (status comes from agents, never from dragging) | M
- Attention inbox + mini tray (concept 2) -> the default Inbox view | S
- Timeline (concept 3) -> Tasks view "Timeline" tab once runs carry reliable start/finish times | L

Changes Claude made to the wireframe proposals: dropped `Space` = pause (it scrolls the page) and single-key `x` = cancel (too easy to hit; Cancel stays a button with a confirm); dropped the "Checkout" button (the main checkout must stay on the base branch; "Copy branch" stays); dropped swipe-to-merge on phones (merge only from the Merge review screen); the tray's global hotkey must be checked against existing shortcuts before it ships.

## Dashboard server (internal; visible on the Health view)

All server fixes are internal. Each shows up as a Health row (numbers below are targets, not measurements):
- Snapshot cache + background refresh -> "Collector: under 1 s per poll", data-age chip stays green.
- Repo dedupe -> "Collects per poll: 3 for 3 repos" (in flight: `dash-perf`).
- Claude session cache -> "Claude sessions: 5 parsed, rest from cache" (in flight: `dash-perf`).
- Terminal-task cache -> "Tasks: 3 running, 22 cached".
- Cold path and negative-lookup cache -> "Last cold collect".
- Git cache and `--no-optional-locks` -> "Git checks: cached 10 s, 0 lock conflicts".
- Chat cache -> the Chat tab updates without pausing the board.
- Per-task try/catch -> repo card chip "1 task unreadable" instead of the whole page going OFFLINE.
- Accept-loop and offset fixes, child-process timeouts -> rows "Server: listening", "Transcript index", "Codex login: stale, last good 2 min ago".
- Abort logging -> "Server errors (24 h): N real faults".
- ETag / 304 and `/api/health` -> "Last poll: 304 unchanged".
- `repos.txt` pruning -> Health "Repo registry" row listing missing, duplicate and no-`main` repos with Prune (confirm, edits `repos.txt` only).

## Tests, docs, machine

- Self-test -> Health "Last self-test" (counts, total, per-case ms slowest first; needs `run-tests.ps1` to print per-case time) and "Run self-test" job.
- Hermetic tests, CI skip rule, new cases -> no GUI; same result with or without real logins, CI badge red on a skip.
- Self-test leftovers -> Health row "42 dirs in %TEMP%" with Archive (moves `trinity-selftest-*` only).
- Docs drift -> Health "Docs drift" row (file:line, claim, Open file); text fixes themselves have no GUI.
- Duplication and onboarding -> Help view: Getting started (PATH, `codex login`, `claude auth login`, where to get `agy`), command table with Copy, Antigravity permissions warning in a "?" popover on the agent picker and Health login rows.
- Disk and transcripts -> Health rows "C: free 2.6 GB (warn under 10 GB)", transcript dir sizes; Housekeeping "Archive old transcripts to D:" (age, count and size preview, confirm, move to `D:\trinity-archive\`, never delete).

## Action API (deduplicated)

Destructive ones need `confirm: true` after a dialog that shows the exact command.

| Action | Runs | Destructive |
|---|---|---|
| dispatch, dispatch-batch | `dispatch <agent> <task> -PromptFile <f> [-Scope -Model -Effort -Base -ReadOnly -Plan -After -FixLoop -BestOf -Role -Deadline]`, `dispatch -Manifest` | no |
| merge, merge-selected, merge-dry-run | `merge <task> -Yes [-Force] [-NoReview]`, `merge -AllDone`, `merge -DryRun` | yes (dry run no) |
| cancel, pick-variant | `cancel <task> [-Force]`, `pick <task>-b` | yes |
| review-task | `review <task>` | no |
| resume, retry, fork, approve | `resume <task> -Feedback <file>`, `retry`, `fork`, `approve` | no |
| logs, show, get-diff | `logs <task>`, `show <task> -Json` | no |
| sync-task | `sync <task>` | no |
| repair-task, cleanup-task, cleanup-orphan | `repair`, `cleanup <task>`, `cleanup -Orphans` | yes |
| clean, archive-artifacts, archive-transcripts, selftest-archive, repos-prune | `clean -Archive`, `archive-transcripts -OlderThan -To`, ... (all move, never delete) | yes |
| doctor, doctor-fix | `doctor -Json`, `doctor -Fix <row>` (allowlisted, reversible fixes) | no |
| set-config, roles-save, hook-test, test-exe | `config set`, `roles save`, `hook test`, `config test-exe` | no |
| run-tests, create-ci | `tests\run-tests.cmd`, `ci init` | no |
| schedule-save, schedule-run, schedule-remove | `schedule add/run/remove` (wraps `schtasks`) | remove: yes |
| task-run, task-stop, open-folder, open-editor | per-task run command, Explorer, editor | no |
| restart-dashboard, refresh-availability, tray-start, tray-stop | `dashboard -Stop` + start, `status -Refresh`, `tray` | no |

New state fields are listed per item above; the full list goes into `docs/dashboard.md` when each item is built.

## Risks and mitigations

- **Any web page could post to localhost:7777** (CSRF, DNS rebinding) and merge or cancel. Loopback-only, strict Host and Origin, per-server token in the served HTML sent back as `X-Trinity-Token`, allowlisted actions with array arguments, `actions.log`.
- **One misclick merges unreviewed code or discards work.** Confirm dialogs with the exact command and branch; Merge stays disabled while P0/P1, conflicts or failing tests exist (override is a visible, logged tick-box); no auto-merge anywhere; archive instead of delete.
- **GUI and CLI act on the same task at once.** Per-task lock file taken by every action and every CLI command; a second action returns "task busy (job id)"; atomic board replace; page re-reads state after each job.
- **The page becomes a long-running controller.** Job output in `.codex-out\jobs\` survives a restart; tray shows "server offline" with Restart; queue and schedules always visible with Pause; Health warns when the server restarted with jobs running.
