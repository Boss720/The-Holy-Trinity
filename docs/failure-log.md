# Failure log

Append-only. One row per failure, error or surprise, newest last, so each can be fixed or prevented.
The orchestrator (Claude) appends; workers report failures in their result file and the orchestrator logs them.
Status: `open`, `fixed <commit>`, `wontfix <why>`, `mitigated <how>`.

| Date | Where | What failed | Cause | Status |
|---|---|---|---|---|
| 2026-10-25 | Codex review, bash | "memory allocation failed", exit 66 | Firefox held about 7.5 GB (7 dashboard connections); machine out of memory | mitigated: shared snapshot (6165c94) cut polling load; wait for memory then retry |
| 2026-10-25 | merge gate, dash-snap | 35/36: Claude summary cache invalidation | state now up to a few seconds old; test read it once | fixed fb55043 (test polls) |
| 2026-10-25 | Codex sandbox | dashboard HTTP tests skipped | sandbox cannot start a listener | mitigated: gate runs them outside the sandbox; skips now fail if server runs but never answers |
| 2026-10-25 | Codex worker gui-s1-server | `index.lock` access denied, could not rebase in worktree | worktree git dir is outside the Codex sandbox | open: sandbox scope (see docs/recommendations.md item 8) |
| 2026-10-25 | Antigravity worker gui-s1-page | task stayed "running" 25 min after finishing | 4 hung `verify_gui.js` child processes kept the agent waiting | mitigated: kill children by hand; open: dispatch needs a deadline and stall watchdog (Top 13 item 4) |
| 2026-10-25 | merge gate, gui-s1-server | 1 test failed: invalid Host did not return 403 | worker changed the forged Host to `localhost.`, which http.sys answers 400 | fixed a28fb54 (forged Host from LAN address) |
| 2026-10-25 | merge gate, gui-s1-server | two P2: board health hardcoded ok, collectMs excluded git checks | worker shortcuts | fixed a28fb54 |
| 2026-10-25 | merge gate, gui-s1-server | P2: rejected remote requests scheduled a collection | `lastRequestAt` set in the 403 branch | fixed 1dab95b |
| 2026-10-25 | orchestrator | merge command printed nothing useful, then never ran | `cd "../Holy trinity"` from the wrong directory; `tail` hid the start of the output | mitigated: write merge output to `.codex-out/merge-<task>.txt`, run from repo root |
| 2026-10-25 | orchestrator | stale dashboard on 7777 served old state after merge | `trinity dashboard -Stop` said "not running" while an old process held the port | open: -Stop should find the listener by port; restart by killing the process on 7777 |
| 2026-10-25 | Inbox | 10 "done, unmerged" items that were merged by hand | board status stays `done` when merged outside `trinity merge` | open: dismiss action / board cleanup (GUI step 2 or Housekeeping) |
