# Dashboard spec

One local page that shows what Claude, Codex and Antigravity are doing across every repo that uses trinity.

## Pieces and owners

| File | Owner | What |
|---|---|---|
| `scripts/dashboard.ps1` | codex | Read-only data collector + localhost HTTP server |
| `scripts/dashboard.html` | antigravity | Single-file UI (inline CSS/JS, no CDN, no build) |
| `scripts/dashboard-sample.json` | antigravity | Sample state matching the contract below, for previewing the UI offline |
| `scripts/trinity.ps1`, `scripts/lib/board.ps1` | claude | `trinity dashboard`, `trinity track`, repo registry |
| `tests/` | codex | Self-test cases for the collector |

## Repo registry

`%USERPROFILE%\.trinity\repos.txt`: one absolute repo root per line (main checkout), written by `trinity init` and `trinity setup`. Missing or stale lines (path gone, not a git repo) are skipped silently. The repo the dashboard is started from is always included even if not listed.

## Data sources per repo

All read-only. Never run git commands that change state.

- Main checkout root: `git -C <path> rev-parse --show-toplevel`; common dir: `git -C <path> rev-parse --path-format=absolute --git-common-dir`.
- Board: `<common-dir>\agent-board.md`. Format, one section per task:
  ```
  ## <task>
  - agent: codex | antigravity | claude
  - branch: agent/<agent>/<task>      (claude tracked tasks: "-")
  - worktree: <abs path>               (claude tracked tasks: "-")
  - scope: <glob>
  - status: <text>
  ```
  Status text examples: `started 2026-10-25 08:43`, `running 2026-10-25 08:43`, `done (1 commits) 2026-10-25 08:55`, `done, no commits 2026-...`, `failed (exit 3) 2026-...`, `merged 2026-...`, `cancelled 2026-...`, `done: <summary> 2026-...` (claude), `waiting for claude session 2026-...`, `working: <note> 2026-...` (claude tracked).
- Out dir: `<main>\.codex-out\`: `result-<task>.md` (agent's final summary), `log-<task>.txt` (agent log), `pid-<task>.txt` (runner PID while it runs; deleted when finished), `review-<task>.txt`, `deferred-<task>.txt`.
- `PLAN.md` in the main checkout: lines `- [x] ...` and `- [ ] ...`.
- `HANDOFF.md`: the bullet lines under `## Status`.

## JSON contract: `GET /api/state`

```json
{
  "generated": "2026-10-25T09:30:05",
  "agents": {
    "claude":      { "running": 1, "done": 3, "failed": 0, "total": 4 },
    "codex":       { "running": 0, "done": 5, "failed": 1, "total": 6 },
    "antigravity": { "running": 1, "done": 1, "failed": 0, "total": 2 }
  },
  "repos": [
    {
      "name": "Holy trinity",
      "path": "D:\\AI\\projects\\Dev\\Projects\\Holy trinity",
      "branch": "main",
      "uncommitted": 0,
      "ahead": 0,
      "plan": { "done": 12, "total": 13, "open": ["Windows notification seen on screen - user"] },
      "handoff": ["Completed: Modules 0-2", "In flight: none", "Next command: ...", "Blockers: none"],
      "tasks": [
        {
          "task": "selftest",
          "agent": "codex",
          "state": "done",
          "status": "done (1 commits) 2026-10-25 08:55",
          "updated": "2026-10-25 08:55",
          "branch": "agent/codex/selftest",
          "scope": "tests/*",
          "runnerAlive": false,
          "commits": 1,
          "result": "first 15 lines of result-<task>.md, or empty",
          "logTail": "last 15 lines of log-<task>.txt, or empty"
        }
      ]
    }
  ]
}
```

Rules:
- `state` is one of `running`, `done`, `failed`, `merged`, `cancelled`, `waiting`, `other`. Derivation: runner pid alive or status starts with `started`/`running`/`working` -> `running`; `failed` -> `failed`; `merged` -> `merged`; `cancelled` -> `cancelled`; `done` -> `done`; `waiting` -> `waiting`; else `other`.
- `agents` counts tasks across all repos: `running` = state running, `done` = done + merged, `failed` = failed, `total` = all tasks. Always include all three agent keys.
- `updated` = trailing `yyyy-MM-dd HH:mm` of the status, or empty.
- `commits` = `git rev-list --count main..<branch>` if the branch exists, else 0.
- `uncommitted` = number of `git status --porcelain` lines in the main checkout; `ahead` = commits ahead of the upstream, 0 if none.
- Tasks sorted: running first, then by `updated` descending. Repos sorted by name.
- Strings are plain text; the UI must escape them (they come from agent output).

## Server

- `powershell -File scripts\dashboard.ps1 [-Port 7777]`: `System.Net.HttpListener` on `http://localhost:<port>/` only (never `+` or `*`). Routes: `GET /` -> `dashboard.html` next to the script; `GET /api/state` -> JSON above (`Content-Type: application/json; charset=utf-8`, `Cache-Control: no-store`); anything else 404. Read-only: no POST, no actions.
- One request at a time is fine. Each request rebuilds state (must stay under ~1s for 10 repos with 20 tasks each).
- `-Once` switch: print the state JSON to stdout and exit (used by tests and `trinity dashboard -Json`).
- Clean shutdown on Ctrl+C / process stop; on startup, if the port is busy, exit 2 with a clear message.

## UI

- Header: overall counts per agent with a colored identity per agent (Claude, Codex, Antigravity), last refresh time, a "live" indicator.
- Three lanes (Claude | Codex | Antigravity): cards for that agent's tasks across all repos, running first. Card: task, repo name, state badge, status text, updated, scope, commits, runner indicator. Click a card to expand result and log tail (monospace, scrollable).
- Repos section: per repo name, path, branch, uncommitted/ahead badges, PLAN progress bar (done/total) with open items, HANDOFF status lines.
- Filters: show/hide finished (merged/cancelled) tasks, filter by repo. Remember choices in localStorage (wrapped in try/catch).
- Polls `/api/state` every 3 s; on fetch error shows "server offline" and keeps the last data. `?sample=1` loads `dashboard-sample.json` instead (for offline preview).
- Works in light and dark (`prefers-color-scheme`), responsive down to 375px, no external requests at all.
