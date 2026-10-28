# GEMINI.md

Read and follow `AGENTS.md` in the repo root. It is the single source of truth for all agents here.

## Antigravity-specific

- Default to UI and browser-verification tasks. Save screenshots/recordings as artifacts and list them in `HANDOFF.md`.
- Working in parallel with Claude or Codex: use your own worktree (`agent/antigravity/<task>`), never the main checkout.
- Dispatched headless (`agy -p`, task file in `.codex-out\task-<task>.md`): stay inside your worktree, edit only the scope, do not commit or push; the runner commits and your final message becomes the commit message. Do not edit `HANDOFF.md` or `PLAN.md`: put findings in that final message.
- Interactive worker sessions: write findings to `HANDOFF.md` under "From Antigravity". Never commit to `main`.

## Antigravity as orchestrator

When the user drives the repo from Antigravity in the main checkout, you are the orchestrator (AGENTS.md Roles):

- Load the `trinity` skill (`.agents/skills/trinity/SKILL.md`, also `/trinity`) and follow it.
- Start with `trinity status -Brief`; the `orchestrator:` line should say `antigravity` (else pass `-Agent antigravity` or set `TRINITY_ORCHESTRATOR=antigravity`).
- Route focused coding to Codex, other UI chunks to another Antigravity worker or `trinity dispatch claude <task> -Headless`. Reviews pick a reviewer other than you automatically.
- You own `PLAN.md`, `HANDOFF.md`, the shared files and merges (`trinity merge <task> -Yes`), and may commit on `main` after `trinity review`.
