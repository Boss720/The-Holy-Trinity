# Antigravity UI Audit: scripts/dashboard.html

## Current page issues

- [P1] [M] Polling destroys DOM and resets focus - dashboard.html:3033-3035 - Every 3s poll wipes out all lane DOM via removeChild loop, destroying active keyboard focus, text selections, and scroll positions. Replace with keyed node reconciliation or diffing.
- [P1] [S] Chat drawer lacks focus trap and return - dashboard.html:3145, 3161 - Opening drawer focuses close button but Tab escapes into background document, and closing does not restore focus to the trigger button. Add keyboard trap and store activeElement before opening.
- [P1] [S] Nested interactive controls on task cards - dashboard.html:2314-2316, 2342, 2517 - Task card sets role="button" and tabindex="0" while containing nested copy and chat buttons, violating WAI-ARIA and breaking screen reader navigation. Make container a semantic div and use a dedicated expand button.
- [P1] [M] Task drawer scroll position resets on poll - dashboard.html:2715, 2729 - Although expandedTaskKeys persists open cards, inner pre.mono-block elements for result and logTail are recreated on every poll, jumping scroll back to top. Retain scroll offsets by taskKey or preserve node references.
- [P2] [M] No unified triage queue for failed and mergeable tasks - dashboard.html:3077-3086 - Tasks are partitioned into 3 agent lanes, requiring operators to scan and scroll each column to find tasks needing action. Introduce an aggregated attention section at the top for failed runs and mergeable branches.
- [P2] [S] Missing text search and status filter controls - dashboard.html:1876-1892 - Toolbar only supports repository selection and hiding finished tasks; lacks free-text filtering on task name, scope, or branch, and cannot isolate running or failed tasks. Add search input and status filter pills.
- [P2] [S] No URL hash state or deep linking - dashboard.html:2005-2012 - Selected repo, expanded cards, and active chat drawers are not mirrored to window.location.hash. Persist active view state to hash so reloading or sharing links preserves context.
- [P2] [S] Uncontrollable polling interval - dashboard.html:3438 - Polling is locked to a 3s setInterval with no pause or manual refresh button. Add pause/play toggle and selectable intervals (3s, 10s, manual) to prevent DOM shifts during inspection.
- [P2] [S] Inaccessible availability tooltip - dashboard.html:1805, 2241-2244 - Availability status detail is stored solely in a title attribute on a non-focusable span dot. Add tabindex="0" and aria-describedby so keyboard users can inspect error details.
- [P2] [S] Static page title and absent web notifications - dashboard.html:8, 3391-3402 - Document title stays static ("Trinity Operator Dashboard") during background tasks. Update title with live counts and trigger Web Notifications API when a running task transitions to done or failed.
- [P3] [S] Mobile title row wrap jitter - dashboard.html:810-824, 1364-1368 - At viewports <= 600px, btn-copy expands to 44px min-height, forcing the task name and badges into disjointed multi-line wraps. Convert copy button to a compact icon button on small screens.
- [P3] [M] Monolithic stylesheet bloating single file - dashboard.html:9-1778 - Over 1760 lines of repetitive CSS in a 3443-line file complicates maintenance and audits. Group utility classes, consolidate shared card styles, and streamline theme token overrides.
- [P3] [S] Missing manual dark/light theme override - dashboard.html:98-177 - Dashboard theme is strictly bound to prefers-color-scheme media query. Add a localStorage-backed theme switch to let operators toggle theme regardless of OS settings.
- [P3] [S] Empty repository state provides no recovery command - dashboard.html:3109-3110 - When no repos are tracked, UI displays plain text without guidance. Include copyable trinity init <path> and trinity setup commands.

## Missing features

- [P1] [S] One-click cancel command for running tasks - tasks[].state, dashboard.html:2336-2383 - Running cards show active status but provide no cancellation action. Add "Copy cancel" button copying trinity cancel <task> alongside "Copy merge".
- [P2] [S] One-click branch checkout and git inspection - tasks[].branch, dashboard.html:2493-2496 - Branch name is rendered as plain text. Add click-to-copy for git checkout <branch> or git log main..<branch>.
- [P2] [S] One-click remediation for unavailable agents - availability.<agent>.detail, dashboard.html:2248-2250 - Availability banners suggest commands (e.g. codex login) in text strings. Extract recommended commands into one-click copy buttons.
- [P2] [S] Critical threshold visual alerts on rate limit bars - tasks[].rateLimits, dashboard.html:2661-2665 - Rate limit bars render with uniform blue fill regardless of usage. Apply warning (amber) at 80% and danger (red) at 95% utilization.
- [P2] [S] Polling pause and manual refresh trigger - dashboard.html:3438 - Operators cannot freeze the view to examine rapid log output. Add pause button and manual reload button in the header.
- [P2] [M] Native browser notifications on task completion - tasks[].state, dashboard.html:3391-3402 - Operators working in background tabs receive no notice when runs finish. Add opt-in HTML5 Notification alerts on state transitions from running to done/failed.
- [P2] [S] Dynamic favicon and title status badges - dashboard.html:7-8 - Browser tab gives no indicator of active work. Prepend counts to title (e.g. "(1 run, 1 fail) Trinity") and update favicon dot color.
- [P2] [S] Blast radius / files touched count badge on collapsed card - tasks[].filesTouched, dashboard.html:2409-2468 - File count is buried in the expanded drawer. Surface a compact chip (e.g. "2 files") on the collapsed stats row.
- [P3] [S] Direct task search hotkey filter - dashboard.html:1876-1892 - Searching tasks requires manual scrolling. Add a "/" keyboard shortcut to focus a real-time task search input.
- [P3] [S] Copyable setup instructions on empty repository list - repos[], dashboard.html:3109-3110 - Unconfigured instances show a dead end. Render ready-to-run setup commands with copy buttons.

## Alternative UI concepts

### Concept 1: Status Kanban Board (Lifecycle Action Flow)

```
+--------------------------------------------------------------------------+
| REPO: [Holy trinity v]  FILTER: [All States v]  [Search...             ] |
+-----------------------+--------------------------+-----------------------+
| RUNNING (2)           | ATTENTION NEEDED (2)     | COMPLETED (4)         |
+-----------------------+--------------------------+-----------------------+
| [Codex] strip-icc     | [FAILED] test-collector  | [MERGED] dash-server  |
| 09m 48s | 320k tok    | Codex | exit 1 | 08:30   | Codex | 3 commits     |
| > run_command         | [View Log] [Rerun]       | 09:15 | 827k tok      |
+-----------------------+--------------------------+-----------------------+
| [AGY] dash-ui         | [DONE] visual-compare    | [DONE] refactor       |
| 06m 33s | 26k tok     | AGY | 2 commits | 08:58  | Claude | 08:50        |
| > write_file          | [Copy Merge] [Open Chat] | 14 tools | 1.2k tok   |
+-----------------------+--------------------------+-----------------------+
```

- Who it serves: Orchestrators and lead developers actively driving task pipelines.
- What it solves: Shifts layout from agent silos to operational lifecycle. Brings blocked runs and pending merges into an immediate "Attention Needed" focal point without cross-lane scanning.
- Rough effort: Medium. Uses existing fields tasks[].state, tasks[].agent, tasks[].task, tasks[].commits, tasks[].tokens, tasks[].durationSec.

### Concept 2: Compact Attention Inbox & Mini Operator Tray

```
+--------------------------------------------------------------------------+
| TRINITY TRAY | Claude: OK (1 run) | Codex: OFF | AGY: OK (1 run) | [Live]|
+--------------------------------------------------------------------------+
| ATTENTION QUEUE: 1 to merge, 1 failed                                    |
| ! FAIL | test-collector  | Codex | exit 1     | 08:30 | [Inspect] [Chat] |
| * DONE | visual-compare  | AGY   | +2 commits | 08:58 | [Copy Merge]     |
+--------------------------------------------------------------------------+
| ACTIVE RUNS (2):                                                         |
| > RUN  | strip-icc       | Codex | 09m 48s    | cl.exe /O2 | 320k tok    |
| > RUN  | dash-ui         | AGY   | 06m 33s    | write_file | 26k tok     |
+--------------------------------------------------------------------------+
| [v] Show History (4 merged/cancelled)   [v] Tracked Repos (1)            |
+--------------------------------------------------------------------------+
```

- Who it serves: Developers keeping the dashboard open in a narrow side-tile or half-screen while actively coding.
- What it solves: Replaces bulky 140px cards and sparse lanes with high-density tabular rows. Maximizes visible task throughput in under 300px of vertical space.
- Rough effort: Small. Uses existing fields availability.*, agents.*, tasks[].state, tasks[].task, tasks[].agent, tasks[].lastTool, tasks[].commits.

### Concept 3: Parallel Execution Timeline (Gantt Swimlanes)

```
+--------------------------------------------------------------------------+
| TIME AXIS (Last 2 Hours)      10:00        10:15        10:30      NOW   |
+--------------------------------------------------------------------------+
| CLAUDE      |==== dash-detail (session) ===========================>     |
|             |          [sub: GIF]   [sub: Theme]                         |
+-------------+------------------------------------------------------------+
| CODEX       |== server ==|  |! test |  |====== strip-icc ==========>     |
|             | (09:00-15) |  | exit1 |  | (10:05 - now)                   |
+-------------+------------------------------------------------------------+
| ANTIGRAVITY |=========== compare ==========|  |=== dash-ui ========>     |
|             |      (08:42 - 08:58)         |  | (10:08 - now)            |
+-------------+------------------------------------------------------------+
| Click bar to open drawer. Red = failed; Green = merged; Striped = active.|
+--------------------------------------------------------------------------+
```

- Who it serves: Multi-agent architects diagnosing concurrency bottlenecks, idle agent gaps, and scheduling dependencies.
- What it solves: Exposes temporal concurrency and run durations visually rather than through isolated numeric timers. Highlights when agents wait or collide.
- Rough effort: Large. Uses existing fields tasks[].started, tasks[].finished, tasks[].durationSec, tasks[].state, tasks[].agent, claudeSessions[].started.

## Top 5

1. Replace full DOM rebuilds with keyed element reconciliation to eliminate focus loss, selection clears, and scroll resets across 3s polls (dashboard.html:3033-3035).
2. Add an aggregated "Attention Needed" queue at the top of the page for failed runs and unmerged branches (dashboard.html:3077-3086).
3. Implement drawer focus trapping, trigger focus restoration, and remove nested button roles for accessibility compliance (dashboard.html:2314-2316, 3145-3165).
4. Introduce real-time text search and state filter buttons to quickly locate tasks without manual lane scanning (dashboard.html:1876-1892).
5. Add a polling pause/interval toggle and dynamic title status updates to support non-intrusive background monitoring (dashboard.html:8, 3438).
