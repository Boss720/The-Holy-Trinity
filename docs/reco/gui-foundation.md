# GUI foundation (shared contract for the GUI conversion)

Goal: every recommendation in `docs/recommendations.md` gets a GUI way to do it, so the user can run trinity from a window instead of typing commands. The CLI stays the source of truth; the GUI is a thin layer that runs the same `trinity` commands.

## Surfaces

1. **Control panel** = the existing dashboard page (`scripts/dashboard.html`, served by `scripts/dashboard.ps1` on `http://localhost:7777/`). Today it is read-only by spec; it gains actions through the action API below. Single file, vanilla JS, no CDN, light and dark, works at 375 px.
2. **Tray icon** = new `scripts/tray.ps1` (PowerShell 5.1 + built-in WinForms `NotifyIcon`, no new dependency). Icon colour = worst state across repos (green idle/ok, blue running, amber needs attention, red failed). Balloon on task done/failed. Menu: Open control panel, Needs attention (N), Merge ready tasks, Start/stop dashboard, Quit. Started by `trinity tray` and optionally at logon.
3. **Toasts** (already exist): clicking one opens the control panel deep-linked to the task (`http://localhost:7777/#task=<repo>/<task>`).

## Action API (server side)

- `POST /api/action` with JSON `{ "action": "<name>", "repo": "<repo path from state>", "task": "<task>", "args": { ... }, "confirm": true|false }`.
- Allowlist only. Each action maps to one `trinity.ps1 <command> ...` call run as a child process in the repo's main checkout (never a shell string built from input; arguments passed as an array, task names validated with the existing task-name rule). Unknown action = 400.
- Runs in the background; reply `{ "job": "<id>" }` at once. `GET /api/job?id=<id>` returns `{ state: running|done|failed, exitCode, output (last 64 KB) }`. The page shows a job toast with live output and the exit code.
- Security: loopback-only (already being added), `Host` must be `localhost:<port>`, `Origin` must be `http://localhost:<port>`, and a random per-server token embedded in the served HTML (`<meta name="trinity-token">`) must come back in header `X-Trinity-Token`. Destructive actions (merge, cancel, clean, force anything) require `confirm: true`, which the page only sends after a confirm dialog that shows the exact command. Every action is appended to `%USERPROFILE%\.trinity\actions.log` (time, action, repo, task, exit code; never prompt text).
- Every GUI action shows its CLI equivalent with a copy button ("Show command"), so the GUI also teaches the CLI.
- Spec change: `docs/dashboard.md` "Read-only: no POST, no actions" becomes "actions only through the allowlisted action API".

## Standard UI building blocks (use these names in the conversion)

- **Attention inbox**: top strip, all repos, ignores the repo filter: failed, done-not-merged, stalled, blocked-by-review.
- **Task drawer**: opens from a card; tabs Summary | Diff | Log | Chat | Review | Evidence; action bar: Merge, Review, Resume, Retry, Cancel, Open worktree folder, Open in editor, Copy branch.
- **Dispatch form**: modal from a "New task" button: agent picker (with availability), task name (validated live), scope picker (tree of `git ls-files` with glob preview and overlap warning against running tasks), prompt editor (multi-line, no quoting problems), role/template dropdown, model + effort, options (plan-first, read-only, best-of-N, after <task>), "Show command".
- **Merge review screen**: diff vs base, review findings as a list with severity chips, scope-violation and conflict warnings, test result, buttons Merge / Resume with findings / Cancel.
- **Settings page**: form over the config file (`~\.trinity\config.json` and repo `.trinity.json`): base branch, reviewer order, disabled agents, exe paths, default model/effort, max parallel, poll interval, theme.
- **Health page** ("doctor"): checklist with pass/warn/fail rows and a Fix button per row where a safe fix exists (enable hooks, add `.codex-out/` to `.gitignore`, prune registry, archive old artifacts, restart stale server).
- **Housekeeping page**: artifacts and board sections by task with size and age, select + Archive (move to `.codex-out\archive\`, never delete), worktree list with orphan flags.

## Item format for conversions

`- <original title> -> GUI: <surface> / <control>: <what the user sees and clicks> | backend: <none | action API: <action> | new state field: <name> | new trinity command: <cmd>> | [S|M|L]`

If an item has no sensible GUI form (pure internal fix), say `-> no GUI: <why>, shows up as <visible effect>` in one line.
