# HANDOFF.md

Update before you stop. Newest entry on top.

## Status
- Completed: Modules 0-4 (dashboard detail + chats; works without Codex), dashboard detail v3 (Antigravity parity)
- In flight: none. Release-install work (spec `docs/reco/install-spec.md`) is merged on main: installer 0e6de07, install-docs f9fdae4, release-pack 146dbb5, plus doctor/PATH/dispatch-guard hardening and self-tests (47 pass). A zip built from main passed `build-release.ps1 -Verify` and a fresh-extract walkthrough in a folder with spaces. NOT released or tagged. To ship: rename CHANGELOG `## Unreleased` to `## v0.4.0 - <date>`, commit, `git tag v0.4.0`, `git push origin main v0.4.0` (needs a token with `workflow` scope for the first push of `.github/workflows`); then check the Release workflow run and the release assets. Earlier: GUI step 1 merged (gui-s1-server a78178c + gui-s1-page f04cc78), gui-s2 merged 4d8c9a5 (by another session)
- Next command: GUI build order step 2 in `docs/recommendations-gui.md` (action API with token/Origin/loopback checks, jobs, first actions cancel/merge/review-task/open-folder). Known: Inbox "done-unmerged" lists old board entries merged by hand; add a dismiss or board cleanup in step 2
- Blockers: none (two PLAN boxes need the user: notification seen on screen, Claude headless reviewer logged in)

## From Claude
- 2026-10-25: Army audit (Codex, Antigravity, 3 Sonnet, 2 Haiku, live dashboard check) wrote `docs/recommendations.md` plus raw reports in `docs/reco/` (uncommitted). Headlines: dashboard collect 4.1 s warm on the only thread and the page polls every 3 s with no in-flight guard (requests queue, 34-75 s replies); the dashboard listener answers on all interfaces (Host-header guard only); merge does not check the task finished; no runner timeout. Audit branches reco-ui and reco-rel were cancelled after their reports were copied.
- 2026-10-25: Module 4. Dashboard shows models, tokens, tool calls, rate limits, chats (Codex, Antigravity, Claude sessions and subagents). Trinity runs without a ChatGPT plan: dispatch reroutes, review/ask/merge fall back to Claude Code headless, then Antigravity plan mode (`--mode plan`, must stay inside the workspace or `--add-dir`, one denied read drops the answer), then tests alone. Real Codex child rollouts carry the PARENT id in `session_id`; own id is in the file name. http.sys answers 400 itself for a foreign Host. Two empty files `Read` and `[-Force]'` are tracked at the root by accident (added in 0f05805/057baa3); left for the user to remove.
- 2026-10-25: Dashboard merged. Gate caught two real failures in Codex's tests (em-dash in a result file read as ANSI became a bare quote in the JSON; tests read the real `~/.trinity` registry); fixed on the worker branch, then merged 16/16. agy's `-p` stdout includes `<SYSTEM_MESSAGE>` background notices; one became the `dash-ui` commit subject (705517b, left in history). Runner now strips them; fake agy emits one so the suite guards it.
- 2026-10-25: Dashboard module. Claude wrote the spec (`docs/dashboard.md`) and the CLI side; Codex builds the server, Antigravity the page, in parallel worktrees. Army skill (`~/.claude/skills/army/SKILL.md`) now routes chunks to Codex/Antigravity via trinity and tells Claude to `track` its own chunk.
- 2026-10-25: Codex wrote its own lookalike "done (...)" status mid-run; closed the hole (done refused for headless tasks, wait checks the runner pid). Suite now 12 cases, runs as the merge gate.
- 2026-10-25: All three harnesses now run the same way: `dispatch codex|antigravity` = headless worker in its own worktree, runner commits, board status, `wait`, `merge` (Codex review gate + Test command), `cancel`. Antigravity uses the `agy` CLI with `--dangerously-skip-permissions` (user's choice); task rules confine it to its worktree. Proven live in MetaStrip: Antigravity wrote `test/ui-hint.test.js`, merged through the gate, 24 tests pass there; the test fails correctly when a format is dropped from the UI hint.
- 2026-10-25: Split MetaStrip into its own repo at `D:\AI\projects\Dev\Projects\MetaStrip`; it uses this toolkit through `trinity init`. This repo is the toolkit only.
- 2026-10-25: Repo scaffolded. Codex reachable via `scripts\codex-*.cmd`.

## From Codex

## From Antigravity
