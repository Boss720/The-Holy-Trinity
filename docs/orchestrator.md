# Any agent can orchestrate

Spec for letting Codex or Antigravity run a trinity repo the way Claude does today:
plan, dispatch workers, track its own chunk, review, merge. Claude stays the default.

## Terms

- Orchestrator: the agent the user is talking to in the main checkout. Exactly one at a time.
- Worker: a headless agent dispatched into its own worktree (`agent/<agent>/<task>`).

## Orchestrator identity

`trinity.ps1` gets a function `Get-Orchestrator` returning `claude`, `codex` or `antigravity`:

1. `-Agent <name>` parameter (new, validated against the three names), if given.
2. `TRINITY_ORCHESTRATOR` env var, if set to one of the three.
3. Environment detection, innermost agent first (a child process inherits its parent's variables, and
   workers are started from the orchestrator):
   - `ANTIGRAVITY_AGENT` or `ANTIGRAVITY_CONVERSATION_ID` set: `antigravity`
   - `CODEX_THREAD_ID` set: `codex`
   - `CLAUDECODE` or `CLAUDE_CODE_SESSION_ID` set: `claude`
4. Default `claude`.

Session id of the orchestrator (for the dashboard): claude `CLAUDE_CODE_SESSION_ID`, codex `CODEX_THREAD_ID`,
antigravity `ANTIGRAVITY_CONVERSATION_ID`; only used when it looks like a GUID.

## Command changes (scripts/trinity.ps1)

- `track <task> <note...>`: board entry agent = orchestrator (was hardcoded `claude`). Refuse only when the existing
  entry belongs to a different agent. Store the session id in the board `session` field (all agents), and for
  codex/antigravity also write `.codex-out\meta-<task>.json` with `agent`, `started`, `sessionId` (keep an existing
  `started`) so the dashboard's Codex/Antigravity detail code links the chat with no dashboard change.
- `done <task>`: today it refuses any codex/antigravity entry ("its runner marks it done"). Refuse only headless worker
  entries, i.e. entries with a real branch (branch not `-`). Tracked orchestrator entries (branch `-`) can be done
  by any agent.
- `review` / `ask`: reviewer author = orchestrator, so the orchestrator never reviews its own change or answers its own question.
- `Select-Reviewer($author)`: honour `TRINITY_REVIEWER` as today; otherwise first available of codex, claude,
  antigravity that is not `$author`; fall back to `$author` itself only if nobody else can run. (Today Codex is always
  picked first even when Codex wrote the branch.) `merge` keeps passing the worker agent as author.
- `dispatch claude <task> ... -Headless` (new switch): Claude Code works headless in the worktree like the other
  workers: runner `_run` gets a `claude` branch:
  `cd /d "<worktree>" && "<claude exe>" -p --permission-mode acceptEdits --allowedTools "Read,Edit,Write,Glob,Grep,Bash" --add-dir "<.codex-out>" --output-format json < "<task file>" > "<out json>" 2> "<log>"`,
  run with `CLAUDECODE` cleared (as `Invoke-ReadOnlyAgent` does). Parse JSON `result` into `result-<task>.md`,
  `session_id` / `usage` / `total_cost_usd` / `duration_ms` / model into `meta-<task>.json` when present; non-JSON
  output is kept as the result as-is. Runner commits like other headless agents. Task-file rules for a headless claude
  are the headless rules (do not commit, runner commits). Without `-Headless`, `dispatch claude` keeps today's
  behaviour (task file, "waiting for claude session"), so the dashboard dispatch form is unchanged.
  `done` refuses a headless claude task like other headless workers (it has a branch, so the rule above covers it).
- `Select-Worker`: requested headless worker unavailable: try the other of codex/antigravity, then headless claude
  if available, else fail as today. When it reroutes to claude, the dispatch runs headless.
- `status`: add an `orchestrator: <agent>` line (also in `-Brief`), after the `agents:` line.
- Usage text: document `-Agent`, `-Headless`, orchestrator detection; `track` line says "your own (orchestrator) work".
- `init`: add `.agents\skills\trinity\SKILL.md` to the refreshed toolkit list; final message says
  "open a new Claude, Codex or Antigravity session there".

## Instruction files

- `.agents/skills/trinity/SKILL.md` (new, toolkit file): the orchestrator playbook for Codex and Antigravity. Both
  load repo skills from `.agents/skills/<name>/SKILL.md` (Antigravity also offers it as `/trinity`). Content: the
  army loop adapted to them (scout, split by files, dispatch with `-PromptFile`, `wait`, `track`/`done`, merge
  through the gate, verify), which worker to pick, start-of-session `trinity status -Brief`, and their sandbox notes.
- `AGENTS.md`: roles become "orchestrator = whoever the user talks to in the main checkout"; worker rules unchanged.
- `CLAUDE.md`, `GEMINI.md`: Claude/Antigravity specifics when orchestrating.

## Tests (tests/run-tests.ps1)

- `Get-Orchestrator` order: `-Agent` beats env; `TRINITY_ORCHESTRATOR`; `CODEX_THREAD_ID` beats `CLAUDECODE`.
- `track -Agent codex` creates a codex entry with the session field and meta file; `done` works on it.
- `done` still refuses a dispatched codex task.
- `Select-Reviewer`: author codex with claude available picks claude; `TRINITY_REVIEWER` still wins.
- `dispatch claude -Headless` with `tests/fake-claude` in edit mode: runner commits, board `done (1 commits)`,
  result file holds the JSON `result`.
- `status -Brief` prints `orchestrator:`.
