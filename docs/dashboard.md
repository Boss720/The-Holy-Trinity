# Dashboard spec

One local page that shows what Claude, Codex and Antigravity are doing across every repo that uses trinity:
tasks, the model each agent runs, token use, and the agents' own chats (including Claude subagents).

## Pieces and owners

| File | Owner | What |
|---|---|---|
| `scripts/dashboard.ps1` | codex | Read-only data collector + localhost HTTP server |
| `scripts/dashboard.html` | antigravity | Single-file UI (inline CSS/JS, no CDN, no build) |
| `scripts/dashboard-sample.json` | antigravity | Sample state matching the contract below, for previewing the UI offline |
| `scripts/trinity.ps1`, `scripts/lib/board.ps1` | claude | `trinity dashboard`, `trinity track`, repo registry, runner metadata, `Get-AgentAvailability` |
| `tests/` | codex (collector cases), claude (harness, fakes) | Self-test |

## Repo registry

`%USERPROFILE%\.trinity\repos.txt`: one absolute repo root per line (main checkout), written by `trinity init` and `trinity setup`. `TRINITY_HOME` overrides the `.trinity` folder (the self-test sets it so it never touches the real registry). Missing or stale lines (path gone, not a git repo) are skipped silently. The repo the dashboard is started from is always included even if not listed.

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
  - session: <claude session id>       (optional; claude tasks from `trinity track` inside a Claude session)
  - status: <text>
  ```
  Status text examples: `started 2026-10-25 08:43`, `running 2026-10-25 08:43`, `done (1 commits) 2026-10-25 08:55`, `done, no commits 2026-...`, `failed (exit 3) 2026-...`, `merged 2026-...`, `cancelled 2026-...`, `done: <summary> 2026-...` (claude), `waiting for claude session 2026-...`, `working: <note> 2026-...` (claude tracked).
  Parse `- key: value` lines generically; unknown keys are ignored.
- Out dir: `<main>\.codex-out\`:
  - `result-<task>.md` (agent's final summary), `log-<task>.txt` (agent log), `pid-<task>.txt` (runner PID while it runs; deleted when finished), `review-<task>.txt`, `deferred-<task>.txt`.
  - `meta-<task>.json` (runner metadata, see below). Older tasks have none.
  - `agy-<task>.log` (Antigravity CLI log of that run; the runner passes `agy --log-file`). Older tasks have none.
- `PLAN.md` in the main checkout: lines `- [x] ...` and `- [ ] ...`.
- `HANDOFF.md`: the bullet lines under `## Status`.

### Runner metadata: `meta-<task>.json`

Written by the trinity runner for headless tasks (codex, antigravity). UTF-8, one JSON object:

```json
{
  "agent": "antigravity",
  "started": "2026-10-25T10:00:03",
  "finished": "2026-10-25T10:05:12",
  "exitCode": 0,
  "model": "Gemini 3.8 Flash (High)",
  "effort": "",
  "sessionId": "c8b55abe-5be3-4cac-aecf-d083281b63bd",
  "durationSec": 309.4,
  "tokens": { "input": 24221, "cached": 0, "output": 1993, "reasoning": 1867, "total": 26214 }
}
```

Only `agent` and `started` exist while the task runs (written when the runner starts). The rest is added when it finishes; any field can be missing or empty. Collector rule: values from the meta file win over values discovered from logs and transcripts, except `tokens`, `toolCalls` and `lastActivity` of a running task (the transcript is fresher).

### Agent homes (read-only)

| Agent | Home | Override |
|---|---|---|
| Codex | `%USERPROFILE%\.codex` | `CODEX_HOME` |
| Antigravity | `%USERPROFILE%\.gemini\antigravity-cli` | `TRINITY_AGY_HOME` |
| Claude | `%USERPROFILE%\.claude` | `CLAUDE_CONFIG_DIR` |

### Codex

- Task log header (`log-<task>.txt`, first 8 KB): lines `model: gpt-6-luna`, `reasoning effort: high`, `session id: <uuid>`, `provider: openai`.
- Default model: `<codex home>\config.toml` top-level `model = "..."` and `model_reasoning_effort = "..."`.
- Transcript ("rollout"): `<codex home>\sessions\YYYY\MM\DD\rollout-<stamp>-<sessionId>.jsonl`. The date folder is the session start date; find the file by the session id suffix (search the start date's folder first, then the day before and after, then a bounded recursive search) and cache path by session id. One JSON object per line, `{ "timestamp", "type", "payload" }`:
  - `type: response_item`, `payload.type: message`, `payload.role: user|assistant|developer`, `payload.content[]` with `{ type: input_text|output_text, text }`. `developer` messages are system instructions: skip them.
  - `payload.type: custom_tool_call` (`name`, `input`, `call_id`) and `function_call` (`name`, `arguments`, `call_id`): one tool call each.
  - `payload.type: custom_tool_call_output` / `function_call_output` (`call_id`, `output`: string, or array of `{ type, text }`).
  - `payload.type: reasoning`: encrypted; use `payload.summary[].text` if present, else skip.
  - `type: event_msg`, `payload.type: token_count`: `payload.info.total_token_usage { input_tokens, cached_input_tokens, output_tokens, reasoning_output_tokens, total_tokens }`, `payload.info.model_context_window`, `payload.rate_limits.primary|secondary { used_percent, window_minutes, resets_at }` (`resets_at` = unix seconds). The last one in the file is current.
  - `type: event_msg`, `payload.type: task_complete`: `duration_ms`, `last_agent_message`.
  - `type: session_meta`: `payload.session_id`, `payload.cli_version`, `payload.parent_thread_id` (set on Codex subagent sessions: their parent is the task's session).
  - Skip every other type (`world_state`, `turn_context`, `token_usage_record`, `item_completed`, ...).

### Antigravity

- `agy-<task>.log`: the model label from `label="Gemini 3.8 Flash (High)"`, the conversation id from `cascade_id:<uuid>`, the workspace from `workspaceDirs=[<dir> ...]`.
- Tasks without `agy-<task>.log` (older runs): optionally search `<agy home>\log\cli-*.log` (newest first, at most 50 files, first 64 KB each) for a `workspaceDirs=[` line that contains the task's worktree path; cache the result.
- Tasks with neither `agy-<task>.log` nor a session in meta (runs before meta existed): the conversation is the one whose transcript's first `USER_INPUT` line mentions `task-<task>.md`. Scan `<agy home>\brain\*\.system_generated\logs\transcript.jsonl`, newest first, at most 200 folders, first 16 KB each, and require the match to be the task file of this repo's `.codex-out` folder (path compare is case-insensitive, `\` and `/` equal; a URL-encoded or `file:///` form also counts). Cache task -> conversation id (also negative results, for 60 s).
- Model of such a task: the first `USER_INPUT` says ``setting `Model Selection` from <old> to <model>.``; use `<model>`. Else `label="..."` in the first `<agy home>\log\cli-*.log` (newest first, at most 50, first 256 KB each) that contains the conversation id; cache it.
- Default model: `label="..."` in the newest `<agy home>\log\cli-*.log` that has one.
- Transcript: `<agy home>\brain\<conversationId>\.system_generated\logs\transcript.jsonl`, one object per line with `step_index`, `source` (`USER_EXPLICIT|MODEL|SYSTEM`), `type`, `status`, `created_at`:
  - `USER_INPUT`: `content`.
  - `PLANNER_RESPONSE`: `thinking`, `content` (may be absent), `tool_calls[] { name, args }`, `input_tokens`, `output_tokens`, `cache_read_tokens`.
  - `GENERIC`: `content` (a tool result).
  - `SYSTEM_MESSAGE`: `content`.

### Claude

- Project folder per checkout: `<claude home>\projects\<slug>\`, where `<slug>` is the absolute checkout path with every character outside `[A-Za-z0-9]` replaced by `-` (`D:\AI\x y` -> `D--AI-x-y`). Look in the main checkout's slug and the slug of every claude task worktree of that repo.
- Session: `<slug>\<sessionId>.jsonl`, one object per line. Use only:
  - `type: assistant`: `message.model` (ignore `<synthetic>`), `message.id`, `message.content[]` (`text`, `tool_use { name, input }`, `thinking { thinking }`), `message.usage { input_tokens, cache_creation_input_tokens, cache_read_input_tokens, output_tokens }`, `effort`, `timestamp`. One API message can span several lines with the same `message.id`: count its usage once.
  - `type: user`: `message.content` (string, or array of `text` / `tool_result { content }`), `isMeta` (skip when true), `timestamp`.
  - `type: custom-title`: `customTitle` (the session title; last one wins).
  - every line: `gitBranch`, `cwd`, `timestamp`.
  - Skip all other types. Some lines (`api-request-blob`, ...) are huge: skip any line over 1 MB before parsing it.
- Subagents: `<slug>\<sessionId>\subagents\agent-<agentId>.jsonl` (same line format) and `agent-<agentId>.meta.json`: `{ agentType, description, model, finished, spawnDepth, toolUseId }`.

## Agent availability

`Get-AgentAvailability` in `scripts/lib/board.ps1` (dot-source it) returns, per agent, `@{ available; detail; exe }`:
- codex: CLI found and `codex login status` exits 0.
- antigravity: `agy.exe` found.
- claude: Claude Code CLI found and `claude auth status` exits 0 (headless use for reviews; the desktop app can be in use while this is false).
- `TRINITY_DISABLE` (comma list, e.g. `codex`) marks an agent unavailable even when installed.

It starts up to two short processes: cache its result for 60 s in the server.

## JSON contract: `GET /api/state`

```json
{
  "generated": "2026-10-25T09:30:05",
  "availability": {
    "claude":      { "available": false, "detail": "not logged in (run: claude auth login)", "model": "claude-opus-5-5", "effort": "max" },
    "codex":       { "available": true,  "detail": "Logged in using ChatGPT", "model": "gpt-6-luna", "effort": "high" },
    "antigravity": { "available": true,  "detail": "ok", "model": "Gemini 3.8 Flash (High)", "effort": "" }
  },
  "agents": {
    "claude":      { "running": 1, "done": 3, "failed": 0, "total": 4, "models": ["claude-opus-5-5"] },
    "codex":       { "running": 0, "done": 5, "failed": 1, "total": 6, "models": [] },
    "antigravity": { "running": 1, "done": 1, "failed": 0, "total": 2, "models": ["Gemini 3.8 Flash (High)"] }
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
          "logTail": "last 15 lines of log-<task>.txt, or empty",
          "model": "gpt-6-luna",
          "effort": "high",
          "sessionId": "01a1727b-b5bc-7432-9ce3-31c53b4e4dd2",
          "started": "2026-10-25T08:43:10",
          "finished": "2026-10-25T08:55:02",
          "durationSec": 712,
          "lastActivity": "2026-10-25T08:55:01",
          "tokens": { "input": 812345, "cached": 700000, "output": 15000, "reasoning": 6000, "total": 827345 },
          "contextWindow": 258400,
          "toolCalls": 42,
          "rateLimits": [ { "name": "primary", "usedPercent": 12.5, "windowMinutes": 300, "resetsAt": "2026-10-25T13:00:00" } ],
          "chat": "codex:01a1727b-b5bc-7432-9ce3-31c53b4e4dd2",
          "subChats": [ { "chat": "codex:<uuid>", "title": "subagent: reviewer", "model": "gpt-6-luna" } ],
          "contextUsed": 61234,
          "steps": 40,
          "thinkingSteps": 12,
          "toolBreakdown": [ { "name": "read_file", "count": 18 }, { "name": "run_command", "count": 9 } ],
          "lastTool": "run_command",
          "filesTouched": ["scripts/dashboard.html"],
          "backgroundTasks": 2
        }
      ],
      "claudeSessions": [
        {
          "id": "b326318e-a0a4-47ae-a2d6-9e3a0699613d",
          "title": "Dashboard detail and no-Codex mode",
          "model": "claude-opus-5-5",
          "effort": "max",
          "branch": "main",
          "cwd": "D:\\AI\\projects\\Dev\\Projects\\Holy trinity",
          "started": "2026-10-25T07:02:11",
          "lastActivity": "2026-10-25T10:12:40",
          "active": true,
          "contextTokens": 143210,
          "task": "dash-detail",
          "chat": "claude:D--AI-projects-Dev-Projects-Holy-trinity:b326318e-a0a4-47ae-a2d6-9e3a0699613d",
          "subagents": [
            {
              "id": "a03501a34a3d4bc5c",
              "description": "Codex: GIF stripping",
              "type": "general-purpose",
              "model": "haiku",
              "finished": true,
              "active": false,
              "lastActivity": "2026-10-25T08:31:02",
              "chat": "claude:D--AI-projects-Dev-Projects-Holy-trinity:b326318e-a0a4-47ae-a2d6-9e3a0699613d:a03501a34a3d4bc5c"
            }
          ]
        }
      ]
    }
  ]
}
```

Rules:
- `state` is one of `running`, `done`, `failed`, `merged`, `cancelled`, `waiting`, `other`. Derivation: runner pid alive or status starts with `started`/`running`/`working` -> `running`; `failed` -> `failed`; `merged` -> `merged`; `cancelled` -> `cancelled`; `done` -> `done`; `waiting` -> `waiting`; else `other`.
- `agents` counts tasks across all repos: `running` = state running, `done` = done + merged, `failed` = failed, `total` = all tasks. Always include all three agent keys. `models` = distinct non-empty `model` of running tasks, plus (claude) of active Claude sessions.
- `availability`: always all three keys; `model`/`effort` = the agent's default (Codex `config.toml`, Antigravity newest CLI log label, Claude model and effort of the newest session seen in any repo); empty string when unknown.
- `updated` = trailing `yyyy-MM-dd HH:mm` of the status, or empty.
- `commits` = `git rev-list --count main..<branch>` if the branch exists, else 0.
- `uncommitted` = number of `git status --porcelain` lines in the main checkout; `ahead` = commits ahead of the upstream, 0 if none.
- Task detail fields (`model` ... `subChats`) are always present; empty string, 0, `null` (`tokens`, `contextWindow`, `durationSec`) or `[]` when unknown. Times are local ISO `yyyy-MM-ddTHH:mm:ss`.
  - `durationSec`: `finished - started`; for a running task, `now - started`.
  - `tokens` (Codex): last `token_count` total. (Antigravity): sum over `PLANNER_RESPONSE` steps (`input` = input_tokens, `cached` = cache_read_tokens, `output` = output_tokens, `reasoning` 0), unless meta has `tokens`. (Claude tasks): null.
  - `toolCalls`: number of tool-call records in the transcript (Codex `custom_tool_call` + `function_call`; Antigravity `tool_calls` entries).
  - `lastActivity`: last record timestamp in the transcript, else transcript (or log) file write time.
  - `rateLimits`: Codex only, from the last `token_count`; `[]` otherwise.
  - `chat`: chat key (below) when a transcript file exists, else empty. Claude tasks with `session:` link to that session's key.
  - `subChats`: Codex sessions whose `session_meta.parent_thread_id` is this task's session id (look in the same date folder; cache).
  - Detail v3 fields (all agents with a transcript; Claude tasks: defaults). Always present: `contextUsed` 0, `steps` 0, `thinkingSteps` 0, `toolBreakdown` `[]`, `lastTool` "", `filesTouched` `[]`, `backgroundTasks` 0 when unknown.
    - `contextUsed`: tokens in the model's context at the last model call. Codex: `info.last_token_usage.input_tokens` of the last `token_count`. Antigravity: `input_tokens + cache_read_tokens` of the last `PLANNER_RESPONSE`.
    - `steps`: model turns. Codex: `token_count` events with `info` non-null. Antigravity: `PLANNER_RESPONSE` records.
    - `thinkingSteps`: Codex: `response_item` of payload type `reasoning`. Antigravity: `PLANNER_RESPONSE` with non-empty `thinking`.
    - `toolBreakdown`: tool name -> call count, sorted by count descending then name, at most 8 entries. Codex: `payload.name` of `custom_tool_call`/`function_call`. Antigravity: `tool_calls[].name`.
    - `lastTool`: name of the last tool call.
    - `filesTouched`: distinct file paths the agent wrote, in first-seen order, at most 20, made relative to the task worktree when under it (forward slashes). Antigravity: `args.Path` or `args.TargetFile` (args may be an object or a JSON string) of `write_file`, `write_to_file`, `edit_file`, `replace_file_content`, `multi_replace_file_content`. Codex: header lines (`*** Add File: `, `*** Update File: `, `*** Delete File: ` at a line start) of an `apply_patch` call, either direct or inside an `exec` call's script as `apply_patch("...")` (a JS string: newlines as `\n`, backslashes doubled). Paths ending in `/` are dropped.
    - `backgroundTasks`: Antigravity `manage_task` calls; Codex: `subChats` count.
    - Antigravity `started`/`finished`/`durationSec` when meta lacks them: first and last transcript `created_at` (UTC `Z` converted to local time); `finished` only when the task is not running.
- `claudeSessions`: up to 5 newest sessions per repo, written within the last 7 days, newest first. `title` = last `custom-title`, else the first non-meta user text (one line, max 100 chars). `active` = last write within 120 s. `contextTokens` = input + cache_creation + cache_read of the last assistant message. `task` = name of the board task whose `session:` is this id, else empty. `subagents`: up to 20 newest; `model` from the meta file, else the subagent's last assistant model; `active` = not finished and last write within 120 s.
- Tasks sorted: running first, then by `updated` descending. Repos sorted by name.
- Strings are plain text; the UI must escape them (they come from agent output).

## Chat contract: `GET /api/chat?id=<key>`

Keys (validate with these exact shapes; anything else -> 400):
- `codex:<uuid>`, `agy:<uuid>` (uuid = 8-4-4-4-12 hex)
- `claude:<slug>:<sessionUuid>` and `claude:<slug>:<sessionUuid>:<agentId>` (slug `[A-Za-z0-9-]{1,200}`, agentId `[A-Za-z0-9_-]{1,64}`)

The file is resolved only inside the agent home named above (never from a path in the request). Not found -> 404.

```json
{
  "id": "agy:c8b55abe-5be3-4cac-aecf-d083281b63bd",
  "agent": "antigravity",
  "title": "dash-ui",
  "model": "Gemini 3.8 Flash (High)",
  "updated": "2026-10-25T10:05:12",
  "truncated": false,
  "messages": [
    { "at": "2026-10-25T10:00:03", "role": "user", "name": "", "text": "Read the task file ..." },
    { "at": "2026-10-25T10:00:09", "role": "thinking", "name": "", "text": "..." },
    { "at": "2026-10-25T10:00:09", "role": "tool", "name": "view_file", "text": "{\"AbsolutePath\":\"...\"}" },
    { "at": "2026-10-25T10:00:10", "role": "result", "name": "", "text": "..." },
    { "at": "2026-10-25T10:05:12", "role": "assistant", "name": "", "text": "Done: ..." }
  ]
}
```

- `role`: `user`, `assistant`, `thinking`, `tool` (name + compact JSON or raw input), `result` (tool output), `system`.
- `title`: task name (Codex/Antigravity task chats), session title (Claude), subagent description (Claude subagent).
- Mapping: Codex as listed under Codex (user/assistant messages, tool calls, outputs, reasoning summaries); Antigravity `USER_INPUT` -> user, `PLANNER_RESPONSE` -> thinking + assistant (`content`) + one tool per `tool_calls` entry, `GENERIC` -> result, `SYSTEM_MESSAGE` -> system; Claude `user` text -> user (drop `<system-reminder>...</system-reminder>` blocks; skip if empty), `tool_result` -> result, `assistant` `text`/`tool_use`/`thinking` -> assistant/tool/thinking.
- Limits: read at most the last 4 MB of the file; keep the last 300 messages; `text` max 4000 chars (`tool`/`result` max 1500), cut with `...`. `truncated` = anything was dropped.
- Redaction (chat text, `result`, `logTail`): replace matches of `sk-[A-Za-z0-9_-]{16,}`, `gh[pousr]_[A-Za-z0-9]{20,}`, `xox[abprs]-[A-Za-z0-9-]{10,}`, `AKIA[0-9A-Z]{16}`, `AIza[0-9A-Za-z_-]{35}`, `(?i)bearer\s+[A-Za-z0-9._~+/=-]{20,}` with `[redacted]`.

## Server

- `powershell -File scripts\dashboard.ps1 [-Port 7777]`: `System.Net.HttpListener` on `http://localhost:<port>/` only (never `+` or `*`). Routes: `GET /` -> `dashboard.html` next to the script; `GET /api/state` -> state JSON; `GET /api/chat?id=` -> chat JSON; `GET /dashboard-sample.json` -> the sample file (for `?sample=1`); anything else 404. Read-only: no POST, no actions.
- Loopback only: a `localhost` prefix makes http.sys listen on every interface and match on the `Host` header alone, so requests whose remote address is not loopback (IPv4-mapped IPv6 included) get 403. Requests whose `Host` header is not `localhost:<port>` also get 403 (DNS-rebinding guard; http.sys itself answers 400 for `127.0.0.1:<port>`, and a `127.0.0.1` prefix would need a URL ACL). Every response sends `X-Content-Type-Options: nosniff`; JSON responses `Content-Type: application/json; charset=utf-8` and `Cache-Control: no-store`.
- JSON is ASCII-only (non-ASCII escaped as `\uXXXX`) so `-Once` output survives any console code page. Result and log files are read as UTF-8, at most 64 KB (head for results, tail for logs), with ReadWrite sharing so a running agent's log is readable.
- Git cost: three git calls per repo (`rev-parse`, `status --porcelain=v2 --branch`, `for-each-ref` with `ahead-behind:main`, falling back to `rev-list` per branch on git older than 2.41). About 0.25 s per poll for one repo.
- Transcripts can be many MB. `/api/state` never parses a whole transcript per poll: keep a per-file cache in the server process (path -> length, write time, byte offset, counters, last values) and read only the bytes appended since the last poll; read heads and tails for Claude sessions, only for the 5 newest session files by write time, and reuse a session's summary while its length and write time are unchanged (`active` is recomputed each poll). Registry paths are normalized and deduplicated before any repo is collected. Parse JSON lines with `System.Web.Script.Serialization.JavaScriptSerializer` (`MaxJsonLength` = max int), not `ConvertFrom-Json` (too slow).
- Shared snapshot: one background runspace builds the state; `/api/state` never builds it on the request thread. Every client gets the same JSON bytes, so N open tabs cost one collection, not N.
  - The collector rebuilds when the snapshot is older than `-RefreshSeconds` (default 3) and a `/api/state` request arrived in the last 30 s. With no clients it idles (no git calls, no transcript reads).
  - A request with a snapshot younger than 15 s gets it at once. An older or missing snapshot (cold start, or first request after idle): the request waits for the next snapshot, at most 60 s. If the wait ends (timeout, or a collection error newer than the request) and an older snapshot exists, that one is served with 200 (its age is in `X-Snapshot-Age-Ms`). With no snapshot at all: 500 after a collection error, otherwise 503 with `Retry-After: 5`. After a failed collection the collector pauses 2 s before retrying.
  - Header `X-Snapshot-Age-Ms` on every `/api/state` reply. A failed collection keeps the last good snapshot and goes to `dashboard-errors.log` (route `collector`); with no snapshot at all the request gets 500.
  - `/api/chat` and static files stay on the request thread and are never blocked by a collection in progress.
  - A collection must stay under ~1 s for 10 repos with 20 tasks each once caches are warm; the first may take longer. `-Once` keeps building state inline.
- `-Once` switch: print the state JSON to stdout and exit (used by tests and `trinity dashboard -Json`). `-Chat <key>`: print one chat JSON and exit (exit 2 for a malformed key, 3 when not found).
- Clean shutdown on Ctrl+C / process stop; on startup, if the port is busy, exit 2 with a clear message.

## UI

- Header: overall counts per agent with a colored identity per agent (Claude, Codex, Antigravity), last refresh time, a "live" indicator. Per agent also: availability dot (available / unavailable, with `detail` as tooltip and visible text when unavailable), default model (`gpt-6-luna · high`), and the models currently running (`agents.<a>.models`).
- Three lanes (Claude | Codex | Antigravity): cards for that agent's tasks across all repos, running first. Card: task, repo name, state badge, status text, updated, scope, commits, runner indicator, model chip, duration (ticks live for running tasks from `started`), token total (`26.2k tok`), tool calls, last activity (`12s ago`). Click a card to expand: result and log tail (monospace, scrollable), token breakdown (input / cached / output / reasoning, context window use), Codex rate limits (bar per limit with `resets HH:MM`), session id, sub-chats, and an "Open chat" button when `chat` is set.
- Unavailable agent: its lane shows a muted banner at the top, e.g. `Codex unavailable: not logged in. New Codex work routes to Antigravity.` (Antigravity: `routes to Codex`.) The lane still lists older tasks.
- Claude lane: a "Sessions" group above the tracked tasks: one card per `claudeSessions` entry across repos (title, repo, model + effort chip, pulsing dot when `active`, context tokens, last activity, branch, linked task) with its subagents nested (description, type, model, running/finished badge, last activity, "chat" button).
- Chat panel: opens from any chat button. Right-side drawer (full screen under 600px). Header: title, agent color, model, updated, live toggle (on by default when the source is running or active: re-fetch `/api/chat` every 3 s), close (button and Esc). Body: messages styled per role; `tool` and `result` monospace and collapsed to 3 lines with expand; `thinking` muted and collapsed; toggles to hide tools / thinking (remembered in localStorage). Stays scrolled to the bottom unless the user scrolled up; then a "jump to latest" button. Show fetch errors inline.
- Repos section: per repo name, path, branch, uncommitted/ahead badges, PLAN progress bar (done/total) with open items, HANDOFF status lines.
- Filters: show/hide finished (merged/cancelled) tasks, filter by repo. Remember choices in localStorage (wrapped in try/catch).
- Polls `/api/state` with at most one request in flight: the next poll starts 3 s after the last one finished (at least as long as that reply took, max 30 s; after an error the delay doubles up to 30 s). No polling while the tab is hidden; poll at once when it becomes visible. The chat drawer's live re-fetch also skips a tick while a fetch is pending. Until the first reply the header shows "connecting" and the lanes a loading placeholder, not zero counts. On fetch error shows "server offline" and keeps the last data. `?sample=1` loads `dashboard-sample.json` instead (for offline preview); in sample mode chats come from its top-level `sampleChats` object (chat key -> chat JSON) instead of `/api/chat`.
- All agent text is set with `textContent` (never `innerHTML`). Works in light and dark (`prefers-color-scheme`), responsive down to 375px, no external requests at all.
