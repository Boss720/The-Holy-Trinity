# Dashboard GUI: full control (contract)

Principle: if a human cannot do it in the dashboard in under three clicks, the feature is not done.
The CLI stays the source of truth: every write the GUI makes runs a `trinity` command as an action job
(existing `/api/action` with token, Origin, loopback and `confirm` guards) and the confirm dialog shows that exact command.
Reads come from files whose formats are fixed below, so the server, the CLI and the page can be built in parallel.

Phase 0 status (2026-10-28): poll guard + cached snapshot (dash-poll b1d4749, dash-perf b564f19), loopback 403,
merge gate (cli-mergebase e2bfb34), runner deadline + stall (runner-watchdog 42a2a6d), wave 2 merged.
Left: scope guard in the CLI `merge` (Claude), live loopback re-check (Claude, at verification).

## 1. Files under `<repo>\.trinity\` (gitignored, never committed: a dirty main would block merges)

All JSON is UTF-8 without BOM, written atomically (write `<name>.tmp`, then `Move-Item -Force`).
A missing file means defaults. An unreadable file means defaults plus a `configError` string in state.

### `.trinity\trinity.json` (repo settings)
```json
{
  "version": 1,
  "slots": { "codex": 2, "antigravity": 1, "claude": 1 },
  "base": "",
  "test": "",
  "autoMerge": false,
  "maxRounds": 3,
  "deadlineMinutes": 120,
  "models": { "codex": "", "antigravity": "", "claude": "" },
  "autopilot": {
    "enabled": false,
    "approval": true,
    "maxTasksPerHour": 6,
    "maxConsecutiveFailures": 3,
    "cleanRunsBeforeAutoMerge": 10
  }
}
```
Ranges: slots 0-8 each; maxRounds 1-10; deadlineMinutes 5-1440; maxTasksPerHour 1-60; maxConsecutiveFailures 1-20.
Unknown keys are kept on write. Empty string = not set (fall through).
Precedence for every knob: CLI flag > env var (`TRINITY_BASE`, `TRINITY_DEADLINE_MINUTES`, `TRINITY_CODEX_MODEL`, ...) > `trinity.json` > built-in default.
`test` overrides the AGENTS.md `Test:` line when non-empty. `autoMerge` only takes effect when `autopilot.approval` is false
AND the repo has at least `cleanRunsBeforeAutoMerge` decisions with action `merged` or `ready` and no failure between them; otherwise autopilot behaves as approval mode.

### `.trinity\queue.json` (queued tasks, in order)
```json
{ "version": 1, "items": [
  { "task": "login-form", "agent": "codex", "scope": "src/auth/*", "promptFile": ".codex-out\\prompt-login-form.md",
    "base": "", "model": "", "addedAt": "2026-10-28T14:00:00", "addedBy": "dashboard",
    "waiting": "no free slot" }
] }
```
`waiting` is written by the scheduler on every tick: `""` (about to start), `no free slot`, `rate limit`, `agent unavailable`,
`scope overlaps <task>` , `paused`, `autopilot off` (never: queued items start whenever the scheduler runs; see below).
Task names follow the board rule `^[a-z0-9][a-z0-9-]*$`, max 40 chars, unique across queue + board (except cancelled).

### `.trinity\PAUSE` (kill switch)
Exists = scheduler and autopilot do nothing but log `paused`. Content: one line, the reason (`user`, `limit: 3 consecutive failures`, ...).
Written by the GUI Stop button, by `trinity pause`, and by autopilot on a limit breach. Removed only by `trinity unpause` / GUI Unpause or the GUI Auto button.

### `.trinity\scheduler.json` (scheduler heartbeat)
`{ "pid": 1234, "startedAt": "<iso>", "processStart": "<iso, for pid reuse check>", "lastTickAt": "<iso>", "now": "<what it is doing>", "next": "<next queued task or ''>" }`
Alive = pid exists AND its process start time equals `processStart` AND `lastTickAt` within 90 s.

### `.trinity\decisions.jsonl` (append-only, one JSON per line)
`{ "at": "<iso>", "task": "<task or ''>", "action": "started|ready|merged|resumed|failed|skipped|paused|limit", "reason": "merged: review clean, tests 47/47, scope ok", "round": 1 }`
Rotate at 2000 lines to `decisions-<yyyyMMddHHmmss>.jsonl`.

## 2. CLI (owner: `scripts/lib/config.ps1`, `scripts/lib/scheduler.ps1`; Claude wires commands into `scripts/trinity.ps1`)

Library functions (dot-sourced; `$Paths` is the object from `Get-Paths` in trinity.ps1 with `.Main`, `.Root`, `.Common`, `.Out`):

- `Get-TrinityConfig $Paths` -> hashtable with every key above filled from defaults; adds `_source` map (key -> `file|default`) and `_error` if the file was unreadable.
- `Set-TrinityConfig $Paths $Patch` -> deep-merge `$Patch` (hashtable) into the file, validate ranges (throw with a clear message on bad values), atomic write, return the new config.
- `Get-TrinityQueue $Paths` / `Add-QueueItem $Paths $Item` / `Remove-QueueItem $Paths $Task` / `Move-QueueItem $Paths $Task $Index`.
  All under a lock file `.trinity\queue.lock` (create-new FileStream, retry 50 ms up to 5 s, stale after 30 s).
- `Test-PauseSwitch $Paths` -> `@{ paused=bool; reason=string }`; `Set-PauseSwitch $Paths $Reason`; `Clear-PauseSwitch $Paths`.
- `Add-Decision $Paths $Task $Action $Reason [$Round]`; `Get-Decisions $Paths [$Last=20]`.
- `Get-SlotUse $Paths $Config` -> `@{ codex=@{used;max}; antigravity=@{used;max}; claude=@{used;max} }`; used = board entries of that agent in state running (runner alive or status `started|running|working`).
- `Invoke-SchedulerTick $Paths [-DispatchCommand <scriptblock>]` -> one pass, returns `@{ started=@(tasks); waiting=@{task=reason}; autopilot=@(decisions made) }`:
  1. PAUSE -> set every item's waiting to `paused`, log nothing new if already logged in the last hour, return.
  2. For each queue item in order: agent unavailable (use the availability function already in `scripts/lib/board.ps1`) -> `agent unavailable`;
     Codex rate limit at or above 95% in the newest rollout -> `rate limit` (best effort; skip check if unknown);
     slot full -> `no free slot`; scope glob overlaps a running task's scope (same normalisation as dashboard dispatch check) -> `scope overlaps <task>`;
     else dispatch via `-DispatchCommand` (default: run `trinity.ps1 dispatch <agent> <task> -Scope <scope> -PromptFile <file> [-Base] [-DeadlineMinutes]` in a child `powershell -NoProfile -ExecutionPolicy Bypass -File`), remove from queue, decision `started`.
  3. Autopilot (only when `autopilot.enabled`): limits first: started-in-last-hour >= maxTasksPerHour or consecutive `failed` decisions >= maxConsecutiveFailures -> `Set-PauseSwitch "limit: <which>"`, decision `limit`, return.
     Then per board task (oldest first, one action per tick):
     - state `done`, not yet decided: run the merge gate WITHOUT merging (`trinity.ps1 merge <task> -DryRun`, Claude adds `-DryRun`: review + scope + tests in the worktree, exit 0 clean).
       Clean + approval mode -> board status `ready: <reason>`, decision `ready`. Clean + auto-merge allowed -> `trinity.ps1 merge <task> -Yes`, decision `merged`. Not clean -> resume (below).
     - state `failed` or not-clean done, rounds used < maxRounds -> `trinity.ps1 resume <task> -FeedbackFile <findings or log tail file>`, decision `resumed` with round; at maxRounds -> decision `failed`, leave it for a human.
  4. Write `scheduler.json` heartbeat.
- `scripts/scheduler.ps1 -Repo <path> [-IntervalSeconds 15] [-Once]`: loop calling `Invoke-SchedulerTick`; single instance per repo (refuse to start when `scheduler.json` says alive); exits cleanly on Ctrl+C, on `.trinity\scheduler.stop` (deletes it), and when queue empty AND autopilot off for 10 min.

Commands (Claude wires; each prints what it did, exit 1 on error):
`trinity config [get [<key>]] | set <key> <value> | set -Json <file>`, `trinity queue [list] | add <agent> <task> -Scope .. -PromptFile .. | remove <task> | move <task> <index>`,
`trinity scheduler start|stop|status|tick`, `trinity pause [<reason>]`, `trinity unpause`, `trinity autopilot on|off`, `trinity history [-Json]`,
`trinity merge <task> -DryRun`. A dry run requires a clean worker worktree whose branch includes the current base; update the branch with the base before retrying if it has fallen behind. `start` launches `scheduler.ps1` detached (Start-Process -WindowStyle Hidden).
`dispatch` and `merge` read `trinity.json` for base, test, deadline and model.

## 3. Server additions (owner: `scripts/dashboard.ps1`)

Reads the files above directly (format in section 1; do not dot-source the new libs, they land separately). All reads cheap and cached by mtime.

### `/api/state`, per repo (additive)
```
config:    effective trinity.json (defaults filled), plus configError when unreadable
queue:     [ { task, agent, scope, addedAt, waiting, overlaps: [task] } ]
slots:     { codex: { used, max }, antigravity: {...}, claude: {...} }
scheduler: { alive: bool, lastTickAt, now, next }
autopilot: { enabled, approval, autoMergeAllowed: bool, cleanRuns: int, paused: bool, pauseReason, roundsUsed: { task: n }, decisions: [last 20, newest first], limitBreach: "" }
```
Task `state` gains `ready` (status starts with `ready`) and `stalled` (status contains `(stalled`), and `queued` items are NOT tasks (they live in `queue`).
Top level `attention[]` (existing) also gets: limit breach / paused-by-limit (kind `limit`), `ready` tasks (kind `ready`).

### New action verbs (all POST `/api/action`, same guards; destructive ones need `confirm:true`; reply 202 `{job, command}`)
| action | extra body fields | command run | confirm |
|---|---|---|---|
| `resume` | `feedback` (string, 1..16 KB) | `trinity resume <task> -FeedbackFile <.codex-out\feedback-<task>-<job>.md>` | yes |
| `retry` | - | `trinity retry <task>` | yes |
| `review-task` (fix) | - | `trinity merge <task> -DryRun` (was a base review of main) | no |
| `queue-add` | `agent`, `scope`, `prompt` (like dispatch) | `trinity queue add <agent> <task> -Scope .. -PromptFile ..` then `trinity scheduler start` | yes |
| `queue-remove` | - | `trinity queue remove <task>` | yes |
| `queue-move` | `index` (int >= 0) | `trinity queue move <task> <index>` | no |
| `start-now` | - | `trinity queue remove <task>` + `trinity dispatch ...` from the queue item, only if a slot is free (else 409 `no free slot`) | yes |
| `settings-save` | `config` (object, keys of section 1 only, validated server side) | `trinity config set -Json <.codex-out\config-<job>.json>` | yes |
| `autopilot` | `enabled` (bool), optional `approval` (bool) | `trinity autopilot on|off [-Approval]` (+ `trinity scheduler start` when on) | yes |
| `pause` | `reason` (string <= 200) | writes `.trinity\PAUSE` directly first (works if CLI hangs), then `trinity scheduler stop` | no |
| `unpause` | - | `trinity unpause` | yes |
Repo-level verbs (`settings-save`, `autopilot`, `pause`, `unpause`) take `task: ""`; the task-name check is skipped for them only.
Command strings in replies use the real values (`command` shows exactly what runs).

### New read routes (GET, loopback + Host, no token)
- `/api/history?repo=<path|all>&agent=<a|all>&outcome=<merged|cancelled|failed|all>` -> `{ items: [ { repo, task, agent, outcome, started, finished, durationSec, commits, model, tokens } ] }` from board + `meta-<task>.json`, newest first, max 500.
- `/api/task/review?repo&task` -> `{ text, findings: [ { severity: "P0".."P3", title, file, line } ], parsed: bool, at }` from `.codex-out\review-<task>.md`.
- `/ui/<name>` serves `scripts/dashboard-ui/<name>` when name matches `^[a-z0-9-]+\.(js|css)$`, correct content type, no-cache; else 404.

## 4. Page (owners: `scripts/dashboard.html` = shell; `scripts/dashboard-ui/*` = new screens)

### Shell contract (`window.Trinity`, defined in dashboard.html before the module scripts)
```js
window.Trinity = {
  getState(),                          // last /api/state object (or null)
  onState(cb),                         // cb(state) after every successful poll; returns unsubscribe
  action(body),                        // shows the confirm dialog with the command preview when body.confirm, POSTs /api/action, tracks the job, resolves {job, command} or rejects Error(message)
  confirmCommand(title, command),      // Promise<bool>, the existing confirm dialog
  openTask(repoPath, task, tab),       // opens the task drawer on a tab: 'log'|'diff'|'review'|'chat'|'files'
  openWizard(prefill),                 // opens the new-task wizard ({repo, agent, task, scope, prompt, mode:'start'|'queue'})
  addView(id, label, render),          // adds a header tab; render(container, state) is called on show and on every poll while shown
  toast(text, kind)                    // 'ok'|'warn'|'error'
};
```
Module files are loaded with `<script src="/ui/board.js" defer>` and `<link rel="stylesheet" href="/ui/board.css">`; they only use `window.Trinity` and the DOM inside the containers they get.
The sample route (`?sample=1`) must work offline: the module tolerates missing fields.

### Screens
- **Overview** (`board.js`, view id `overview`, first tab): one card per repo: name, branch, slots "2/3 codex, 1/2 antigravity, 0/1 claude", running count, agent availability dots, Codex rate-limit bars, autopilot toggle (off by default; turning on asks confirm), scheduler alive chip, paused banner with Unpause, Settings button, Autopilot button.
- **Board** (`board.js`, view id `board`): columns `queued | running | done | ready | failed | stalled | merged | cancelled` (cancelled as a drop zone, collapsed). Repo filter. Drag queued -> running = `start-now`; drag any non-terminal -> cancelled = `cancel`; drag done/ready -> merged = `merge`; every drop goes through the confirm dialog with the exact command. Queued card shows `waiting: <reason>` in neutral grey, overlap warning badge (amber) from `queue[].overlaps`. Click any card -> `Trinity.openTask`. Queued cards drag within the column to reorder (`queue-move`).
- **Settings panel** (`board.js`, modal per repo): sliders slots per agent (0-8), base branch text, test command text, max rounds, deadline minutes, model per agent, autoMerge toggle (disabled with the reason until clean runs reached), autopilot limits form. Save = `settings-save` (confirm shows the JSON diff).
- **Autopilot panel** (`board.js`, drawer per repo): now, next queued task, rounds used per task, last 20 decisions with reasons, limits with current values, big Stop button (`pause`), red banner on `limitBreach`.
- **Task drawer** (shell): existing Log, Diff, Chat; add Review (findings from `/api/task/review` as severity chips) and Files (files touched vs scope globs, out-of-scope red). Buttons: Resume with feedback (textarea, prefilled with review findings), Retry, Review (`review-task`), Merge, Cancel, Open folder; each disabled with a reason when state does not allow it.
- **New task wizard** (shell, existing dispatch form): add mode radio Start now / Add to queue (`queue-add`), model field, glob preview (files matching the scope, from existing dispatch check), live check stays; Start disabled until check passes.
- **Needs attention** (shell, existing Inbox strip): each item gets one-click fix buttons by kind: failed -> Resume / Retry; stalled -> Resume / Cancel; done-not-merged -> Review / Merge; ready -> Merge; limit -> Open autopilot / Unpause.
- **Header** (shell): slots summary across repos, Auto button (Stop all's counterpart), Stop-all button (pause every repo with autopilot on), notifications toggle.
  - **Auto** (Stop all's counterpart, before Stop all): targets repos where `!autopilot.enabled || autopilot.paused || !scheduler.alive`. Disabled (with a title) when actions are off (missing token or server actions off) or there are no targets. Click opens the usual confirm dialog showing, per repo: `cd /d "<path>" && [trinity unpause && ]trinity autopilot on[ -Approval] && trinity scheduler start` (unpause only when paused; -Approval kept from the repo's `autopilot.approval`). On confirm: per repo, POST `/api/action` `{action:'unpause', ...}` first when paused, then `{action:'autopilot', enabled:true, approval:<repo setting>, confirm:true}` (server runs autopilot on + scheduler start). Toast "Auto: started N of M repos", then refresh. Sample mode never POSTs.
  - **Stop all**: pauses each target repo via `pause`.
- **Notifications** (shell): Browser Notification API (ask permission on toggle), fire on a task entering done, failed, stalled, ready or a new attention item; click focuses the task. Remember toggle in localStorage.
- **History** (`history.js`, view id `history`): table from `/api/history`, filters repo / agent / outcome, Export CSV (client side, RFC 4180 quoting).

## 5. Build order and owners (army: Codex on gpt-6.1-terra, Claude subagents; no Antigravity)

Wave A, parallel, disjoint files:
1. Codex `sched-core`: `scripts/lib/config.ps1`, `scripts/lib/scheduler.ps1`, `scripts/scheduler.ps1`, `tests/cases/sched-core.ps1`.
2. Codex `dash-api`: `scripts/dashboard.ps1`, `tests/cases/dash-api.ps1`.
3. Claude `ui-shell`: `scripts/dashboard.html`, `scripts/dashboard-sample.json`.
4. Claude `ui-board`: `scripts/dashboard-ui/board.js`, `scripts/dashboard-ui/board.css`, `scripts/dashboard-ui/history.js`, `scripts/dashboard-ui/harness.html`.
Claude (orchestrator): Codex model knob, CLI scope guard, then after merges: wire commands into `scripts/trinity.ps1`, help lines, `.gitignore` `.trinity/`, `merge -DryRun`, live click-through.
