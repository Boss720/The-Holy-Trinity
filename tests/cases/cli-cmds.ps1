Run-Case 'cli-cmds: queue round trip and JSON' {
    param($f)
    foreach ($task in @('first-task','second-task')) {
        $r = Invoke-Trinity $f @('queue','add',$task,'-Agent','codex','-Scope','tests/*','-PromptFile',$f.Prompt)
        Assert-True ($r.ExitCode -eq 0) "add failed: $($r.Output)"
    }
    $r = Invoke-Trinity $f @('queue','move','second-task','0')
    Assert-True ($r.ExitCode -eq 0) "move failed: $($r.Output)"
    $r = Invoke-Trinity $f @('queue','list','-Json'); $q = ConvertFrom-Json $r.Output
    Assert-True ($r.ExitCode -eq 0 -and $q.version -eq 1 -and $q.items.Count -eq 2 -and $q.items[0].task -eq 'second-task') "bad queue: $($r.Output)"
    foreach ($task in @('first-task','second-task')) { $r = Invoke-Trinity $f @('queue','remove',$task); Assert-True ($r.ExitCode -eq 0) "remove failed: $($r.Output)" }
    $r = Invoke-Trinity $f @('queue','list','-Json'); $q = ConvertFrom-Json $r.Output
    Assert-True ($q.items.Count -eq 0) 'queue not empty'
    $r = Invoke-Trinity $f @('queue','add','bad-agent','bad-task','-Scope','tests/*','-PromptFile',$f.Prompt)
    Assert-True ($r.ExitCode -ne 0 -and $r.Output -match 'agent') "invalid agent accepted: $($r.Output)"
}
Run-Case 'cli-cmds: pause and autopilot' {
    param($f)
    $r = Invoke-Trinity $f @('pause','limit: test'); $pause = Join-Path $f.Repo '.trinity\PAUSE'
    Assert-True ($r.ExitCode -eq 0 -and (Test-Path $pause) -and [IO.File]::ReadAllText($pause) -match 'limit: test') "pause failed: $($r.Output)"
    $r = Invoke-Trinity $f @('unpause'); Assert-True ($r.ExitCode -eq 0 -and -not (Test-Path $pause)) "unpause failed: $($r.Output)"
    foreach ($state in @('on','off')) {
        $r = Invoke-Trinity $f @('autopilot',$state,'-Approval'); $cfg = ConvertFrom-Json ([IO.File]::ReadAllText((Join-Path $f.Repo '.trinity\trinity.json')))
        Assert-True ($r.ExitCode -eq 0 -and $cfg.autopilot.enabled -eq ($state -eq 'on') -and $cfg.autopilot.approval) "autopilot failed: $($r.Output)"
    }
}
Run-Case 'cli-cmds: scheduler status and empty tick' {
    param($f)
    $r = Invoke-Trinity $f @('scheduler','status'); Assert-True ($r.ExitCode -eq 0 -and $r.Output -match 'not running') "status failed: $($r.Output)"
    $r = Invoke-Trinity $f @('scheduler','tick'); Assert-True ($r.ExitCode -eq 0 -and $r.Output -match '0 started') "tick failed: $($r.Output)"
    Assert-True (-not (Test-Path (Join-Path $f.Repo '.codex-out\run-*.cmd'))) 'unexpected dispatch'
}
Run-Case 'cli-cmds: history filtering and help' {
    param($f)
    Set-CliTask $f 'merged-task' 'merged 2026-10-28 12:00'
    Set-CliTask $f 'failed-task' 'failed 2026-10-28 11:00'
    $r = Invoke-Trinity $f @('history','-Json','-Outcome','merged'); $items = @(ConvertFrom-Json $r.Output)
    Assert-True ($r.ExitCode -eq 0 -and $items.Count -eq 1 -and $items[0].task -eq 'merged-task') "history failed: $($r.Output)"
    $r = Invoke-Trinity $f @('help')
    foreach ($name in @('queue','scheduler','pause','unpause','autopilot','history')) { Assert-True ($r.Output -match "(?m)^\s+$name\b") "help missing $name" }
}
Run-Case 'cli-cmds: bad input fails with a message' {
    param($f)
    $r = Invoke-Trinity $f @('queue','add','some-task','-Agent','nobody','-Scope','tests/*','-PromptFile',$f.Prompt)
    Assert-True ($r.ExitCode -ne 0 -and $r.Output -match 'agent') "bad -Agent accepted: $($r.Output)"
    $r = Invoke-Trinity $f @('queue','add','some-task','-Agent','codex','-PromptFile',$f.Prompt)
    Assert-True ($r.ExitCode -ne 0 -and $r.Output -match 'Scope') "missing scope accepted: $($r.Output)"
    $r = Invoke-Trinity $f @('queue','remove','ghost'); Assert-True ($r.ExitCode -ne 0) 'removing a missing task exited 0'
    $r = Invoke-Trinity $f @('queue','move','ghost','0'); Assert-True ($r.ExitCode -ne 0) 'moving a missing task exited 0'
    $r = Invoke-Trinity $f @('autopilot','maybe'); Assert-True ($r.ExitCode -ne 0 -and $r.Output -match 'usage') "bad autopilot arg: $($r.Output)"
    $r = Invoke-Trinity $f @('scheduler','bogus'); Assert-True ($r.ExitCode -ne 0 -and $r.Output -match 'usage') "bad scheduler arg: $($r.Output)"
    $r = Invoke-Trinity $f @('scheduler','stop'); Assert-True ($r.ExitCode -eq 0 -and $r.Output -match 'not running') "stop with no scheduler: $($r.Output)"
}
Run-Case 'cli-cmds: history shows decisions and -Agent filter' {
    param($f)
    $r = Invoke-Trinity $f @('autopilot','on'); Assert-True ($r.ExitCode -eq 0) "autopilot failed: $($r.Output)"
    Set-CliTask $f 'failed-task' 'failed 2026-10-28 11:00'
    $r = Invoke-Trinity $f @('history','-Json'); $items = @(ConvertFrom-Json $r.Output)
    Assert-True ($r.ExitCode -eq 0 -and @($items | Where-Object { $_.type -eq 'decision' }).Count -ge 1 -and @($items | Where-Object { $_.task -eq 'failed-task' -and $_.outcome -eq 'failed' }).Count -eq 1) "history lacks entries: $($r.Output)"
    $r = Invoke-Trinity $f @('history','-Json','-Agent','claude')
    Assert-True ($r.ExitCode -eq 0 -and $r.Output -notmatch 'task') "agent filter leaked: $($r.Output)"
    $r = Invoke-Trinity $f @('history','-Outcome','bogus'); Assert-True ($r.ExitCode -ne 0) 'bad outcome accepted'
}

Run-Case 'cli-cmds: scheduler tick skips when daemon mutex is held and preserves heartbeat' {
    param($f)
    $bytes = [Text.Encoding]::UTF8.GetBytes(([IO.Path]::GetFullPath($f.Repo)).ToLowerInvariant())
    $hash = [Security.Cryptography.SHA256]::Create(); try { $mName = ([BitConverter]::ToString($hash.ComputeHash($bytes))).Replace('-', '') } finally { $hash.Dispose() }
    $owned = $false
    $mutex = New-Object Threading.Mutex($true, ('Local\TrinityScheduler-' + $mName), [ref]$owned)
    try {
        $r = Invoke-Trinity $f @('scheduler', 'tick')
        Assert-True ($r.ExitCode -eq 0 -and $r.Output -match 'scheduler is running; tick skipped') "tick with held mutex did not skip: $($r.Output)"
    } finally {
        if ($owned) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
    $hbPath = Join-Path $f.Repo '.trinity\scheduler.json'
    [void][IO.Directory]::CreateDirectory((Split-Path $hbPath))
    $fake = @{pid=99999;startedAt='2026-10-28T10:00:00Z';processStart='2026-10-28T10:00:00Z';lastTickAt='2026-10-28T10:00:00Z';now='idle';next=''}
    [IO.File]::WriteAllText($hbPath, (ConvertTo-Json -InputObject $fake -Depth 10), (New-Object Text.UTF8Encoding($false)))
    $r = Invoke-Trinity $f @('scheduler', 'tick')
    Assert-True ($r.ExitCode -eq 0) "tick failed: $($r.Output)"
    $after = ConvertFrom-Json ([IO.File]::ReadAllText($hbPath))
    Assert-True ($after.pid -eq 99999) "manual tick overwrote heartbeat: $($after.pid)"
    Remove-Item -LiteralPath $hbPath -Force
    $r = Invoke-Trinity $f @('scheduler', 'tick')
    Assert-True ($r.ExitCode -eq 0 -and -not (Test-Path -LiteralPath $hbPath)) 'manual tick wrote a heartbeat when none existed'
}

Run-Case 'cli-cmds: scheduler stop and start respect processStart regardless of lastTickAt' {
    param($f)
    $hbPath = Join-Path $f.Repo '.trinity\scheduler.json'
    [void][IO.Directory]::CreateDirectory((Split-Path $hbPath))
    $proc = Get-Process -Id $PID
    $oldTick = (Get-Date).AddSeconds(-150).ToString('o')
    $busy = @{pid=$PID;startedAt=$proc.StartTime.ToString('o');processStart=$proc.StartTime.ToString('o');lastTickAt=$oldTick;now='busy gate';next=''}
    [IO.File]::WriteAllText($hbPath, (ConvertTo-Json -InputObject $busy -Depth 10), (New-Object Text.UTF8Encoding($false)))
    $r = Invoke-Trinity $f @('scheduler', 'stop')
    $stopPath = Join-Path $f.Repo '.trinity\scheduler.stop'
    Assert-True ($r.ExitCode -eq 0 -and $r.Output -match 'Scheduler stop requested.' -and (Test-Path -LiteralPath $stopPath)) "stop failed on busy daemon: $($r.Output)"
    $r = Invoke-Trinity $f @('scheduler', 'start')
    Assert-True ($r.ExitCode -ne 0 -and $r.Output -match 'Scheduler already running' -and (Test-Path -LiteralPath $stopPath)) "start did not refuse or deleted stop file: $($r.Output)"
    $dead = @{pid=999999;startedAt='2026-10-28T10:00:00Z';processStart='2026-10-28T10:00:00Z';lastTickAt=$oldTick;now='dead';next=''}
    [IO.File]::WriteAllText($hbPath, (ConvertTo-Json -InputObject $dead -Depth 10), (New-Object Text.UTF8Encoding($false)))
    $r = Invoke-Trinity $f @('scheduler', 'stop')
    Assert-True ($r.ExitCode -eq 0 -and $r.Output -match 'not running') "stop reported alive for dead pid: $($r.Output)"
}

Run-Case 'cli-cmds: scheduler tick dispatch model fallback for codex and antigravity' {
    param($f)
    $cfgPath = Join-Path $f.Repo '.trinity\trinity.json'
    $cfg = @{version=1;slots=@{codex=2;antigravity=2;claude=1};models=@{codex='cfg-codex';antigravity='cfg-agy'}}
    [void][IO.Directory]::CreateDirectory((Split-Path $cfgPath))
    [IO.File]::WriteAllText($cfgPath, (ConvertTo-Json -InputObject $cfg -Depth 10), (New-Object Text.UTF8Encoding($false)))
    $r1 = Invoke-Trinity $f @('queue', 'add', 'item-codex', '-Agent', 'codex', '-Scope', 'tests/a/*', '-PromptFile', $f.Prompt)
    $r2 = Invoke-Trinity $f @('queue', 'add', 'item-agy', '-Agent', 'antigravity', '-Scope', 'tests/b/*', '-PromptFile', $f.Prompt)
    $r3 = Invoke-Trinity $f @('queue', 'add', 'item-custom', '-Agent', 'antigravity', '-Scope', 'tests/c/*', '-PromptFile', $f.Prompt, '-Model', 'custom-agy')
    Assert-True ($r1.ExitCode -eq 0 -and $r2.ExitCode -eq 0 -and $r3.ExitCode -eq 0) "queue add failed: $($r1.Output) $($r2.Output) $($r3.Output)"
    $r = Invoke-Trinity $f @('scheduler', 'tick')
    Assert-True ($r.ExitCode -eq 0 -and $r.Output -match '3 started') "tick failed to dispatch: $($r.Output)"
    foreach ($t in @('item-codex', 'item-agy', 'item-custom')) {
        $w = Invoke-Trinity $f @('wait', $t, '-Timeout', '30')
        Assert-True ($w.ExitCode -eq 0) "wait $t failed: $($w.Output)"
    }
    $runCodex = [IO.File]::ReadAllText((Join-Path $f.Repo '.codex-out\run-item-codex.cmd'))
    $runAgy = [IO.File]::ReadAllText((Join-Path $f.Repo '.codex-out\run-item-agy.cmd'))
    $runCustom = [IO.File]::ReadAllText((Join-Path $f.Repo '.codex-out\run-item-custom.cmd'))
    Assert-True ($runCodex -match '-c model=cfg-codex') "codex model fallback failed: $runCodex"
    Assert-True ($runAgy -match '--model cfg-agy') "antigravity model fallback failed: $runAgy"
    Assert-True ($runCustom -match '--model custom-agy') "antigravity custom model failed: $runCustom"
}

Run-Case 'cli-cmds: autopilot on keeps approval and -NoApproval disables it' {
    param($f)
    $cfgPath = Join-Path $f.Repo '.trinity\trinity.json'
    $r = Invoke-Trinity $f @('autopilot', 'on', '-Approval')
    $c = ConvertFrom-Json ([IO.File]::ReadAllText($cfgPath))
    Assert-True ($r.ExitCode -eq 0 -and $c.autopilot.enabled -and $c.autopilot.approval) "autopilot on -Approval failed: $($r.Output)"
    $r = Invoke-Trinity $f @('autopilot', 'on', '-NoApproval')
    $c = ConvertFrom-Json ([IO.File]::ReadAllText($cfgPath))
    Assert-True ($r.ExitCode -eq 0 -and $c.autopilot.enabled -and -not $c.autopilot.approval) "autopilot on -NoApproval failed: $($r.Output)"
    $r = Invoke-Trinity $f @('autopilot', 'off')
    $c = ConvertFrom-Json ([IO.File]::ReadAllText($cfgPath))
    Assert-True ($r.ExitCode -eq 0 -and -not $c.autopilot.enabled -and -not $c.autopilot.approval) "autopilot off altered approval: $($r.Output)"
    $r = Invoke-Trinity $f @('autopilot', 'on')
    $c = ConvertFrom-Json ([IO.File]::ReadAllText($cfgPath))
    Assert-True ($r.ExitCode -eq 0 -and $c.autopilot.enabled -and -not $c.autopilot.approval) "autopilot on did not preserve approval: $($r.Output)"
    $r = Invoke-Trinity $f @('autopilot', 'on', '-Approval', '-NoApproval')
    Assert-True ($r.ExitCode -ne 0 -and $r.Output -match 'cannot specify both') "conflicting switches accepted: $($r.Output)"
    $r = Invoke-Trinity $f @('help')
    Assert-True ($r.Output -match 'autopilot on\|off \[-Approval\|-NoApproval\]') "help missing -NoApproval: $($r.Output)"
}

Run-Case 'cli-cmds: history de-duplicates task and decision rows with same outcome' {
    param($f)
    Set-CliTask $f 'task-merged' 'merged 2026-10-28 12:00'
    Set-CliTask $f 'task-failed' 'failed 2026-10-28 11:00'
    $decPath = Join-Path $f.Repo '.trinity\decisions.jsonl'
    [void][IO.Directory]::CreateDirectory((Split-Path $decPath))
    $d1 = @{at='2026-10-28T12:00:00Z';task='task-merged';action='merged';reason='clean';round=0} | ConvertTo-Json -Compress
    $d2 = @{at='2026-10-28T11:50:00Z';task='task-merged';action='started';reason='started';round=0} | ConvertTo-Json -Compress
    $d3 = @{at='2026-10-28T11:00:00Z';task='task-failed';action='failed';reason='failed';round=0} | ConvertTo-Json -Compress
    $d4 = @{at='2026-10-28T10:00:00Z';task='other-task';action='merged';reason='clean';round=0} | ConvertTo-Json -Compress
    [IO.File]::WriteAllText($decPath, "$d1`r`n$d2`r`n$d3`r`n$d4`r`n", (New-Object Text.UTF8Encoding($false)))
    $r = Invoke-Trinity $f @('history', '-Json')
    Assert-True ($r.ExitCode -eq 0) "history failed: $($r.Output)"
    $items = @(ConvertFrom-Json $r.Output)
    Assert-True (@($items | Where-Object { $_.task -eq 'task-merged' -and $_.outcome -eq 'merged' }).Count -eq 1) "task-merged not deduplicated: $($r.Output)"
    Assert-True (@($items | Where-Object { $_.task -eq 'task-merged' -and $_.outcome -eq 'started' }).Count -eq 1) "task-merged started decision lost: $($r.Output)"
    Assert-True (@($items | Where-Object { $_.task -eq 'task-failed' -and $_.outcome -eq 'failed' }).Count -eq 1) "task-failed not deduplicated: $($r.Output)"
    Assert-True (@($items | Where-Object { $_.task -eq 'other-task' -and $_.outcome -eq 'merged' }).Count -eq 1) "other-task lost: $($r.Output)"
}

Run-Case 'cli-cmds: scheduler tick respects environment model overrides' {
    param($f)
    $cfgPath = Join-Path $f.Repo '.trinity\trinity.json'
    [void][IO.Directory]::CreateDirectory((Split-Path $cfgPath))
    $cfg = @{version=1;slots=@{codex=1;antigravity=1;claude=1};models=@{codex='cfg-codex';antigravity='cfg-agy'}}
    [IO.File]::WriteAllText($cfgPath, (ConvertTo-Json -InputObject $cfg -Depth 10), (New-Object Text.UTF8Encoding($false)))
    $env:TRINITY_CODEX_MODEL = 'env-codex'; $env:TRINITY_AGY_MODEL = 'env-agy'
    foreach ($pair in @(@('codex','env-codex-task'), @('antigravity','env-agy-task'))) {
        $r = Invoke-Trinity $f @('queue','add',$pair[1],'-Agent',$pair[0],'-Scope',('tests/' + $pair[0] + '/*'),'-PromptFile',$f.Prompt)
        Assert-True ($r.ExitCode -eq 0) "queue failed: $($r.Output)"
    }
    $r = Invoke-Trinity $f @('scheduler','tick')
    Assert-True ($r.ExitCode -eq 0 -and $r.Output -match '2 started') "tick failed: $($r.Output)"
    foreach ($task in @('env-codex-task','env-agy-task')) {
        $r = Invoke-Trinity $f @('wait',$task,'-Timeout','30')
        Assert-True ($r.ExitCode -eq 0) "wait failed: $($r.Output)"
    }
    $codex = [IO.File]::ReadAllText((Join-Path $f.Repo '.codex-out\run-env-codex-task.cmd'))
    $agy = [IO.File]::ReadAllText((Join-Path $f.Repo '.codex-out\run-env-agy-task.cmd'))
    Assert-True ($codex -match '-c model=env-codex' -and $agy -match '--model env-agy') "environment models lost: $codex $agy"
}

Run-Case 'cli-cmds: scheduler start reports immediate daemon failure' {
    param($f)
    $scheduler = Join-Path $f.Repo 'scripts\scheduler.ps1'
    [IO.File]::WriteAllText($scheduler, "exit 23`r`n", (New-Object Text.UTF8Encoding($true)))
    $r = Invoke-Trinity $f @('scheduler','start')
    Assert-True ($r.ExitCode -ne 0 -and $r.Output -match 'Scheduler failed to start' -and $r.Output -notmatch 'Scheduler starting') "immediate failure misreported: $($r.Output)"
}
