# GUI step 4: dispatch form, single task (contract)

Source: build order step 4 in docs/recommendations-gui.md and wireframe (c) in docs/reco/gui-wireframes.md. Scope of this step: ONE task per submit with agent, task name, scope globs and prompt. NOT in this step: roles, model/effort, batch, plan-first, best-of-N, run-after, fix loop, schedule. Two workers, disjoint files (server: scripts/dashboard.ps1 + tests/run-tests.ps1; page: scripts/dashboard.html + scripts/dashboard-sample.json).

## Server

### GET /api/dispatch/check?repo=<path>&agent=<codex|antigravity|claude>&task=<name>&scope=<globs>
Read-only, no token, same loopback + Host checks. `repo` must equal a repo path in the snapshot (404 unknown). Reply 200 always (validation results are data):
`{ "taskOk": bool, "taskReason": "<text or empty>", "agentOk": bool, "agentReason": "...", "effectiveAgent": "<agent>", "rerouted": bool, "scopeOk": bool, "scopeReason": "...", "scopeNormalized": ["<glob>"], "overlaps": [ { "task", "agent", "state", "glob" } ], "command": "trinity dispatch <effective> <task> -Scope \"<globs>\" -PromptFile <file>", "canDispatch": bool }`
- Task name: board rule `^[a-z0-9][a-z0-9-]*$`, max 40 chars; not already a board entry in that repo (any state except cancelled), no existing branch `agent/*/<task>` in the repo (cheap `git for-each-ref`), no leftover worktree dir.
- Agent: availability from the snapshot's `availability` for that agent. Unavailable codex or antigravity -> `rerouted:true`, `effectiveAgent` is the other one (same rule as Select-Worker in scripts/trinity.ps1: reuse the logic or mirror it). `claude` is allowed only as "park a task" (worktree + task file, no headless run); say so in `agentReason`.
- Scope: comma separated, forward slashes, each glob non-empty, at most 20, no `..`, no absolute path, no drive letter, no `:` or control characters, no leading `/`. `scopeNormalized` lists them trimmed. Empty scope is allowed (`scopeOk` true, with reason "no scope: overlap not checked").
- Overlaps: compare against tasks in `running`/`working` state in the same repo (their board `scope`), using a conservative glob overlap (same literal prefix before the first `*` on either side, or one glob matching the other as a path). Return each overlapping task. Overlap is a warning, not a block (`canDispatch` stays true).
- `canDispatch` = taskOk && agentOk && scopeOk. The command line text uses the effective agent and is for display only; never executed from this string.

### POST /api/action with `action: "dispatch"`
Add to the existing allowlist (same guards as step 2: loopback + Host, exact Origin, X-Trinity-Token; the 8 KB JSON body limit is raised to 64 KB for this action only; `confirm:true` required). Args: `{ repo, agent, task, scope, prompt }`.
- Re-run the same validation as /api/dispatch/check on the server; refuse with 400 and the reason when `canDispatch` is false. Prompt: non-empty after trim, at most 32 KB, any text.
- Write the prompt as UTF-8 (no BOM) to `<repo>\.codex-out\prompt-<task>.md` (create the dir if missing; refuse to overwrite an existing file of that name), then run the repo's `scripts\trinity.ps1 dispatch <agent> <task> -Scope "<globs>" -PromptFile <that file>` as an async job through the existing Start-ActionProcess / job machinery (array args, never a shell string; prompt text must never appear on a command line). Resolve trinity.ps1 as the review-task action does (repo copy, fallback to the dashboard's own toolkit copy).
- The job output is the dispatch output; `GET /api/job?id=` works as before. Log to actions.log with action, repo, task, agent (never the prompt text, never the token).
- The max-4-jobs rule and existing error codes stay.

### Tests (tests/run-tests.ps1, existing dashboard HTTP style, fake agents, never start a real codex/agy)
check: valid new name -> canDispatch true; bad name; duplicate board name; unknown repo 404; scope with `..` and absolute path rejected; overlap with a running task reported; unavailable agent rerouted (use the existing availability fixture/env switch such as TRINITY_DISABLE). Action: missing token 401, missing confirm 400, bad Origin 403, invalid task 400, and one happy path with a fake agent (the existing action API test shows how a fake agent/job is run) that proves the prompt file is written byte-exact (include non-ASCII and a leading `-Force` line) and the job completes. Keep added test time under 60 s.

## Page (scripts/dashboard.html)
- A "Dispatch" button in the header bar (next to the data-age chip) opens a modal "Dispatch new task". Hidden/disabled with tooltip when actions are disabled or in sample mode (reuse areActionsEnabled).
- Fields: Repo select (tracked repos, default the current filter or the first), Agent radio (Codex, Antigravity, Claude park) each with an availability chip from `availability`, Task name input, Scope input (comma separated globs) plus overlap warnings list, Prompt textarea (monospace, char counter, 32 KB limit).
- Live validation: debounce 300 ms, single-flight, GET /api/dispatch/check on repo/agent/task/scope change; per-field red/green hints, an amber "rerouted to X" notice, amber overlap list (task, agent, glob), the CLI preview line from `command`, "Copy CLI" button. Dispatch button disabled until `canDispatch` and prompt non-empty.
- Submit: Ctrl+Enter or the button -> existing confirm dialog showing agent, task, scope, first 200 chars of the prompt -> POST action dispatch with token, confirm:true -> job toast and poll as the other actions do; on success close the modal and navigate to the task (`navigateToTask`; the card may appear after the next poll: retry for ~10 s); on failure the modal stays open with the server error text and nothing is cleared.
- Esc closes (confirm only if the prompt has unsaved text), focus trap, focus returns to the Dispatch button, labels on every field, 375 px layout, light + dark, keyboard operable. Remember last repo and agent in localStorage (wrapped in try/catch); never store the prompt.
- Literal `__TRINITY_TOKEN__` must stay exactly once in the page (meta tag); never write it in JS or comments.
- Existing Inbox, Health, Tasks, tabs from step 3, action bar, confirm dialog, toasts, age chip keep working.
