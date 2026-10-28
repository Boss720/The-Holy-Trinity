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
