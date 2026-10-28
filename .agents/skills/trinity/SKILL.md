---
name: trinity
description: Orchestrate parallel AI workers (Codex, Antigravity, Claude Code) in a trinity repo. Use when asked to orchestrate, delegate, fan out, dispatch workers, "army", parallelize tasks, or work in a repo with trinity.cmd at the root.
---

# Trinity Orchestration Playbook

You are the orchestrator in the main checkout. You plan, split work, dispatch headless workers into isolated git worktrees, track your own chunk, review, and merge through the quality gate.

## Start of Session

Run `trinity status -Brief` (or `./trinity.sh status -Brief` from Git Bash).
- Check `agents:` to see available workers (Codex, Antigravity, Claude).
- Check `orchestrator:` to verify your identity (`codex` or `antigravity`).
- If any task shows `done`, read its result and offer to merge it (`trinity merge <task> -Yes`).

## Identify Yourself

If the `orchestrator:` line is wrong, pass `-Agent codex` or `-Agent antigravity` on `trinity track`, or set `TRINITY_ORCHESTRATOR=codex|antigravity` in your environment.

## The Loop

1. **Scout inline:** Inspect codebase, find exact files, and define contracts before dispatching.
2. **Split by files:** Partition tasks into non-overlapping file scopes. Shared files stay with you.
3. **Write spec and commit:** Save architecture or interfaces to `docs/<feature>.md` and commit to `main` so workers share one source of truth.
4. **Write worker prompts:** Save prompt to `.codex-out/prompt-<task>.md` with concrete paths, clear boundaries, and test commands.
5. **Dispatch workers:** Run `trinity dispatch <agent> <task> -Scope "<glob>" -PromptFile .codex-out/prompt-<task>.md`.
6. **Wait in background:** Run `trinity wait <task> -Timeout 2400` in the background (exit 0 done, 1 failed, 2 running).
7. **Track your chunk:** Run `trinity track <task> "<note>"` to record your own work on the board. Do your work on `main`, then run `trinity done <task> "<summary>"`.
8. **Inspect results:** Read `.codex-out/result-<task>.md` and git diffstat.
9. **Merge through gate:** Run `trinity merge <task> -Yes` (runs independent review + tests; blocks on P0/P1).
10. **Wire and verify:** Wire shared files (check `.codex-out/deferred-<task>.txt`), run project Test command, read the diff.

## Worker Routing Table

| Orchestrator | Task Type | Route To | Command / Note |
|---|---|---|---|
| Codex | UI, frontend, repo-wide search | `antigravity` | `trinity dispatch antigravity <task> -Scope "<path>" -PromptFile <file>` |
| Codex | Focused coding, algorithms, tests | `codex` or `claude` | `trinity dispatch codex ...` or `trinity dispatch claude <task> -Headless ...` |
| Antigravity | Focused coding, algorithms, tests | `codex` | `trinity dispatch codex <task> -Scope "<path>" -PromptFile <file>` |
| Antigravity | UI, frontend, big-context work | `antigravity` or `claude` | `trinity dispatch antigravity ...` or `trinity dispatch claude <task> -Headless ...` |
| Either | Independent code review | Auto-fallback | `trinity review` / `merge` automatically picks another agent as reviewer |

Note: `trinity dispatch claude <task>` without `-Headless` only parks a task file for a human interactive session. Always include `-Headless` for automated Claude workers.

## Shell and Sandbox Notes

- **Syntax:** Windows CMD: `trinity <command>`. Git Bash: `./trinity.sh <command>` (preserves arguments with spaces).
- **Codex Orchestrator:** `trinity dispatch` writes `.git` worktrees and starts background processes. Run with `danger-full-access` or approve execution outside read-only sandboxes. Never run bare `codex exec`; use `trinity ask` or `scripts/codex-ask.cmd`.
- **Antigravity Orchestrator:** Run trinity commands via terminal tools. Run long waits (`trinity wait`) as background tasks.

## Rules

- **One writer per file set:** Strictly disjoint `-Scope` paths. Never let two workers edit the same files.
- **Shared files stay with orchestrator:** Registries, index files, package.json, and AGENTS.md "Shared files" are wired only by you after merge.
- **Never git merge agent branches by hand:** Always use `trinity merge <task> -Yes`.
- **Never use --no-verify:** If pre-commit hooks fail in a worktree, fix the problem in that worktree and commit there.
- **Main must be clean to merge:** Commit your orchestrator changes on `main` before merging worker branches.
- **Review before every commit on main:** Run `trinity review` (it picks a reviewer other than you), fix real findings, ignore style nits.
- **Treat worker output as a draft:** Re-run the project Test command and inspect the diff yourself after merge.
- **No secrets in prompts:** Never paste API keys, credentials, or personal data into prompt files.
- **Commit at each module gate:** Keep small, clean checkpoint commits on `main`.
