# Codex reliability recommendations

## Bugs and races

- [P1] [M] Readers can see a partially rewritten board - scripts/lib/board.ps1:73 - `Get-BoardEntry` reads without the write lock while `WriteAllText` truncates and rewrites the same file, so a concurrent wait or dispatch can parse missing or incomplete state - lock board reads too or write through a temporary file and atomically replace it.
- [P1] [M] Merge review can go stale while main advances - scripts/trinity.ps1:618 - another merge can move main after the clean-tree check and during review, so the reviewed diff and eventual merge base differ - serialize merges and verify main HEAD is unchanged immediately before merging.
- [P2] [S] Fast runner can leave a stale PID file - scripts/trinity.ps1:359 - a worker can finish and remove its pid file before dispatch writes the just-started PID, leaving a stale file that confuses wait and cancel - establish a runner handshake or have the runner create and own its PID record before work begins.

## Recovery

- [P1] [M] Headless execution has no worker timeout - scripts/trinity.ps1:495 - Codex and Antigravity run synchronously without a process timeout, so a hung CLI leaves the runner and task pending indefinitely while wait only times out its own polling - add a runner-enforced deadline and terminate the child process tree on expiry.
- [P1] [M] Stale PID can make wait hang or cancel kill an unrelated process - scripts/trinity.ps1:285 - PID existence alone is treated as runner identity, so a reused PID after reboot can look alive and cancel can terminate the unrelated process - store and verify process start time plus a task-specific command identity before trusting or killing a PID.
- [P2] [M] Dispatch failures after worktree creation leave orphaned task state - scripts/trinity.ps1:351 - a task-file write or hidden runner launch failure occurs after the worktree and board entry exist and has no rollback path - wrap task-file creation and launch in cleanup that marks failed and removes only newly created state.
- [P2] [S] Failed cleanup leaves merged task registered as complete - scripts/trinity.ps1:697 - the board is marked merged before worktree removal, so a cleanup error leaves a stale branch/worktree that blocks reuse of the task name - record a cleanup-needed state and provide an idempotent repair path.

## Merge gate

- [P1] [M] Nonstandard P1 formatting bypasses the finding gate - scripts/trinity.ps1:62 - only lines matching `- [P0]` through `- [P3]` start finding blocks, so a reviewer that reports a P1 with a heading, bold markup, or another list marker can be treated as clean - parse severity independently of presentation and fail closed on unrecognized review output.
- [P1] [M] Merge can run before a headless worker is finished - scripts/trinity.ps1:614 - merge checks for commits but not a terminal board status or live runner, so it can review and merge a branch while the worker is still changing it - require a completed status and no verified live runner before review and merge.

## Untrusted input

- [P1] [M] Codex sandbox includes writable shared Git metadata - scripts/trinity.ps1:499 - `--add-dir $paths.Common` grants the worker access to the shared common Git directory, which contains the board and repository metadata, so an agent can alter refs or other tasks' coordination state - remove that added directory and let only the runner perform Git operations.
- [P2] [S] Worker result is printed as terminal control text - scripts/trinity.ps1:303 - `wait` writes untrusted result-file contents directly to the console, allowing control characters to manipulate terminal display or conceal output - escape or strip control characters before rendering results.
- [P2] [S] Secret hook recognizes only a small set of token formats - .githooks/pre-commit:40 - staged secrets using unlisted providers or formats pass the scan even though the hook appears to guard staged content generally - broaden the patterns or use a configurable scanner with representative coverage and document its limits.

## Performance

- [P2] [S] Every status call performs sequential login probes - scripts/lib/board.ps1:225 - `status` invokes Codex and Claude login commands through availability checks, adding external CLI startup latency to a frequently used command - cache availability briefly or separate detailed probes from routine status output.
- [P3] [S] Wait reparses the whole board every five seconds - scripts/trinity.ps1:276 - each poll rereads and scans all board entries even though it needs only one task, making waits scale with both task count and duration - read the requested section under a consistent snapshot or use a task-indexed state store.

## Other

- [P2] [S] Init can leave a partially updated target after copy failure - scripts/trinity.ps1:733 - toolkit files are copied one at a time directly into the target, so interruption can leave a mixed-version installation that still appears initialized - stage updates and replace them as a transaction or record incomplete setup for repair.

## Top 5

- [P1] [M] Remove Codex write access to shared Git metadata - scripts/trinity.ps1:499 - isolate the worker to its worktree and keep Git mutations in the runner.
- [P1] [M] Require a completed task before merge - scripts/trinity.ps1:614 - reject active or unverified runner state before starting review.
- [P1] [M] Add an enforced worker deadline - scripts/trinity.ps1:495 - stop hung CLI process trees and write a terminal failure status.
- [P1] [M] Make review severity parsing fail closed - scripts/trinity.ps1:62 - block on severity markers even when the reviewer formats the finding unexpectedly.
- [P1] [M] Serialize merges and revalidate main HEAD - scripts/trinity.ps1:618 - ensure the commit being merged is the one the reviewer examined.
