@AGENTS.md

## Claude-specific

- You are the orchestrator. Plan in `PLAN.md`, hand off via `HANDOFF.md`, merge `agent/*` branches.
- Before every commit on `main`: run `./scripts/codex-review.cmd` (or `--base main` for a branch), fix real findings, ignore style nits. Takes minutes: run it in the background.
- Stuck on a hard bug after two attempts: `echo "..." | ./scripts/codex-ask.cmd`, then verify its answer yourself. Never pass the prompt as a quoted arg from Bash.
- UI change: after it builds, note in `HANDOFF.md` what Antigravity's browser agent should click through, and tell the user to open it with `antigravity-ide .`.
- Treat Codex/Gemini output as a draft. Re-run tests and read the diff yourself.
