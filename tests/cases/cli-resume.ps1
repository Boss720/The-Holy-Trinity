# trinity resume: re-run a finished task in the same worktree and branch with feedback appended to its prompt.

# Fake Codex that records the task file it was given in the worktree, so every round commits a different file.
# It lives next to the fixture repo (not in it), so main stays clean. Returns the path of the .cmd to use as CODEX_EXE.
function Install-ResumeCodex($f) {
    $source = @'
$ErrorActionPreference = 'Stop'
$arguments = $env:FAKE_CODEX_ARGUMENTS
if ($arguments -match '^\s*login\s+status') { [Console]::WriteLine('Logged in using ChatGPT'); exit 0 }
if ($arguments -notmatch '^\s*exec(?:\s|$)') { exit 2 }
if ($env:FAKE_CODEX_MODE -eq 'fail') { exit 3 }
$workingDirectory = $null
$resultPath = $null
if ($arguments -match '(?:^|\s)-C\s+"([^"]+)"') { $workingDirectory = $Matches[1] }
if ($arguments -match '(?:^|\s)-o\s+"([^"]+)"') { $resultPath = $Matches[1] }
if (-not $workingDirectory -or -not $resultPath) { exit 2 }
$prompt = [Console]::In.ReadToEnd()
$utf8 = New-Object System.Text.UTF8Encoding($false)
[IO.File]::WriteAllText((Join-Path $workingDirectory 'seen-task.txt'), $prompt, $utf8)
[IO.File]::WriteAllText($resultPath, 'Fake resume Codex done.' + "`r`n", $utf8)
exit 0
'@
    $utf8 = New-Object Text.UTF8Encoding($false)
    [IO.File]::WriteAllText((Join-Path $f.Root 'fake-resume-codex.ps1'), $source, $utf8)
    $cmd = Join-Path $f.Root 'fake-resume-codex.cmd'
    [IO.File]::WriteAllText($cmd, "@echo off`r`nset `"FAKE_CODEX_ARGUMENTS=%*`"`r`npowershell -NoProfile -ExecutionPolicy Bypass -File `"%~dp0fake-resume-codex.ps1`"`r`nexit /b %ERRORLEVEL%`r`n", $utf8)
    $cmd
}

Run-Case 'cli-resume: done task resumes on the same branch and worktree, feedback in the prompt, rounds kept' {
    param($f)
    $env:CODEX_EXE = Install-ResumeCodex $f
    $out = Join-Path $f.Repo '.codex-out'
    $board = Join-Path $f.Repo '.git\agent-board.md'
    $wt = Join-Path $f.Worktrees 'codex-rs-done'
    Start-CodexTask $f 'rs-done'
    $wait = Invoke-Trinity $f @('wait', 'rs-done', '-Timeout', '60')
    Assert-True ($wait.ExitCode -eq 0 -and $wait.Output -match 'done \(1 commits\)') "first run failed: $($wait.Output)"
    $firstHead = Invoke-Git $f.Repo @('rev-parse', 'agent/codex/rs-done')

    # No feedback and no saved review, or an empty feedback file: refused, nothing touched.
    $none = Invoke-Trinity $f @('resume', 'rs-done')
    Assert-True ($none.ExitCode -eq 1 -and $none.Output -match 'usage: trinity resume') "resume without feedback was accepted: $($none.Output)"
    $emptyFile = Join-Path $f.Root 'empty-feedback.txt'
    [IO.File]::WriteAllText($emptyFile, "  `r`n", (New-Object Text.UTF8Encoding($false)))
    $empty = Invoke-Trinity $f @('resume', 'rs-done', '-FeedbackFile', $emptyFile)
    Assert-True ($empty.ExitCode -eq 1 -and $empty.Output -match 'usage: trinity resume') "resume with an empty feedback file was accepted: $($empty.Output)"
    $missing = Invoke-Trinity $f @('resume', 'rs-done', '-FeedbackFile', (Join-Path $f.Root 'no-such-file.txt'))
    Assert-True ($missing.ExitCode -eq 1 -and $missing.Output -match 'feedback file not found') "missing feedback file was accepted: $($missing.Output)"
    Assert-True ((Get-Content -Raw $board) -match '- status: done \(1 commits\)') 'a refused resume changed the board'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $out 'log-rs-done.round1.txt'))) 'a refused resume moved the old log'

    # Round 2: -Feedback.
    $resume = Invoke-Trinity $f @('resume', 'rs-done', '-Feedback', 'Please also handle the empty input case.')
    Assert-True ($resume.ExitCode -eq 0 -and $resume.Output -match 'round 2') "resume failed: $($resume.Output)"
    $wait = Invoke-Trinity $f @('wait', 'rs-done', '-Timeout', '60')
    Assert-True ($wait.ExitCode -eq 0 -and $wait.Output -match 'done \(2 commits\)') "resumed run did not add a commit: $($wait.Output)"
    Assert-True ((Invoke-Git $f.Repo @('rev-list', '--count', 'main..agent/codex/rs-done')) -eq '2') 'branch should have 2 commits'
    Assert-True ((Invoke-Git $f.Repo @('rev-parse', 'agent/codex/rs-done~1')) -eq $firstHead) 'the new commit is not on top of the first run'
    $worktrees = @((Invoke-Git $f.Repo @('worktree', 'list', '--porcelain')) -split "`n" | Where-Object { $_ -like 'worktree *' })
    Assert-True ($worktrees.Count -eq 2) "resume must not create another worktree: $($worktrees -join ', ')"
    $seen = Get-Content -Raw (Join-Path $wt 'seen-task.txt')
    Assert-True ($seen -match 'Perform the fixture task' -and $seen -match '## Feedback \(round 2\)' -and $seen -match 'Please also handle the empty input case' -and $seen -match '## Rules') "agent did not get original request plus feedback: $seen"
    Assert-True ($seen.IndexOf('Perform the fixture task') -lt $seen.IndexOf('## Feedback (round 2)') -and $seen.IndexOf('## Feedback (round 2)') -lt $seen.IndexOf('## Rules')) 'feedback is not between the request and the rules'
    foreach ($name in @('log-rs-done.round1.txt', 'result-rs-done.round1.md', 'meta-rs-done.round1.json', 'run-rs-done.round1.cmd')) {
        Assert-True (Test-Path -LiteralPath (Join-Path $out $name)) "round 1 file not kept: $name"
    }
    Assert-True ((Get-Content -Raw (Join-Path $out 'result-rs-done.md')) -match 'Fake resume Codex done') 'the new run did not write a fresh result'
    Assert-True ((Get-Content -Raw $board) -match '(?m)^- round: 2\r?$') "board should record round 2: $(Get-Content -Raw $board)"
    $taskText = Get-Content -Raw (Join-Path $out 'task-rs-done.md')
    Assert-True ($taskText -match 'scope: tests/\*' -and $taskText -match 'Do not run git commit' -and $taskText -match '## Feedback \(round 2\)') 'task file lost its header or rules'
    Assert-True ((Get-Content -Raw (Join-Path $out 'prompt-rs-done.md')) -match 'Perform the fixture task[\s\S]*## Feedback \(round 2\)') 'prompt file does not hold the resumed prompt'

    # Round 3: -Feedback together with -FeedbackFile; earlier feedback stays in the prompt.
    $notes = Join-Path $f.Root 'feedback.txt'
    [IO.File]::WriteAllText($notes, "Fix the typo.`r`nThen rerun the checks.`r`n", (New-Object Text.UTF8Encoding($false)))
    $resume = Invoke-Trinity $f @('resume', 'rs-done', '-Feedback', 'Extra note.', '-FeedbackFile', $notes, '-DeadlineMinutes', '7')
    Assert-True ($resume.ExitCode -eq 0 -and $resume.Output -match 'round 3') "second resume failed: $($resume.Output)"
    $wait = Invoke-Trinity $f @('wait', 'rs-done', '-Timeout', '60')
    Assert-True ($wait.ExitCode -eq 0 -and $wait.Output -match 'done \(3 commits\)') "round 3 did not add a commit: $($wait.Output)"
    $seen = Get-Content -Raw (Join-Path $wt 'seen-task.txt')
    Assert-True ($seen -match '## Feedback \(round 2\)' -and $seen -match '## Feedback \(round 3\)' -and $seen -match 'Extra note\.\s+Fix the typo\.\s+Then rerun the checks\.') "round 3 prompt is wrong: $seen"
    foreach ($name in @('log-rs-done.round1.txt', 'log-rs-done.round2.txt', 'result-rs-done.round2.md', 'meta-rs-done.round2.json')) {
        Assert-True (Test-Path -LiteralPath (Join-Path $out $name)) "round file not kept: $name"
    }
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $out 'log-rs-done.round3.txt'))) 'the current run must not be archived'
    Assert-True ((Get-Content -Raw $board) -match '(?m)^- round: 3\r?$') 'board should record round 3'
    Assert-True ((Invoke-Git $f.Repo @('rev-list', '--count', 'main..agent/codex/rs-done')) -eq '3') 'branch should have 3 commits'
    $meta = Get-Content -Raw (Join-Path $out 'meta-rs-done.json') | ConvertFrom-Json
    Assert-True ((([datetime]$meta.deadlineAt) - ([datetime]$meta.started)).TotalMinutes -eq 7) "resume ignored -DeadlineMinutes: $($meta.started) -> $($meta.deadlineAt)"
}

Run-Case 'cli-resume: failed task resumes with the saved review as default feedback' {
    param($f)
    $env:CODEX_EXE = Install-ResumeCodex $f
    $out = Join-Path $f.Repo '.codex-out'
    $env:FAKE_CODEX_MODE = 'fail'
    Start-CodexTask $f 'rs-failed'
    $wait = Invoke-Trinity $f @('wait', 'rs-failed', '-Timeout', '60')
    Assert-True ($wait.ExitCode -eq 1 -and $wait.Output -match 'failed \(exit 3\)') "first run should fail: $($wait.Output)"
    $env:FAKE_CODEX_MODE = 'ok'
    [IO.File]::WriteAllText((Join-Path $out 'review-rs-failed.txt'), "[P1] scripts/x.ps1: handle empty input`r`n", (New-Object Text.UTF8Encoding($false)))
    $resume = Invoke-Trinity $f @('resume', 'rs-failed')
    Assert-True ($resume.ExitCode -eq 0 -and $resume.Output -match 'Feedback from') "resume of a failed task failed: $($resume.Output)"
    $wait = Invoke-Trinity $f @('wait', 'rs-failed', '-Timeout', '60')
    Assert-True ($wait.ExitCode -eq 0 -and $wait.Output -match 'done \(1 commits\)') "resumed run did not finish: $($wait.Output)"
    $seen = Get-Content -Raw (Join-Path $f.Worktrees 'codex-rs-failed\seen-task.txt')
    Assert-True ($seen -match '## Feedback \(round 2\)' -and $seen -match '\[P1\] scripts/x\.ps1: handle empty input') "review text not used as feedback: $seen"
    Assert-True (Test-Path -LiteralPath (Join-Path $out 'log-rs-failed.round1.txt')) 'the failed run log was not kept'
    Assert-True ((Get-Content -Raw (Join-Path $f.Repo '.git\agent-board.md')) -match '(?m)^- round: 2\r?$') 'board should record round 2'
}

Run-Case 'cli-resume: refused for running, merged, cancelled, live runner, tracked, gone and unknown tasks' {
    param($f)
    $env:CODEX_EXE = Install-ResumeCodex $f
    $out = Join-Path $f.Repo '.codex-out'
    New-Item -ItemType Directory -Path $out -Force | Out-Null
    $board = Join-Path $f.Repo '.git\agent-board.md'
    $states = [ordered]@{
        'rs-started' = 'started 2026-01-01 00:00'
        'rs-running' = 'running 2026-01-01 00:00'
        'rs-stalled' = 'running (stalled: no output 15 min) 2026-01-01 00:00'
        'rs-waiting' = 'waiting for claude session 2026-01-01 00:00'
        'rs-merged' = 'merged 2026-01-01 00:00'
        'rs-cancelled' = 'cancelled 2026-01-01 00:00'
    }
    foreach ($name in $states.Keys) { Set-CliTask $f $name $states[$name] }
    $before = Get-Content -Raw $board
    foreach ($name in $states.Keys) {
        $res = Invoke-Trinity $f @('resume', $name, '-Feedback', 'try again')
        Assert-True ($res.ExitCode -eq 1 -and $res.Output -match 'cannot resume') "resume accepted $name ($($states[$name])): $($res.Output)"
    }
    Assert-True ((Get-Content -Raw $board) -ceq $before) 'refused resumes changed the board'

    $unknown = Invoke-Trinity $f @('resume', 'rs-nothing', '-Feedback', 'x')
    Assert-True ($unknown.ExitCode -eq 1 -and $unknown.Output -match 'unknown task') "unknown task accepted: $($unknown.Output)"
    $noName = Invoke-Trinity $f @('resume')
    Assert-True ($noName.ExitCode -eq 1 -and $noName.Output -match 'usage: trinity resume') "missing task name accepted: $($noName.Output)"

    # A finished task whose worktree is gone cannot be resumed in place.
    Set-CliTask $f 'rs-gone' 'done (1 commits) 2026-01-01 00:00'
    $gone = Invoke-Trinity $f @('resume', 'rs-gone', '-Feedback', 'x')
    Assert-True ($gone.ExitCode -eq 1 -and $gone.Output -match 'is gone') "gone worktree accepted: $($gone.Output)"

    # A tracked orchestrator chunk has no branch or worktree.
    $chunk = "`r`n## rs-chunk`r`n- agent: claude`r`n- branch: -`r`n- worktree: -`r`n- scope: unspecified`r`n- status: done: finished 2026-01-01 00:00`r`n"
    [IO.File]::AppendAllText($board, $chunk, (New-Object Text.UTF8Encoding($false)))
    $tracked = Invoke-Trinity $f @('resume', 'rs-chunk', '-Feedback', 'x')
    Assert-True ($tracked.ExitCode -eq 1 -and $tracked.Output -match 'tracked chunk') "tracked chunk accepted: $($tracked.Output)"

    # A done status with a live runner behind it (the pid file names this very test process).
    Set-CliTask $f 'rs-live' 'done (1 commits) 2026-01-01 00:00'
    $pidFile = Join-Path $out 'pid-rs-live.txt'
    [IO.File]::WriteAllText($pidFile, "$PID", (New-Object Text.UTF8Encoding($false)))
    (Get-Item -LiteralPath $pidFile).LastWriteTime = (Get-Process -Id $PID).StartTime
    $live = Invoke-Trinity $f @('resume', 'rs-live', '-Feedback', 'x')
    Assert-True ($live.ExitCode -eq 1 -and $live.Output -match 'runner is still alive') "live runner accepted: $($live.Output)"
}

Run-Case 'cli-resume: interactive Claude task goes back to waiting with the feedback in its task file' {
    param($f)
    $out = Join-Path $f.Repo '.codex-out'
    $board = Join-Path $f.Repo '.git\agent-board.md'
    [IO.File]::WriteAllText($f.Prompt, "Perform the fixture task.`r`n", (New-Object Text.UTF8Encoding($false)))
    $dispatch = Invoke-Trinity $f @('dispatch', 'claude', 'rs-claude', '-Scope', 'tests/*', '-PromptFile', $f.Prompt)
    Assert-True ($dispatch.ExitCode -eq 0) "dispatch failed: $($dispatch.Output)"
    $done = Invoke-Trinity $f @('done', 'rs-claude', 'finished', 'by', 'hand')
    Assert-True ($done.ExitCode -eq 0) "done failed: $($done.Output)"
    $resume = Invoke-Trinity $f @('resume', 'rs-claude', '-Feedback', 'Cover the error path too.')
    Assert-True ($resume.ExitCode -eq 0 -and $resume.Output -match 'Open a new Claude Code session') "interactive resume failed: $($resume.Output)"
    $text = Get-Content -Raw $board
    Assert-True ($text -match '- status: waiting for claude session' -and $text -match '(?m)^- round: 2\r?$') "board not updated: $text"
    $taskText = Get-Content -Raw (Join-Path $out 'task-rs-claude.md')
    Assert-True ($taskText -match 'Perform the fixture task' -and $taskText -match '## Feedback \(round 2\)' -and $taskText -match 'Cover the error path too' -and $taskText -match 'trinity done rs-claude') "task file not updated: $taskText"
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $out 'pid-rs-claude.txt'))) 'an interactive resume must not start a runner'
}
