# HANDOFF.md

Update before you stop. Newest entry on top.

## Status
- Completed: Modules 0-4 (dashboard detail + chats; works without Codex), dashboard detail v3 (Antigravity parity), docs/dashboard-gui.md contract (a120a12), cli-wire 4444c50 (merge -DryRun with conflict check, scope guard, running-task guard, TRINITY_CODEX_MODEL/EFFORT, config precedence, trinity config).
- In flight, wave A (dashboard GUI, see "2026-10-28 wave A" below):
  - codex `sched-core`: done, 2 commits on `agent/codex/sched-core` (4c83d86). Not merged.
  - codex `dash-api`: done, 2 commits on `agent/codex/dash-api` (cad9382). HTTP verb tests skipped in sandbox (no HttpListener). Not merged.
  - claude `ui-board`: merged 057642d (gate: 100 passed, 1 skipped).
  - claude `ui-shell`: finished by the Sonnet worker in worktree `claude-ui-shell` (dashboard.html, dashboard-sample.json; 96 passed per its report). Not committed or merged. `.codex-out/prompt-ui-shell-codex.md` is obsolete.
  - `cli-wire`: done, committed on main (4444c50). Config part waits on sched-core (lib/config.ps1 absent, that test skips).
- Not started: queue/scheduler/pause/unpause/autopilot/history CLI commands (need sched-core signatures); Phase 4 notifications and History wiring (touches dashboard.ps1, after dash-api merge); live click-through of the dashboard.
- Known gaps: dash-api action-verb HTTP coverage not run; /api timing (warm collect) not controlled-measured (39 ms added by state collector with 20 tasks); `trinity config` P1 review finding resolves when sched-core lands.
- Carried over: test-parallel (Sonnet subagent, parked claude task): tests/run-parallel.ps1 shards run-tests.ps1 (-Shard i/N), run-tests.cmd calls it; serial 521 s vs parallel 186 s. Wave 2 merged 2026-10-28: cli-resume 649f7eb (`trinity resume`), cli-dashstop (dashboard -Stop/start find orphan by port, HTTP.sys pid 4 handled), cli-mergebase e2bfb34 (re-review when base moved, unparsed review blocks unless -Force, review-<task>.md, Get-BaseBranch + `base:` status line). Wave 1 merged: dash-token-test 67ae756, worktree-seed 0205a66 + wiring 010a4f0/83ad531, runner-watchdog 42a2a6d. Released through v0.6.0.
- Next commands, in order:
  1. Clean main: `git status`. Four staged ui-board files are from the stopped merge. Unstage (`git restore --staged scripts/dashboard-ui`) or let `trinity merge ui-board -Yes` redo it. Do not merge by hand.
  2. Untracked scratch files in repo root (`0`, `0)`, `MIN_GAP_MS)`, `PAUSE`, `board.png`, `m1.png`, and similar) were moved to the scratchpad quarantine folder (`C:\Users\Hp\AppData\Local\Temp\claude\D--AI-projects-Dev-Projects-Holy-trinity\3a7d357a-199c-41bf-b553-d8cc789f8333\scratchpad\quarantine`). Check it, then delete if unneeded. Shell-quoting leftovers. The merge gate refuses a dirty main.
  3. `./trinity.sh merge ui-board -Yes`, then `merge sched-core -Yes`, then `merge dash-api -Yes`. Read each diffstat and gate result first. Re-run `tests\run-tests.cmd` after each.
  4. Dispatch Codex (gpt-6.1-terra, high effort; `TRINITY_DISABLE=antigravity`):
     - ui-shell follow-up from `.codex-out/prompt-ui-shell-codex.md`.
     - queue/scheduler/pause/unpause/autopilot/history CLI wiring in trinity.ps1 against sched-core's real signatures. Add help lines, AGENTS.md entries for TRINITY_CODEX_MODEL, TRINITY_CODEX_EFFORT, TRINITY_SCOPE_GUARD. Re-run cli-wire config case.
     - Phase 4 notifications and History wiring, after dash-api merge.
  5. Live click-through: `trinity dashboard`, open http://localhost:7777/, exercise Overview, Board drag, Settings, Autopilot, drawer, wizard, History. Re-check loopback. Screenshots as evidence.
  6. Update PLAN.md, this file, and docs/failure-log.md (see Failures below). Then `trinity done cli-wire` if still tracked.
- Blockers: Claude usage at 98%, so Claude workers pause until reset. Codex config.toml default effort is `low` (user's file, `model = "gpt-6.1-sol"`); always pass `TRINITY_CODEX_EFFORT=high` for workers or they stop early. Live `dispatch claude -Headless` still untested. Plan boxes for user: notification seen on screen, Claude headless reviewer logged in.

## 2026-10-28 wave A (dashboard GUI full control)
- Contract: `docs/dashboard-gui.md` (a120a12). Routing: Codex gpt-6.1-terra for sched-core and dash-api, Claude Sonnet for ui-board and ui-shell. No Antigravity.
- Failures this wave (log these in docs/failure-log.md):
  - Codex workers stopped early at config.toml effort `low`. Fix: `TRINITY_CODEX_EFFORT=high`, resume with `TRINITY_CODEX_MODEL=gpt-6.1-terra TRINITY_CODEX_EFFORT=high TRINITY_DISABLE=antigravity ./trinity.sh resume <task> -FeedbackFile ...`.
  - Hard scope guard broke about 20 merge tests (fakes write outside `tests/*`). Fix: `TRINITY_SCOPE_GUARD` block|warn|off (default block); suite runs warn.
  - Merge gate refused ui-board with "main checkout has uncommitted changes" because of stray root files from shell quoting. Fix: quarantine, do not delete blindly. Avoid unquoted `$`/`(` in bash one-liners.
  - Codex review P2 on cli-wire: dry-run tested worktree only, missed base conflicts. Fixed with `git merge-tree --write-tree` check before tests.
  - Codex review P1 on cli-wire: `scripts/lib/config.ps1` not present on main, so `trinity config` fails. Pending sched-core merge.
  - ui-shell Sonnet worker never finished before Claude usage ran out.
- Decisions: CLI gate stays the only merge path. Dry run must check conflicts with base. Config precedence: env > flag > trinity.json > default.

## 2026-10-28 earlier (Claude)
- Any agent can orchestrate (spec `docs/orchestrator.md`). Merged orch-skill (`.agents/skills/trinity/SKILL.md`, Antigravity) and orch-core (`-Agent`, `TRINITY_ORCHESTRATOR`, env detection, `orchestrator:` status line, `track`/`done` for any agent, reviewer never the author, `dispatch claude -Headless`, Codex); docs 59de4f7, fix 6954ae9. 58 tests pass. Live: real `codex exec` and `agy -p` sessions ran `status -Brief`/`track`/`done` here and were detected as codex/antigravity with chats linked on the dashboard (board tasks live-codex, live-agy). Not live-tested: `dispatch claude -Headless` with a real Claude CLI (not logged in on this machine; covered by fake-claude test only).

## 2026-10-25 (Claude)
- Army audit (Codex, Antigravity, 3 Sonnet, 2 Haiku, live dashboard check) wrote `docs/recommendations.md` plus raw reports in `docs/reco/` (uncommitted). Headlines: dashboard collect 4.1 s warm on the only thread and the page polls every 3 s with no in-flight guard (requests queue, 34-75 s replies); the dashboard listener answers on all interfaces (Host-header guard only); merge does not check the task finished; no runner timeout. Audit branches reco-ui and reco-rel were cancelled after their reports were copied.
- Module 4. Dashboard shows models, tokens, tool calls, rate limits, chats (Codex, Antigravity, Claude sessions and subagents). Trinity runs without a ChatGPT plan: dispatch reroutes, review/ask/merge fall back to Claude Code headless, then Antigravity plan mode (`--mode plan`, must stay inside the workspace or `--add-dir`, one denied read drops the answer), then tests alone. Real Codex child rollouts carry the PARENT id in `session_id`; own id is in the file name. http.sys answers 400 itself for a foreign Host. Two empty files `Read` and `[-Force]'` are tracked at the root by accident (added in 0f05805/057baa3); left for the user to remove.
- Dashboard merged. Gate caught two real failures in Codex's tests (em-dash in a result file read as ANSI became a bare quote in the JSON; tests read the real `~/.trinity` registry); fixed on the worker branch, then merged 16/16. agy's `-p` stdout includes `<SYSTEM_MESSAGE>` background notices; one became the `dash-ui` commit subject (705517b, left in history). Runner now strips them; fake agy emits one so the suite guards it.
- Dashboard module. Claude wrote the spec (`docs/dashboard.md`) and the CLI side; Codex builds the server, Antigravity the page, in parallel worktrees. Army skill (`~/.claude/skills/army/SKILL.md`) now routes chunks to Codex/Antigravity via trinity and tells Claude to `track` its own chunk.
- Codex wrote its own lookalike "done (...)" status mid-run; closed the hole (done refused for headless tasks, wait checks the runner pid). Suite now 12 cases, runs as the merge gate.
- All three harnesses now run the same way: `dispatch codex|antigravity` = headless worker in its own worktree, runner commits, board status, `wait`, `merge` (Codex review gate + Test command), `cancel`. Antigravity uses the `agy` CLI with `--dangerously-skip-permissions` (user's choice); task rules confine it to its worktree. Proven live in MetaStrip: Antigravity wrote `test/ui-hint.test.js`, merged through the gate, 24 tests pass there; the test fails correctly when a format is dropped from the UI hint.
- Split MetaStrip into its own repo at `D:\AI\projects\Dev\Projects\MetaStrip`; it uses this toolkit through `trinity init`. This repo is the toolkit only.
- Repo scaffolded. Codex reachable via `scripts\codex-*.cmd`.

## From Codex

## From Antigravity
