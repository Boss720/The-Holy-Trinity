Run-Case 'runner watchdog: deadline kills hanging worker and marks failed (timed out)' {
    param($f)
    $oldSec = $env:TRINITY_DEADLINE_SECONDS
    try {
        $env:TRINITY_DEADLINE_SECONDS = '2'
        $env:FAKE_CODEX_MODE = 'hang'
        Start-CodexTask $f 'deadline-default'
        $wait = Invoke-Trinity $f @('wait', 'deadline-default', '-Timeout', '30')
        Assert-True ($wait.ExitCode -eq 1) "wait should exit 1 on deadline timeout, got $($wait.ExitCode)"
        Assert-True ($wait.Output -match 'failed \(timed out after 45 min\)') "output should mention timed out: $($wait.Output)"
        $board = Get-Content -Raw (Join-Path $f.Repo '.git\agent-board.md')
        Assert-True ($board -match '- status: failed \(timed out after 45 min\)') "board status should be timed out: $board"
        Assert-True (Test-Path (Join-Path $f.Worktrees 'codex-deadline-default')) 'worktree must be preserved for show/retry'
        $branchLog = Invoke-Git $f.Repo @('log', '--oneline', 'main..agent/codex/deadline-default')
        Assert-True (-not $branchLog) "branch should have 0 commits on timeout: $branchLog"
        $metaPath = Join-Path $f.Repo '.codex-out\meta-deadline-default.json'
        Assert-True (Test-Path $metaPath) 'meta file should exist'
        $meta = Get-Content $metaPath -Raw | ConvertFrom-Json
        Assert-True ($meta.deadlineAt -or $meta.deadline) 'meta file should contain deadline ISO time'
    }
    finally {
        $env:TRINITY_DEADLINE_SECONDS = $oldSec
    }
}

Run-Case 'runner watchdog: deadline with -DeadlineMinutes flag' {
    param($f)
    $oldSec = $env:TRINITY_DEADLINE_SECONDS
    try {
        $env:TRINITY_DEADLINE_SECONDS = '2'
        $env:FAKE_AGY_MODE = 'hang'
        [IO.File]::WriteAllText($f.Prompt, "Perform fixture task.`r`n", [System.Text.UTF8Encoding]::new($false))
        $res = Invoke-Trinity $f @('dispatch', 'antigravity', 'deadline-custom', '-Scope', 'tests/*', '-PromptFile', $f.Prompt, '-DeadlineMinutes', '10')
        Assert-True ($res.ExitCode -eq 0) "dispatch failed: $($res.Output)"
        $wait = Invoke-Trinity $f @('wait', 'deadline-custom', '-Timeout', '30')
        Assert-True ($wait.ExitCode -eq 1) "wait should exit 1 on deadline timeout, got $($wait.ExitCode)"
        Assert-True ($wait.Output -match 'failed \(timed out after 10 min\)') "output should show 10 min: $($wait.Output)"
        $board = Get-Content -Raw (Join-Path $f.Repo '.git\agent-board.md')
        Assert-True ($board -match '- status: failed \(timed out after 10 min\)') "board status should show 10 min: $board"
    }
    finally {
        $env:TRINITY_DEADLINE_SECONDS = $oldSec
    }
}

Run-Case 'runner watchdog: stall status appears then clears when output grows' {
    param($f)
    $oldStall = $env:TRINITY_STALL_SECONDS
    $oldDeadSec = $env:TRINITY_DEADLINE_SECONDS
    try {
        $env:TRINITY_DEADLINE_SECONDS = $null
        $env:TRINITY_STALL_SECONDS = '2'
        $env:FAKE_CODEX_MODE = 'stall-then-resume'
        Start-CodexTask $f 'stall-task'
        $stalledSeen = $false
        $boardFile = Join-Path $f.Repo '.git\agent-board.md'
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        while ($sw.ElapsedMilliseconds -lt 12000) {
            if (Test-Path $boardFile) {
                $board = Get-Content -Raw $boardFile
                if ($board -match 'running \(stalled: no output 15 min\)') {
                    $stalledSeen = $true
                    break
                }
            }
            Start-Sleep -Milliseconds 200
        }
        Assert-True $stalledSeen 'board status should transition to running (stalled: no output 15 min)'
        $wait = Invoke-Trinity $f @('wait', 'stall-task', '-Timeout', '30')
        Assert-True ($wait.ExitCode -eq 0) "task should finish successfully: $($wait.Output)"
        Assert-True ($wait.Output -match 'done') "output should show done: $($wait.Output)"
        $board = Get-Content -Raw $boardFile
        Assert-True ($board -match '- status: done') "board status should clear stall and be done: $board"
    }
    finally {
        $env:TRINITY_STALL_SECONDS = $oldStall
        $env:TRINITY_DEADLINE_SECONDS = $oldDeadSec
    }
}

Run-Case 'runner watchdog: pid reuse detection reports runner dead' {
    param($f)
    $outDir = Join-Path $f.Repo '.codex-out'
    if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }

    # Part A: Non-powershell live process
    Set-CliTask $f 'reuse-nonps' 'running' 'codex'
    $nonPs = Get-Process | Where-Object { $_.ProcessName -notin @('powershell', 'pwsh') } | Select-Object -First 1
    [IO.File]::WriteAllText((Join-Path $outDir 'pid-reuse-nonps.txt'), "$($nonPs.Id)`r`n", [System.Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $outDir 'task-reuse-nonps.md'), "# Task`r`n", [System.Text.UTF8Encoding]::new($false))
    $waitA = Invoke-Trinity $f @('wait', 'reuse-nonps', '-Timeout', '10')
    Assert-True ($waitA.ExitCode -eq 1) "wait should exit 1 on non-powershell PID, got $($waitA.ExitCode)"
    Assert-True ($waitA.Output -match 'runner dead \(pid reused\)') "wait should report runner dead: $($waitA.Output)"

    # Part B: Powershell live process started before task dispatch
    Set-CliTask $f 'reuse-ps' 'running' 'codex'
    [IO.File]::WriteAllText((Join-Path $outDir 'pid-reuse-ps.txt'), "$PID`r`n", [System.Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $outDir 'task-reuse-ps.md'), "# Task`r`n", [System.Text.UTF8Encoding]::new($false))
    $waitB = Invoke-Trinity $f @('wait', 'reuse-ps', '-Timeout', '10')
    Assert-True ($waitB.ExitCode -eq 1) "wait should exit 1 on reused powershell PID, got $($waitB.ExitCode)"
    Assert-True ($waitB.Output -match 'runner dead \(pid reused\)') "wait should report runner dead: $($waitB.Output)"

    # Part C: Cancel on reused PID does not kill unrelated process
    Set-CliTask $f 'reuse-cancel' 'running' 'codex'
    [IO.File]::WriteAllText((Join-Path $outDir 'pid-reuse-cancel.txt'), "$PID`r`n", [System.Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $outDir 'task-reuse-cancel.md'), "# Task`r`n", [System.Text.UTF8Encoding]::new($false))
    $cancel = Invoke-Trinity $f @('cancel', 'reuse-cancel', '-Force')
    Assert-True ($cancel.Output -match 'runner dead \(pid reused\)') "cancel should report runner dead: $($cancel.Output)"
    $myProc = Get-Process -Id $PID -ErrorAction SilentlyContinue
    Assert-True ($null -ne $myProc) 'cancel must not kill unrelated process'
}

Run-Case 'runner watchdog: help text mentions -DeadlineMinutes' {
    param($f)
    $help = Invoke-Trinity $f @('help')
    Assert-True ($help.ExitCode -eq 0) "help failed: $($help.Output)"
    Assert-True ($help.Output -match '-DeadlineMinutes') "help should mention -DeadlineMinutes: $($help.Output)"
}
