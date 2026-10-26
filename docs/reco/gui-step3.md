# GUI step 3: Diff tab, Log tab, merge review with blockers (contract)

Source: build order step 3 in docs/recommendations-gui.md ("Task drawer tabs Diff and Log, Merge review screen with blockers and Dry run") and Top 13 items 3, 6, 7. Two workers, disjoint files. All new endpoints are read-only GET.

## Server: three GET endpoints (scripts/dashboard.ps1)

Common: same loopback + Host check as every route; no token needed (read-only); query `repo` must equal a repo path in the current snapshot (case-insensitive), `task` must match the board task-name rule and exist in that repo's tasks, else 400 (bad name) / 404 (unknown repo or task). Run git with the existing Invoke-GitRead helper (array args, never a shell string). Every field ASCII-safe like the other routes. A task without a branch gets 409 `{ "error": "task has no branch" }`. Replies are JSON; errors `{ "error": "<text>" }`. These run on the request thread, so every git call must be cheap and capped (no git gc, no fetch).

### GET /api/task/diff?repo=<path>&task=<name>
`{ "task", "branch", "base": "main", "files": [ { "path", "status": "A"|"M"|"D"|"R", "added": int, "deleted": int, "binary": bool } ], "stat": { "files": int, "added": int, "deleted": int }, "patch": "<unified diff of base...branch, three-dot>", "truncated": bool }`
Files from `git diff --numstat` + `--name-status` of `main...<branch>`. `patch` from `git diff main...<branch>`, capped at 200 KB (cut at a line boundary, set `truncated`). Binary files have `binary:true` and no hunk text.

### GET /api/task/log?repo=<path>&task=<name>&offset=<int>
Tail of the task's runner log: the same file the task state already reads for `logTail` (log-<task>.txt, or agy-<task>.log for Antigravity, under the repo's .codex-out). Reply `{ "size": int, "offset": int, "nextOffset": int, "text": "<up to 64 KB from offset>", "reset": bool, "exists": bool }`. `offset` omitted or negative = last 16 KB. If offset > size (log rotated/truncated) return the last 16 KB with `reset:true`. Read the file with FileShare.ReadWrite (the runner is still writing it). Control characters other than TAB/LF are returned as visible escapes like `\x1b`.

### GET /api/task/merge-check?repo=<path>&task=<name>   (the dry run)
`{ "task", "branch", "canMerge": bool, "blockers": [ { "id", "label", "severity": "block"|"warn", "detail" } ], "conflicts": [ "<path>" ], "scopeViolations": [ "<path>" ], "ahead": int, "behind": int, "mainHead": "<short sha>", "checkedAt": "<ISO>" }`
`canMerge` is true only when there is no `block` blocker. Blocker ids and rules:
- `not-done` (block): task state is not `done`.
- `runner-alive` (block): the runner process for the task is still alive.
- `no-commits` (block): branch has 0 commits ahead of main.
- `main-dirty` (block): main checkout has uncommitted changes (`git status --porcelain` non-empty), because trinity merge refuses a dirty main.
- `conflicts` (block): `git merge-tree --write-tree main <branch>` reports conflicts; list the conflicted paths in `conflicts`. If git is too old for --write-tree, emit `conflicts-unchecked` (warn) instead.
- `scope-violation` (block): files changed on the branch that match none of the task's scope globs (the board `scope` field, comma separated, `*` wildcard, forward slashes); list them in `scopeViolations`. Empty or unspecified scope = no check, no blocker.
- `behind-main` (warn): branch base is behind main (`behind` > 0); detail "re-review recommended".
No git write operation, no checkout, no merge-tree side effects on the working tree (`--write-tree` writes only objects; acceptable).

Tests (tests/run-tests.ps1, style of the existing dashboard HTTP cases, fixture repo with a real branch made with git inside the fixture): diff of a branch with an added and a modified file (files, stat, patch contains the added line); unknown repo 404; bad task name 400; branchless task 409; log tail with offset continuity (read, append to the file, read again from nextOffset gets only the new text) and a control character escaped; merge-check: a done task with a clean branch -> canMerge true; a task still running -> blocker `runner-alive`/`not-done`; dirty main -> `main-dirty`; a branch that conflicts with a change on main -> `conflicts` with the path; a branch touching a file outside its scope -> `scope-violation`. Keep added test time under 60 s.

## Page: tabs and merge review (scripts/dashboard.html)

- The expanded task detail gets tabs: Summary (today's content) | Diff | Log | Merge check. Tab state is per task, remembered while the task stays expanded; deep link `#task=<repo>/<task>&tab=diff|log|merge` opens that tab (the existing `#task=` link keeps working).
- Diff tab: fetch `/api/task/diff` when opened; header "N files, +A -D"; a file list (status chip, path, +/- counts); click a file to expand its hunk (split the returned `patch` by `diff --git` headers on the client); added lines green, removed red, hunk headers muted; a "truncated" notice; "Copy diff" button; binary files show "binary". Empty diff shows "No changes vs main".
- Log tab: fetch `/api/task/log` and poll with `nextOffset` every 2 s while the task is running and the tab is visible (single-flight; stop when the task is not running; pause while the tab is hidden), appending text; monospace, auto-scroll "Follow" toggle (off when the user scrolls up), search box that highlights matches, "Copy log" and "Clear view" buttons. Show `\xNN` escapes as returned. `exists:false` shows "No log file yet".
- Merge check tab and "Review merge" button: on done-unmerged tasks (task detail and Inbox rows) add a "Review merge" button that opens the Merge check tab (Inbox row: navigates to the task with `tab=merge`). The tab fetches `/api/task/merge-check` and shows blocker chips (red = block, amber = warn, green "No blockers" when empty) each with its detail, conflicted files and scope-violating files as lists, `ahead/behind` and main head, a "Dry run" button that re-runs the check and shows the time, and a Merge button that is disabled with the reason chips next to it while `canMerge` is false; when enabled it uses the existing Merge action with its confirm dialog. The inline Merge buttons from step 2 stay but become disabled-with-tooltip "see Review merge" is NOT required; keep them as they are.
- All fetch errors (404/409/400) show inside the tab as a red message with the server's `error` text; never blank.
- Single-flight fetches, no polling for Diff or Merge check (refresh on tab open and on the Dry run button).
- Vanilla JS, no CDN, light + dark, 375 px, keyboard operable tabs (`role="tablist"`, arrow keys), keyed DOM updates so a state poll does not reset the open tab or scroll.
- Do not add the string `__TRINITY_TOKEN__` anywhere else in the page (the server replaces every occurrence).
