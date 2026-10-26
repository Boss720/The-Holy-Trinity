# GUI step 2: action API and first buttons (contract)

Source: build order step 2 in docs/recommendations-gui.md and the "Action API" section of docs/reco/gui-foundation.md. Two workers, disjoint files.

## Server: POST /api/action

Request: `POST /api/action`, `Content-Type: application/json`, body at most 8 KB:
`{ "action": "cancel"|"merge"|"review-task"|"open-folder", "repo": "<repoPath from /api/state>", "task": "<task>", "confirm": true|false }`
Reply 202 `{ "job": "<id>", "command": "<display string>" }`. Errors: 400 bad JSON/unknown action/bad task name, 401 missing or wrong token, 403 bad Origin/Host/non-loopback, 404 unknown repo or task, 409 job already running for that repo+task, 412 destructive action without `confirm:true`, 413 body too large, 415 wrong content type, 429 too many running jobs (limit 4). Error body `{ "error": "<text>" }`.

Checks, in order: loopback RemoteEndPoint + Host `localhost:<port>` (same as today; count blocked ones), `Origin` header must equal `http://localhost:<port>`, header `X-Trinity-Token` must equal the server token (compare in constant time). The token is 32 random bytes hex, made at server start, injected into the served HTML by replacing the literal `__TRINITY_TOKEN__` in `<meta name="trinity-token" content="__TRINITY_TOKEN__">` (the sample route serves the file untouched). It is never logged and never in /api/state.

Allowlist, each is ONE child process started with an argument array (never a shell string), cwd = the repo main checkout, stdout+stderr to a job file:
- `cancel`  -> `powershell -NoProfile -ExecutionPolicy Bypass -File <repo>\scripts\trinity.ps1 cancel <task>`; requires confirm. Never passes -Force.
- `merge`   -> `... trinity.ps1 merge <task> -Yes`; requires confirm.
- `review-task` -> `... trinity.ps1 review --base main` run with cwd = the task's worktree (path taken from the board / state, never from the request); read-only, no confirm.
- `open-folder` -> `explorer.exe <task worktree path>` (path from state; must exist and sit in the repo's `.worktrees` sibling folder); no output needed, the reply still returns a job that finishes at once.
Validation: `repo` must be one of the repo paths in the current snapshot (exact, case-insensitive); `task` must match the board task-name rule already used by trinity (reuse it) AND exist in that repo's tasks; the task state must allow the action (cancel: not merged/cancelled; merge: state done; review-task and open-folder: has a worktree/branch).
`command` in the reply is the CLI text a user could paste, e.g. `trinity merge <task> -Yes`.

Jobs: id = 12 random hex. Output file `<repo>\.codex-out\jobs\<id>.txt` (create dir; keep newest 50 jobs, delete older files). `GET /api/job?id=<id>` -> `{ "id", "action", "task", "state": "running"|"done"|"failed", "exitCode": int|null, "output": "<last 64 KB, ASCII-safe>", "command": "..." }`; id must match `^[0-9a-f]{12}$` else 400; unknown id 404. GET /api/job goes through the same loopback/Host check; it does not need the token.
Every action request (accepted or refused after auth) appends one line to `<trinity home>\actions.log`: ISO time, action, repo, task, result (job id or error code), exit code when the job ends. Never prompt text, never the token. Keep under 512 KB like dashboard-errors.log.
The main loop is single-threaded: starting a job must not block (async Start-Process, poll process state in /api/job). Job processes must be killed on server shutdown.
State: `/api/state` `server` gains `actionsEnabled: true`.

## Page: buttons

- Read `<meta name="trinity-token">` once. Send it as `X-Trinity-Token` on POST /api/action. If the meta is missing, still the literal `__TRINITY_TOKEN__`, or `server.actionsEnabled` is not true, hide all action buttons (old server, or opened from file).
- Task detail (existing expanded task) gets an action bar: Merge (only state done), Review (has branch), Cancel (not merged/cancelled), Open folder (has worktree), Copy branch. Inbox rows get inline Merge (done-unmerged) and Cancel (failed/runner-dead) buttons acting on that task.
- Destructive (Merge, Cancel): a confirm dialog that shows the exact command text and requires a click on "Run"; only then send `confirm:true`. Non-destructive actions send `confirm:false`. Every action control has a "Show command" copy button (existing copy-command buttons stay).
- Job toast (bottom right, stackable, dismissible): title `<action> <task>`, live output (monospace, last lines, auto-scroll), state chip running/done/failed with exit code. Poll `GET /api/job?id=` every 1 s while running (single-flight; stops at done/failed; pauses when the tab is hidden). Toast survives view switches. After a job ends, trigger an immediate state refresh.
- API errors (401/403/409/412/429...) show in the toast as red text with the server's `error` message; never fail silently. Buttons disable while a job for the same task runs.
- Keyboard: real `<button>`s, toast is `role="status"`, confirm dialog traps focus and Esc closes it. No Space/x shortcuts, no swipe-to-merge.
- Vanilla JS, no CDN, light + dark, 375 px. Add the meta tag `<meta name="trinity-token" content="__TRINITY_TOKEN__">` to the page head.
- dashboard-sample.json: set `server.actionsEnabled: true` so the sample route shows the buttons (they fail with an error toast there, which is fine for checking layout).
