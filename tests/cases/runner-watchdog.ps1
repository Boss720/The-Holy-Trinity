Run-Case 'runner watchdog: deadline kills hanging worker and marks failed (timed out)' {
    param($f)
    $oldSec = $env:TRINITY_DEADLINE_SECONDS
    try {
        $env:TRINITY_DEADLINE_SECONDS = '2'
        $env:FAKE_CODEX_MODE = 'hang'
        Start-CodexTask $f 'deadline-default'
        $wait = Invoke-Trinity $f @('wait', 'deadline-default', '-Timeout', '30')
        Assert-True ($wait.ExitCode -eq 1) "wait should exit 1 on deadline timeout, got $($wait.ExitCode)"
        Assert-True ($wait.Output -match 'failed \(timed out after 120 min\)') "output should mention timed out: $($wait.Output)"
        $board = Get-Content -Raw (Join-Path $f.Repo '.git\agent-board.md')
        Assert-True ($board -match '- status: failed \(timed out after 120 min\)') "board status should be timed out: $board"
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
    (Get-Item -LiteralPath (Join-Path $outDir 'pid-reuse-ps.txt')).LastWriteTime = (Get-Process -Id $PID).StartTime.AddMinutes(10)
    $waitB = Invoke-Trinity $f @('wait', 'reuse-ps', '-Timeout', '10')
    Assert-True ($waitB.ExitCode -eq 1) "wait should exit 1 on reused powershell PID, got $($waitB.ExitCode)"
    Assert-True ($waitB.Output -match 'runner dead \(pid reused\)') "wait should report runner dead: $($waitB.Output)"

    # Part C: Cancel on reused PID does not kill unrelated process
    Set-CliTask $f 'reuse-cancel' 'running' 'codex'
    [IO.File]::WriteAllText((Join-Path $outDir 'pid-reuse-cancel.txt'), "$PID`r`n", [System.Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $outDir 'task-reuse-cancel.md'), "# Task`r`n", [System.Text.UTF8Encoding]::new($false))
    (Get-Item -LiteralPath (Join-Path $outDir 'pid-reuse-cancel.txt')).LastWriteTime = (Get-Process -Id $PID).StartTime.AddMinutes(10)
    $cancel = Invoke-Trinity $f @('cancel', 'reuse-cancel', '-Force')
    Assert-True ($cancel.Output -match 'runner dead \(pid reused\)') "cancel should report runner dead: $($cancel.Output)"
    $myProc = Get-Process -Id $PID -ErrorAction SilentlyContinue
    Assert-True ($null -ne $myProc) 'cancel must not kill unrelated process'

    # Part D: a powershell started after the pid file was written (PID reused by a newer process)
    $newer = Start-Process powershell.exe -ArgumentList '-NoProfile', '-Command', 'Start-Sleep -Seconds 60' -PassThru -WindowStyle Hidden
    try {
        Set-CliTask $f 'reuse-newer' 'running' 'codex'
        $pidNewer = Join-Path $outDir 'pid-reuse-newer.txt'
        [IO.File]::WriteAllText($pidNewer, "$($newer.Id)`r`n", [System.Text.UTF8Encoding]::new($false))
        (Get-Item -LiteralPath $pidNewer).LastWriteTime = $newer.StartTime.AddMinutes(-5)
        $cancelD = Invoke-Trinity $f @('cancel', 'reuse-newer', '-Force')
        Assert-True ($cancelD.Output -match 'runner dead \(pid reused\)') "cancel should report runner dead: $($cancelD.Output)"
        Assert-True (-not $newer.HasExited) 'cancel killed a newer process that reused the pid'
    }
    finally { if (-not $newer.HasExited) { $newer.Kill() } }
}

Run-Case 'runner watchdog: help text mentions -DeadlineMinutes' {
    param($f)
    $help = Invoke-Trinity $f @('help')
    Assert-True ($help.ExitCode -eq 0) "help failed: $($help.Output)"
    Assert-True ($help.Output -match '-DeadlineMinutes') "help should mention -DeadlineMinutes: $($help.Output)"
}

Run-Case 'runner watchdog: changing files without log output is not a stall' {
    param($f)
    $oldStall = $env:TRINITY_STALL_SECONDS
    try {
        # Allow for slow filesystem scheduling before deciding how long counts as idle.
        $probe = Join-Path $f.Root 'write-probe.txt'
        $writeTime = [Diagnostics.Stopwatch]::StartNew()
        [IO.File]::WriteAllText($probe, 'probe')
        $writeTime.Stop()
        $env:TRINITY_STALL_SECONDS = [string][Math]::Max(2, [Math]::Ceiling($writeTime.Elapsed.TotalSeconds * 4 + 2))
        $env:FAKE_CODEX_MODE = 'quiet-edits'
        Start-CodexTask $f 'quiet-task'
        $boardFile = Join-Path $f.Repo '.git\agent-board.md'
        $stalledSeen = $false
        $deadline = (Get-Date).AddSeconds(60)
        while ((Get-Date) -lt $deadline) {
            $board = Get-Content -Raw $boardFile
            if ($board -match 'status: running \(stalled') { $stalledSeen = $true; break }
            if ($board -match 'status: (done|failed)') { break }
            Start-Sleep -Milliseconds 250
        }
        $wait = Invoke-Trinity $f @('wait', 'quiet-task', '-Timeout', '60')
        Assert-True (-not $stalledSeen) 'a task that keeps editing files was marked stalled'
        Assert-True ($wait.ExitCode -eq 0) "task should finish: $($wait.Output)"
    }
    finally { $env:TRINITY_STALL_SECONDS = $oldStall }
}

Run-Case 'runner watchdog: antigravity idle wait for background task ends as done' {
    param($f)
    $oldIdle = $env:TRINITY_AGY_IDLE_SECONDS
    try {
        $env:TRINITY_AGY_IDLE_SECONDS = '3'
        $env:FAKE_AGY_MODE = 'idle-wait'
        $res = Invoke-Trinity $f @('dispatch', 'antigravity', 'idle-task', '-Scope', '*', '-PromptFile', $f.Prompt)
        Assert-True ($res.ExitCode -eq 0) "dispatch failed: $($res.Output)"
        $wait = Invoke-Trinity $f @('wait', 'idle-task', '-Timeout', '40')
        Assert-True ($wait.ExitCode -eq 0 -and $wait.Output -match 'done') "idle agy not ended as done: $($wait.Output)"
        $result = [IO.File]::ReadAllText((Join-Path $f.Repo '.codex-out\result-idle-task.md'))
        Assert-True ($result -match 'Fake idle summary') "summary not taken from transcript: $result"
    }
    finally { $env:TRINITY_AGY_IDLE_SECONDS = $oldIdle }
}
