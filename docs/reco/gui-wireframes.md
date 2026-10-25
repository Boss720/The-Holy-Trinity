# GUI Wireframes & Control Panel Architecture

Information architecture, wireframes, and interaction specifications for converting the Trinity Operator Dashboard into an actionable Control Panel.

> Raw Antigravity proposal. Where it differs, `docs/recommendations-gui.md` wins: no `Space`/`x` shortcuts, no Checkout button, no swipe-to-merge, no draggable kanban cards, tray hotkey checked for collisions first.

## 1. Navigation

### Top-Level Views
- `[1] Inbox` (Default view): Cross-repo attention queue (failed, done-unmerged, stalled runs) followed by currently active tasks and sessions. Why default: Solves immediate operator triage ("what needs my intervention right now?") without scanning through multi-column agent lanes or missing tasks filtered out by repository selectors.
- `[2] Tasks`: Full task inventory. Provides two layout toggles:
  - `By Agent`: The 3 legacy lanes (Claude, Codex, Antigravity) with Claude interactive sessions at top.
  - `By State` (Kanban): Columns for Running, Attention Needed, Completed.
- `[3] Repos`: Repository list with branch status, uncommitted/ahead counts, PLAN progress checklist, and HANDOFF status bullets.
- `[4] Health`: System and environment doctor checklist (git hooks, ignored folders, CLI logins, disk budgets, orphan worktrees) with one-click safe fix actions.
- `[5] Housekeeping`: Artifact size and age auditing, board section pruning, orphan worktree cleanup, and temp folder purging.
- `[6] Settings`: Configuration editor for user (`~/.trinity/config.json`) and repository (`.trinity.json`) options (base branch, reviewer hierarchy, agent enable/disable, poll interval, theme).

Persistent Top Bar:
- Brand title, Live/Offline indicator with poll pause/refresh controls, agent availability summary pills, global search (`/`), and primary `[+ New Task]` button.

---

## 2 & 3. Wireframes & Interaction Specifications

### (a) Default View with Attention Inbox
```
+------------------------------------------------------------------------------------------+
| TRINITY CONTROL PANEL   [1:Inbox*] [2:Tasks] [3:Repos] [4:Health] [5:Clean] [6:Cfg]  [+New]|
| LIVE (3s) [Pause] [Refresh]  Claude: OK (1) | Codex: OFF | Antigravity: OK (1)   [Theme] |
+------------------------------------------------------------------------------------------+
| ATTENTION INBOX (2 items require action across 2 repos)             [Clear] [Filter: All]|
| [FAIL] Holy trinity / test-collector   Codex | exit 1 | 8m ago  [Inspect] [Retry] [Cancel]|
| [DONE] Holy trinity / gui-wire         AGY   | +2 com | 2m ago  [Merge Review] [Open Chat]|
+------------------------------------------------------------------------------------------+
| ACTIVE RUNS (2)                                   Repo: [All Repos v]  Search: [/      ] |
| > RUN  Holy trinity / strip-icc       Codex | 09:48 | 320k tok | cl.exe /O2     [Drawer] |
| > RUN  gemini-live   / audio-stream   AGY   | 04:12 |  28k tok | write_file     [Drawer] |
| > LIVE Holy trinity / Session: Wire   Claude| 12:40 | 143k tok | Opus (active)  [Drawer] |
+------------------------------------------------------------------------------------------+
| COMPLETED & MERGED (Last 24h, 4 tasks)                               [Show 12 Archived v]|
| * MERG Holy trinity / server-perf     Codex | merged 10:15 | 4 commits | 827k   [Summary]|
| * DONE gemini-live   / refactor-cli    Claude| done 09:30   | 1 commit  |  12k   [Summary]|
+------------------------------------------------------------------------------------------+
```
- State fields used:
  - Existing: `availability.*`, `agents.*`, `repos[].name`, `repos[].tasks[]` (`task`, `agent`, `state`, `status`, `commits`, `durationSec`, `tokens`, `lastTool`), `repos[].claudeSessions[]` (`id`, `title`, `active`, `contextTokens`, `model`).
  - New: `tasks[].stalled` (boolean from runner watchdog), `tasks[].attentionReason` ("failed" | "done_unmerged" | "stalled").
- Action API calls: `action: "retry"` (`task`), `action: "cancel"` (`task`, `confirm: true`), `action: "open_chat"` (`id`), `open_merge_review` (modal).
- Keyboard shortcuts:
  - `1`..`6`: Switch top navigation views
  - `/`: Focus search input
  - `j` / `k`: Select next / previous task card
  - `Enter`: Open drawer for selected card
  - `m`: Open merge review for selected done task
  - (dropped: `x` to cancel; Cancel stays a button with a confirm)
  - (dropped: `Space` to pause; it scrolls the page. Use the Pause button)

### (b) Task Drawer with Tabs and Action Bar
```
+------------------------------------------------------------------------------------------+
| TASK: gui-wire  [agent/antigravity/gui-wire]  Repo: Holy trinity  State: DONE (+2) [X Esc]|
| Model: Gemini 3.8 Flash (High) | Duration: 05:12 | Tokens: 26.2k | Tools: 42             |
+------------------------------------------------------------------------------------------+
| [Summary]  [*Diff*]  [Log]  [Chat]  [Review]  [Evidence (1)]                             |
+------------------------------------------------------------------------------------------+
| diff --git a/docs/reco/gui-wireframes.md b/docs/reco/gui-wireframes.md                   |
| new file mode 100644                                                                     |
| index 0000000..8a4e321                                                                   |
| --- /dev/null                                                                            |
| +++ b/docs/reco/gui-wireframes.md                                                        |
| @@ -0,0 +1,280 @@                                                                        |
| +# GUI Wireframes & Control Panel Architecture                                           |
| +Scope: docs/reco/gui-wireframes.md only                                                 |
| +Files touched: docs/reco/gui-wireframes.md (1 file, within scope)                       |
+------------------------------------------------------------------------------------------+
| ACTION BAR:                                                                              |
| [Merge]  [Resume/Fix]  [Review]  [Retry]  [Cancel]  [Folder]  [Editor]  [Copy]  [CLI Cmd] |
+------------------------------------------------------------------------------------------+
```
- State fields used:
  - Existing: `tasks[].task`, `tasks[].branch`, `tasks[].state`, `tasks[].commits`, `tasks[].model`, `tasks[].effort`, `tasks[].durationSec`, `tasks[].tokens`, `tasks[].toolCalls`, `tasks[].result`, `tasks[].logTail`, `tasks[].filesTouched`, `tasks[].chat`, `tasks[].sessionId`.
  - New: `tasks[].diff` (`git diff base...branch`), `tasks[].evidence` (file list in `.codex-out/<task>/evidence/`), `tasks[].review` (review findings).
- Action API calls:
  - `action: "merge"` (`task`, `confirm: true`)
  - `action: "resume"` (`task`, `args: { feedback: string }`)
  - `action: "review"` (`task`)
  - `action: "retry"` (`task`)
  - `action: "cancel"` (`task`, `confirm: true`)
  - `action: "open_folder"`, `action: "open_editor"`
- Keyboard shortcuts:
  - `Esc`: Close drawer (focus restored to trigger element)
  - `Tab` / `Shift+Tab`: Navigate trapped within drawer
  - `Alt+1`..`Alt+6`: Switch tabs (Summary, Diff, Log, Chat, Review, Evidence)
  - `m`: Trigger merge
  - `r`: Trigger resume feedback dialog
  - `b`: Copy branch name to clipboard

### (c) Dispatch Form Modal
```
+------------------------------------------------------------------------------------------+
| DISPATCH NEW TASK                                                                [X Esc] |
+------------------------------------------------------------------------------------------+
| Target Repo: [Holy trinity (main)        v]   Agent: (*) AGY [Avail]  ( ) Codex  ( ) Cl  |
| Task Name:   [gui-wire                     ]   Role:  [UI / Frontend Wireframes        v]|
| Scope Globs: [docs/reco/gui-wireframes.md  ]   [+] Browse files... [Overlap check: OK]   |
| Model:       [Gemini 3.8 Flash (High)    v]   Effort: [Default v]   Max Rounds: [3 v]    |
| Execution:   [ ] Plan-first  [ ] Read-only  [ ] Best-of-N  Dependency: [None / Immed. v] |
+------------------------------------------------------------------------------------------+
| Prompt:                                                                                  |
| +--------------------------------------------------------------------------------------+ |
| | Design task, docs only. Write ONE new file: docs/reco/gui-wireframes.md.             | |
| | Produce information architecture, 9 ASCII wireframes, item conversions, build order. | |
| +--------------------------------------------------------------------------------------+ |
| CLI Preview: trinity dispatch antigravity gui-wire -Scope "docs/reco/..." "..."          |
+------------------------------------------------------------------------------------------+
| [Show Command] [Copy CLI]                                 [Cancel]  [Dispatch Task (Run)]|
+------------------------------------------------------------------------------------------+
```
- State fields used:
  - Existing: `repos[].name`, `repos[].path`, `repos[].branch`, `availability.*`.
  - New: `repoFiles` (file tree from `git ls-files`), `activeScopes` (running task scopes for live overlap checking), `roles` (templates in `.trinity/roles/*.md`).
- Action API calls: `action: "dispatch"` (`args: { agent, task, scope, prompt, role, model, effort, planFirst, readOnly, after }`).
- Keyboard shortcuts:
  - `Ctrl+Enter`: Submit dispatch form
  - `Esc`: Dismiss modal
  - `Alt+C`: Copy generated CLI command

### (d) Merge Review Screen
```
+------------------------------------------------------------------------------------------+
| MERGE GATE REVIEW: gui-wire -> main (Holy trinity)                               [X Esc] |
| Branch: agent/antigravity/gui-wire | Commits: 2 | Base: main (clean, ahead 0, behind 0)  |
+------------------------------------------------------------------------------------------+
| GATE CHECKS:                                                                             |
| [PASS] Runner state: Terminated (exitCode 0)    [PASS] Scope guard: 1/1 files in reco/*  |
| [PASS] Conflicts: Clean merge (git merge-tree)  [PASS] Tests: tests\run-tests (31 passed)|
| [WARN] Review findings: 0 P0, 0 P1, 1 P2 finding (reviewer: codex)                       |
+------------------------------------------------------------------------------------------+
| FINDINGS & DIFF SUMMARY:                                                                 |
| - [P2] docs/reco/gui-wireframes.md: Line 142 consider adding Esc key note to drawer     |
| Modified files: docs/reco/gui-wireframes.md (+270 lines, -0 lines)                       |
+------------------------------------------------------------------------------------------+
| RESUME / FIX FEEDBACK:                                                                   |
| [Address P2 finding: add Esc shortcut note to drawer header...                         ] |
+------------------------------------------------------------------------------------------+
| CLI: trinity merge gui-wire                                                              |
| [Cancel]       [Resume Agent With Findings]       [Merge (Ignore P2)]       [Merge -Force|
+------------------------------------------------------------------------------------------+
```
- State fields used:
  - Existing: `tasks[].task`, `tasks[].branch`, `tasks[].commits`, `repos[].branch`, `repos[].uncommitted`.
  - New: `tasks[].terminal` (boolean), `tasks[].scopeViolation` (boolean + files), `tasks[].mergeConflicts` (boolean), `tasks[].testStatus` ("pass" | "fail"), `tasks[].findings` (parsed P0/P1/P2 findings list + reviewer).
- Action API calls:
  - `action: "merge"` (`task`, `args: { force: boolean, noReview: boolean }`, `confirm: true`)
  - `action: "resume"` (`task`, `args: { feedback: string }`)
  - `action: "sync"` (`task`)
  - `action: "cancel"` (`task`, `confirm: true`)
- Keyboard shortcuts:
  - `m`: Execute clean Merge
  - `Shift+M`: Execute Merge -Force (with confirmation)
  - `r`: Focus resume feedback textarea
  - `Esc`: Dismiss screen

### (e) Health Page ("Doctor")
```
+------------------------------------------------------------------------------------------+
| TRINITY HEALTH DOCTOR                                    [Run All Checks] [Auto-Fix All] |
+------------------------------------------------------------------------------------------+
| CHECK ITEM                           STATUS    DETAILS / REMEDIATION             ACTION  |
+------------------------------------------------------------------------------------------+
| Git core.hooksPath (.githooks)       [PASS]    Hooks configured and executable   [Verify]|
| Gitignore .codex-out/                [PASS]    Ignored in all registered repos   [Verify]|
| AGENTS.md test command               [WARN]    Repo 'gemini-live': Test is TBD   [Open]  |
| Disk space drive C: (<= 5 GB)        [FAIL]    2.6 GB free on C: (transcripts)   [Arch C]|
| Disk space drive D: (worktrees)      [PASS]    184.2 GB free on D:               [OK]    |
| Codex CLI & Login                    [FAIL]    Token expired; 'codex login' req  [Copy]  |
| Claude CLI & Auth                    [PASS]    Logged in (claude-opus-5-5)       [OK]    |
| Antigravity CLI (agy.exe)            [PASS]    agy 2.1 on PATH (Gemini 3.8 Flash)[OK]    |
| Orphan worktrees & stale PIDs        [WARN]    1 orphan worktree (selftest-old)  [Prune] |
| Dashboard server status              [PASS]    PID 14208, loopback only, v1.2    [Restrt]|
+------------------------------------------------------------------------------------------+
| SUMMARY: 7 Passed, 2 Warnings, 2 Failures                CLI: trinity doctor [--fix]     |
+------------------------------------------------------------------------------------------+
```
- State fields used:
  - Existing: `availability.*`.
  - New: `doctor.checks[]` (`id`, `name`, `status`, `detail`, `fixable`, `fixAction`), `doctor.diskSpace` (`cFreeBytes`, `dFreeBytes`), `doctor.serverPid`, `doctor.serverVersion`.
- Action API calls: `action: "doctor_run"`, `action: "doctor_fix"` (`args: { checkId: string }`, `confirm: true`), `action: "server_restart"`.
- Keyboard shortcuts:
  - `r`: Re-run all health checks
  - `a`: Auto-fix all safe checks
  - `Esc`: Return to default view

### (f) Housekeeping Page
```
+------------------------------------------------------------------------------------------+
| HOUSEKEEPING & ARTIFACT MANAGEMENT                          Total disk used: 12.8 MB     |
+------------------------------------------------------------------------------------------+
| [x] Select All Merged/Cancelled     Target: Move to .codex-out/archive/ (never deletes)  |
+------------------------------------------------------------------------------------------+
| TASK / ARTIFACT SET         STATE      AGE      FILES   TOTAL SIZE   ACTIONS             |
| [x] strip-icc-old           MERGED     4 days   8       4.2 MB       [Archive] [Inspect] |
| [x] collector-bench         CANCELLED  6 days   6       2.8 MB       [Archive] [Inspect] |
| [x] test-suite-haiku        MERGED     2 days   5       1.9 MB       [Archive] [Inspect] |
| [ ] gui-wire (active wt)    DONE       1 hour   3       0.4 MB       [Active Task]       |
+------------------------------------------------------------------------------------------+
| WORKTREE ORPHAN CLEANUP:                                                                 |
| [x] ..\Holy trinity.worktrees\selftest-tmp  (no active board entry)  [Prune Worktree]    |
| TEMP DIRECTORY CLEANUP:                                                                  |
| [x] 42 orphaned trinity-selftest-* dirs in %TEMP% (312 MB)           [Purge Temp]        |
| BOARD PRUNING:                                                                           |
| [x] 14 merged tasks older than 48h in agent-board.md                 [Prune Board]       |
+------------------------------------------------------------------------------------------+
| [Archive Selected (8.9 MB)]     [Prune All Cleanable]        CLI: trinity clean [-All]   |
+------------------------------------------------------------------------------------------+
```
- State fields used:
  - Existing: `repos[].tasks[]`.
  - New: `housekeeping.artifacts[]` (`task`, `state`, `ageDays`, `fileCount`, `sizeBytes`, `archived`), `housekeeping.orphanWorktrees[]`, `housekeeping.tempDirsCount`, `housekeeping.prunableBoardEntriesCount`.
- Action API calls:
  - `action: "clean_archive"` (`args: { tasks: string[] }`)
  - `action: "clean_worktrees"` (`args: { paths: string[] }`, `confirm: true`)
  - `action: "clean_temp"` (`confirm: true`)
  - `action: "board_prune"` (`args: { olderThanHours: number }`)
- Keyboard shortcuts:
  - `a`: Archive selected tasks
  - `p`: Prune orphan worktrees and temp directories
  - `Ctrl+A`: Toggle select all cleanable items

### (g) Settings Page
```
+------------------------------------------------------------------------------------------+
| TRINITY CONFIGURATION & SETTINGS                                    [Export] [Reset]     |
+------------------------------------------------------------------------------------------+
| Scope: (*) Global (~/.trinity/config.json)      ( ) Current Repo (.trinity.json)         |
+------------------------------------------------------------------------------------------+
| GIT & REVIEW SETTINGS:                                                                   |
| Base branch default:     [main               ]  Reviewer order: [codex,claude,antigrav v]|
| Max fix loop rounds:     [3                  ]  Gate rule:      [Block P0/P1, warn P2 v] |
+------------------------------------------------------------------------------------------+
| AGENT RUNTIMES & MODELS:                                                                 |
| Disabled agents:         [ ] Codex  [ ] Claude  [ ] Antigravity   (TRINITY_DISABLE)      |
| Antigravity CLI path:    [C:\Users\Hp\.gemini\antigravity-cli\agy.exe                  ] |
| Codex default model:     [gpt-6-luna         ]  Effort: [high   v]                       |
| Antigravity model:       [Gemini 3.8 Flash (High)                                      ] |
+------------------------------------------------------------------------------------------+
| DAEMON & POLLING:                                                                        |
| Max parallel workers:    [3                  ]  Poll interval: [3s  v]  Cache: [ON v]    |
| Web UI theme override:   (*) Dark  ( ) Light  ( ) OS System  Desktop alerts:   [ON v]    |
+------------------------------------------------------------------------------------------+
| [Save Settings]                      [Reload From Disk]      Config file: ~/.trinity/cfg |
+------------------------------------------------------------------------------------------+
```
- State fields used:
  - Existing: `availability.*`.
  - New: `config.global`, `config.repo` (`baseBranch`, `reviewerOrder`, `disabledAgents`, `maxParallel`, `pollInterval`, `theme`, `desktopNotifications`, `agentPaths`, `defaultModels`, `maxFixRounds`).
- Action API calls: `action: "config_save"` (`args: { scope: string, values: object }`), `action: "config_reload"`.
- Keyboard shortcuts:
  - `Ctrl+S`: Save configuration
  - `Alt+R`: Reload configuration from disk
  - `Esc`: Cancel changes and return to inbox

### (h) Tray Icon Menu
```
+---------------------------------------+
|  TRINITY AGENT TRAY      [Green: IDLE]|
+---------------------------------------+
|  Open Control Panel          Ctrl+Alt+T
|  -------------------------------------|
|  ! Needs Attention (2)             >  |
|    - [FAIL] test-collector (Codex)    |
|    - [DONE] gui-wire (AGY ready)      |
|  > Active Runs (2 running)         >  |
|    - strip-icc (Codex 09m 48s)        |
|    - audio-stream (AGY 04m 12s)       |
|  * Quick Merge Ready (1 task)...      |
|  + Dispatch New Task...               |
|  -------------------------------------|
|  [x] Desktop Notifications            |
|  Doctor / Health Check...             |
|  -------------------------------------|
|  Restart Server (port 7777)           |
|  Quit Trinity Tray                    |
+---------------------------------------+
```
- State fields used:
  - Existing: `agents.*` (running, failed, done counts), `repos[].tasks[]`.
  - New: `tray.worstStatus` (green: idle/ok | blue: running | amber: attention | red: failed), `tray.attentionCount`, `tray.readyToMergeTasks[]`.
- Action API calls: `open_control_panel` (shell launch deep link), `action: "merge"` (`task`, `confirm: true`), `action: "dispatch_dialog"`, `server_restart`, `tray_quit`.
- Keyboard shortcuts:
  - Global OS hotkey: `Ctrl+Alt+T` / `Win+Shift+T` (Open Control Panel)
  - Menu navigation: Up / Down arrows, `Enter` to invoke, `Esc` to close menu

### (i) Phone Width (375 px) Default View
```
+---------------------------------------+
| TRINITY [LIVE] [||]     [Menu=] [+New]|
| C: OK(1) | X: OFF | A: OK(1)          |
+---------------------------------------+
| ! ATTENTION NEEDED (2)                |
| +-----------------------------------+ |
| | [FAIL] test-collector   (Codex)   | |
| | exit 1 | 8m ago                   | |
| | [Inspect] [Retry] [Cancel]        | |
| +-----------------------------------+ |
| | [DONE] gui-wire         (AGY)     | |
| | +2 commits | 2m ago               | |
| | [Merge Review] [Diff]             | |
| +-----------------------------------+ |
+---------------------------------------+
| > ACTIVE RUNS (2)                     |
| +-----------------------------------+ |
| | [RUN] strip-icc (Codex) 09:48     | |
| | 320k tok | cl.exe /O2   [Drawer]  | |
| +-----------------------------------+ |
| | [RUN] audio-stream (AGY) 04:12    | |
| | 28k tok | write_file    [Drawer]  | |
| +-----------------------------------+ |
+---------------------------------------+
| [Show 4 Completed / Merged v]         |
+---------------------------------------+
```
- State fields used: Identical to default view (a); responsive media query `<= 600px`.
- Action API calls: Same endpoints (`inspect`, `retry`, `cancel`, `merge_review`); buttons meet minimum 44px touch-target standard.
- Touch interactions:
  - Tap card: open mobile-optimized full-screen drawer
  - Swipe left on card: reveal quick action buttons (Merge / Cancel)
  - Pull down: force manual state refresh

---

## 4. Convert the Page Items

### Dashboard Page Items
- Polling destroys DOM and resets focus -> no GUI: internal keyed reconciliation and DOM node recycling, shows up as stable focus, text selection, and scroll position across 3s polls | [M]
- Chat drawer has no focus trap and does not return focus -> GUI: Task drawer & Chat / Modal container: focus trapped inside drawer upon opening and restored to trigger button on Esc or close | backend: none | [S]
- Task cards are role="button" with nested buttons inside -> GUI: Control panel / Task card: plain semantic container with dedicated expand button and independent action buttons | backend: none | [S]
- No text search or state filter -> GUI: Control panel / Toolbar: search input field with '/' shortcut plus filter pills for Running, Attention, Done, Merged | backend: none | [S]
- No URL hash state -> GUI: Control panel / Router: deep-linkable URL hashes (#inbox, #tasks, #task=<repo>/<task>, #chat=<id>) preserved across reload | backend: none | [S]
- No pause or manual refresh -> GUI: Control panel / Header: pause/play toggle button and manual refresh button with interval selector (3s, 10s, manual) | backend: none | [S]
- Availability detail lives only in a title on non-focusable dot -> GUI: Control panel / Agent header cards: keyboard-focusable availability pill (tabindex="0") showing popover with error details and copyable fix command | backend: none | [S]
- Long lists: 16 finished subagents listed in full -> GUI: Control panel / Subagents & History: list capped at 5 recent items with collapsible 'Show N more' button | backend: none | [S]
- Token totals are cumulative prompt tokens including cache -> GUI: Control panel & Drawer / Metrics chip: segmented token chip showing Input, Cached, Output, Reasoning tokens and estimated cost | backend: new state field: tokens.cached/output/reasoning | [S]
- PLAN items in repo card cut mid-sentence -> GUI: Repos view / Plan section: truncated item text with ellipsis tooltip and collapsed counter ('+19 more') | backend: none | [S]
- Copy button wraps titles at <= 600 px -> GUI: Control panel / Mobile cards: compact 32px icon-only copy button on viewports <= 600px preventing multi-line wrap | backend: none | [S]
- 1760 of 3443 lines are CSS -> no GUI: internal refactoring into shared design tokens and modular utility classes, shows up as faster page load and clean responsive styles | [M]
- One-click cancel command for running tasks -> GUI: Attention inbox & Task cards / Action bar: 'Cancel' button with CLI confirmation modal | backend: action API: cancel | [S]
- One-click branch checkout and git inspection -> GUI: Task drawer / Action bar: 'Copy branch' and 'Checkout' action buttons | backend: none | [S]
- One-click remediation for unavailable agents -> GUI: Control panel & Health / Banner: 'Fix login' / 'Copy fix' button executing or copying login commands | backend: action API: doctor_fix | [S]
- Critical threshold visual alerts on rate limit bars -> GUI: Task drawer / Rate limits tab: progress bar turning amber at >= 80% and red at >= 95% utilization | backend: none | [S]
- Opt-in browser notification on running to done/failed -> GUI: Control panel & Settings / Toggle: HTML5 Notification permission prompt and setting toggle alerting on state transitions | backend: none | [M]
- Dynamic favicon and title status badges -> GUI: Browser tab / Favicon & Title: dynamic badge title ('(1 run, 1 fail) Trinity') and colored canvas favicon dot | backend: none | [S]
- Blast radius / files touched count badge on collapsed card -> GUI: Control panel / Card stats row: compact 'N files' badge summarizing worktree blast radius | backend: new state field: tasks[].filesTouchedCount | [S]
- Direct task search hotkey filter -> GUI: Control panel / Search bar: '/' hotkey instantly focuses global search bar | backend: none | [S]
- Copyable setup instructions on empty repository list -> GUI: Repos view / Empty state: guide box with copyable 'trinity init <path>' and 'trinity setup' buttons | backend: none | [S]

### Alternative UI Concepts
- Status kanban (Concept 1) -> GUI: Tasks view / View toggle: three-column lifecycle board (Running, Attention Needed, Completed) with draggable/actionable cards | backend: none | [M]
- Compact Attention inbox + mini tray (Concept 2) -> GUI: Control panel / Top section: condensed high-density attention queue and active runs strip, default landing view | backend: new state field: tasks[].attentionReason | [S]
- Timeline (Gantt) swimlanes (Concept 3) -> GUI: Tasks view / Timeline tab: temporal concurrency Gantt chart displaying run durations, agent overlap, and idle gaps | backend: new state field: tasks[].started/finished | [L]

---

## 5. Build Order

1. **DOM Stability & Keyed Reconciliation**: Implement keyed element updates in `scripts/dashboard.html` to eliminate focus/scroll resets on poll; wire up URL hash routing (`#inbox`, `#tasks`, `#task=`), accessibility fixes (focus trap, semantic cards), and `/` search hotkey.
2. **Attention Inbox & Top Strip**: Surface aggregated attention queue (failed, done-unmerged, stalled runs across all repos) at top of default view; style responsive 375px card stack with compact touch targets.
3. **Action API & Drawer Actions**: Implement loopback-only `POST /api/action` endpoint with token validation in `scripts/dashboard.ps1`; connect Task Drawer action bar buttons (Cancel, Retry, Resume, Open Folder, Copy Branch) with job toasts.
4. **Merge Gate Review Screen**: Build interactive merge review modal with live `git merge-tree` conflict radar, scope-guard verification, test-result badge, findings parser, and one-click Merge / Merge -Force / Resume triggers.
5. **Dispatch Form Modal**: Build "New Task" modal with agent availability checks, live scope tree picker, running task overlap collision warning, and prompt editor outputting copyable CLI commands.
6. **Health Doctor & Housekeeping Views**: Implement Health page (`trinity doctor` GUI) with safe auto-fix execution; implement Housekeeping page for artifact archiving (`.codex-out\archive\`) and temp/worktree pruning.
7. **Windows System Tray Companion**: Ship `scripts/tray.ps1` WinForms NotifyIcon companion showing worst-status color dot, balloon notifications on task completion, quick merge menu, and global `Ctrl+Alt+T` hotkey.
