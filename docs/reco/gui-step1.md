# GUI step 1: read-only foundations (contract)

Source: build order step 1 in `docs/recommendations-gui.md`. Read-only: no POST, no actions yet.
Two workers, disjoint files. Both follow this contract exactly so they merge independently.

## State additions (`/api/state` JSON, top level, all new fields additive)

```
server: {
  startedAt:        ISO local time the dashboard server process started
  scriptHash:       first 12 hex of SHA256 of scripts/dashboard.ps1 when the server started
  scriptHashOnDisk: same hash computed now (differs => "server outdated")
  listenerScope:    "loopback"
  blockedRemoteCount: int, requests refused by the loopback/Host check since start
  collectMs:        int, duration of the last snapshot build
  avgCollectMs:     int, mean of the last 10 builds
}
attention: [   // all repos, newest first
  { repo: <repo name>, repoPath: <repo path>, task: <task>, agent: <agent>,
    reason: "failed" | "done-unmerged" | "runner-dead",
    detail: <short human text>, since: <ISO time, task updated> }
]
health: [      // read-only doctor rows
  { id: <kebab id>, label: <text>, status: "ok" | "warn" | "fail", detail: <text> }
]
```

Health rows (server side, cheap checks only, no network):
`dashboard-server` (collectMs under 1000 = ok, under 3000 = warn, else fail),
`listener-loopback` (ok, detail "loopback only, N blocked"),
`server-outdated` (ok when hashes equal, warn otherwise),
`board-readable` (ok when every repo board parsed),
`hooks-enabled` (per repo: git config core.hooksPath ends with .githooks),
`agents` (one row per agent: ok when available, warn otherwise, detail = availability detail).

Attention rules: task.state `failed` -> reason failed; `done` (not merged) -> done-unmerged;
`running` with runnerAlive false -> runner-dead. Merged/cancelled never appear.

The reply to `GET /api/state` already carries header `X-Snapshot-Age-Ms`. Page uses it for the data-age chip.

## Page (scripts/dashboard.html)

- Views switched by URL hash, default `#inbox`: `#inbox`, `#tasks` (the existing lanes UI, unchanged), `#health`.
  `#task=<repo name>/<task>` opens the existing task detail for that task (and shows the Tasks view behind it).
  Unknown hash = inbox. Back/forward works. A view bar sits under the header.
- Inbox: groups "Needs attention (N)" (from `attention[]`, reason chip, agent, repo/task, detail, relative time, click opens `#task=`) and "Running (N)" (running tasks across repos). Empty state "Nothing needs you". Ignores any repo filter.
- Health: table of `health[]` rows with status dot (ok green, warn amber, fail red) + label + detail. Read-only, no buttons.
- Header data-age chip: "updated 2 s ago, collect 0.8 s" from `X-Snapshot-Age-Ms` and `server.collectMs`; spinner while a poll is in flight; turns amber past 15 s.
- Banner when `server.scriptHash != server.scriptHashOnDisk`: "Server outdated, restart to load the latest code".
- Existing CONNECTING / LIVE / OFFLINE behavior stays. Missing new fields (old server) must not break the page: hide those parts.
- Vanilla JS, no CDN, light + dark, works at 375 px, DOM updates keyed so focus/scroll do not reset on poll (Inbox and Health at least).
- scripts/dashboard-sample.json gains the new fields with plausible sample data (it feeds the page when opened from the sample route).
