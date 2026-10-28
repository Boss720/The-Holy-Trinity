. (Join-Path $repoSource 'scripts\lib\scheduler.ps1')

Run-Case 'sched-core: config defaults merge validation and corruption' {
    param($f)
    $p=Get-SchedulerPaths $f.Repo; $c=Get-TrinityConfig $p
    Assert-True ($c.slots.codex -eq 2 -and $c.autopilot.approval -and $c._source.base -eq 'default') 'defaults incorrect'
    $null=Set-TrinityConfig $p @{unknown=@{keep=42};slots=@{codex=4}}
    $c=Set-TrinityConfig $p @{unknown=@{other=7};slots=@{claude=3}}
    Assert-True ($c.unknown.keep -eq 42 -and $c.unknown.other -eq 7 -and $c.slots.codex -eq 4 -and $c.slots.claude -eq 3) 'deep merge failed'
    $threw=$false; try { $null=Set-TrinityConfig $p @{maxRounds=11} } catch { $threw=$true }; Assert-True $threw 'invalid range accepted'
    [IO.File]::WriteAllText((Join-Path $f.Repo '.trinity\trinity.json'),'{broken')
    $c=Get-TrinityConfig $p; Assert-True ($c._error -and $c.slots.codex -eq 2) 'corrupt config did not return defaults and error'
}
Run-Case 'sched-core: queue order lock and stale lock' {
    param($f)
    $p=Get-SchedulerPaths $f.Repo
    foreach ($name in @('one','two','three')) { Add-QueueItem $p @{task=$name;agent='codex'} }
    Move-QueueItem $p 'three' 0; Remove-QueueItem $p 'two'; $q=Get-TrinityQueue $p
    Assert-True (($q.items.task -join ',') -eq 'three,one') 'queue order incorrect'
    $lock=Join-Path $f.Repo '.trinity\queue.lock'; [IO.File]::WriteAllText($lock,'stale'); (Get-Item $lock).LastWriteTime=(Get-Date).AddSeconds(-31)
    $null=Get-TrinityQueue $p; Assert-True (-not (Test-Path $lock)) 'stale lock not removed'
    $stream=[IO.File]::Open($lock,[IO.FileMode]::CreateNew,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    $lib=Join-Path $repoSource 'scripts\lib\scheduler.ps1'
    $job=Start-Job -ScriptBlock { param($lib,$repo) . $lib; $p=Get-SchedulerPaths $repo; Add-QueueItem $p @{task='later';agent='codex'} } -ArgumentList $lib,$f.Repo
    try { Start-Sleep -Seconds 2; Assert-True ($job.State -eq 'Running') 'second writer did not wait' } finally { $stream.Dispose(); Remove-Item $lock -Force; $null=Wait-Job $job -Timeout 10 }
    $errors=@(Receive-Job $job -ErrorAction SilentlyContinue -ErrorVariable jobErrors); Remove-Job $job -Force
    Assert-True (-not $jobErrors -and @((Get-TrinityQueue $p).items | Where-Object { $_.task -eq 'later' }).Count -eq 1) 'waiting writer failed'
}
Run-Case 'sched-core: pause marks all queued items' {
    param($f)
    $p=Get-SchedulerPaths $f.Repo; Add-QueueItem $p @{task='one';agent='codex'}; Add-QueueItem $p @{task='two';agent='codex'}; Set-PauseSwitch $p 'user'
    $r=Invoke-SchedulerTick $p -DispatchCommand { throw 'must not dispatch' }
    Assert-True ($r.waiting.one -eq 'paused' -and $r.waiting.two -eq 'paused' -and @((Get-TrinityQueue $p).items | Where-Object { $_.waiting -eq 'paused' }).Count -eq 2) 'pause failed'
}
Run-Case 'sched-core: slots block then dispatch' {
    param($f)
    $p=Get-SchedulerPaths $f.Repo; $null=Set-TrinityConfig $p @{slots=@{codex=0}}; Add-QueueItem $p @{task='one';agent='codex'}
    $calls=New-Object Collections.ArrayList; $fake={ param($paths,$item,$config) [void]$calls.Add($item.task); return $true }
    $r=Invoke-SchedulerTick $p -DispatchCommand $fake; Assert-True ($r.waiting.one -eq 'no free slot') 'slot did not block'
    $null=Set-TrinityConfig $p @{slots=@{codex=1}}; $r=Invoke-SchedulerTick $p -DispatchCommand $fake
    Assert-True ($calls.Count -eq 1 -and $r.started[0] -eq 'one' -and (Get-TrinityQueue $p).items.Count -eq 0 -and @(Get-Decisions $p 1)[0].action -eq 'started') ("dispatch failed calls=$($calls.Count) started=$($r.started -join ',') queue=$((Get-TrinityQueue $p).items.Count) decisions=$((Get-Decisions $p 1 | ConvertTo-Json -Compress)) waiting=$($r.waiting.one)")
}
Run-Case 'sched-core: running scope blocks overlap' {
    param($f)
    $p=Get-SchedulerPaths $f.Repo; [IO.File]::WriteAllText($p.Board,"## busy`r`n- agent: claude`r`n- scope: src/auth/*`r`n- status: running`r`n")
    Add-QueueItem $p @{task='one';agent='codex';scope='src/auth/forms/*'}; $r=Invoke-SchedulerTick $p -DispatchCommand { throw 'unexpected dispatch' }
    Assert-True ($r.waiting.one -eq 'scope overlaps busy') 'overlap not blocked'
}
Run-Case 'sched-core: autopilot ready resume and limit' {
    param($f)
    $p=Get-SchedulerPaths $f.Repo; $null=Set-TrinityConfig $p @{autopilot=@{enabled=$true;maxConsecutiveFailures=2}}
    foreach ($name in @('done-task','failed-task')) {
        $null=Invoke-Git $f.Repo @('branch', "agent/codex/$name")
        [void][IO.Directory]::CreateDirectory((Join-Path $p.Worktrees "codex-$name"))
        Add-Decision $p $name 'started' 'dispatched' 0
    }
    [IO.File]::WriteAllText($p.Board,"## done-task`r`n- agent: codex`r`n- scope: src/*`r`n- status: done`r`n")
    $r=Invoke-SchedulerTick $p -MergeCommand { param($p,$task,$dry) return $true }; Assert-True ((Get-BoardEntry $p 'done-task').status -match '^ready' -and $r.autopilot[0] -eq 'ready') 'ready failed'
    [IO.File]::WriteAllText($p.Board,"## failed-task`r`n- agent: codex`r`n- status: failed`r`n")
    $calls=New-Object Collections.ArrayList; $r=Invoke-SchedulerTick $p -ResumeCommand { param($p,$task,$file) [void]$calls.Add($task); return $true }
    $d=@(Get-Decisions $p 1)[0]; Assert-True ($calls.Count -eq 1 -and $d.action -eq 'resumed' -and $d.round -eq 1) 'resume failed'
    Add-Decision $p 'a' 'failed' 'failure' 0; Add-Decision $p 'b' 'failed' 'failure' 0; $null=Invoke-SchedulerTick $p
    Assert-True ((Test-PauseSwitch $p).reason -match '^limit:' -and @(Get-Decisions $p 1)[0].action -eq 'limit') 'limit failed'
}
Run-Case 'sched-core: once writes heartbeat' {
    param($f)
    $exe=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $output=& $exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $f.Repo 'scripts\scheduler.ps1') -Repo $f.Repo -Once 2>&1
    Assert-True ($LASTEXITCODE -eq 0) "once failed: $output"
    $h=ConvertFrom-Json ([IO.File]::ReadAllText((Join-Path $f.Repo '.trinity\scheduler.json')))
    Assert-True ($h.pid -gt 0 -and $h.lastTickAt -and $h.processStart) 'heartbeat missing fields'
}

Run-Case 'sched-core: old tasks and missing branches are ignored' {
    param($f)
    $p=Get-SchedulerPaths $f.Repo; $null=Set-TrinityConfig $p @{autopilot=@{enabled=$true}}
    [IO.File]::WriteAllText($p.Board,"## old`r`n- agent: codex`r`n- status: done`r`n")
    $calls=New-Object Collections.ArrayList
    $null=Invoke-SchedulerTick $p -MergeCommand { [void]$calls.Add('merge'); $true }
    [void][IO.Directory]::CreateDirectory((Join-Path $p.Worktrees 'codex-old')); Add-Decision $p 'old' 'started' 'dispatched' 0
    $null=Invoke-SchedulerTick $p -MergeCommand { [void]$calls.Add('merge'); $true }
    Assert-True ($calls.Count -eq 0) 'old or missing branch task acted on'
}
Run-Case 'sched-core: dispatch failure backoff and half success' {
    param($f)
    $p=Get-SchedulerPaths $f.Repo; Add-QueueItem $p @{task='retry';agent='codex';scope='src/*'}
    $calls=New-Object Collections.ArrayList; $fake={ [void]$calls.Add(1); throw 'failure' }
    $null=Invoke-SchedulerTick $p -DispatchCommand $fake; $r=Invoke-SchedulerTick $p -DispatchCommand $fake
    Assert-True ($calls.Count -eq 1 -and $r.waiting.retry -eq 'retry backoff' -and @((Get-Decisions $p 0) | Where-Object { $_.action -eq 'failed' }).Count -eq 1) 'backoff failed'
    [IO.File]::WriteAllText($p.Board,"## retry`r`n- agent: codex`r`n- status: running`r`n")
    $r=Invoke-SchedulerTick $p -DispatchCommand $fake
    Assert-True ($r.waiting.retry -eq 'already dispatched' -and (Get-TrinityQueue $p).items.Count -eq 0) 'half dispatch not removed'
}
Run-Case 'sched-core: conservative glob and unknown scopes' {
    param($f)
    Assert-True ((Test-SchedulerOverlap '' 'src/*') -and (Test-SchedulerOverlap 'unspecified' 'src/*') -and (Test-SchedulerOverlap 'src/fo*.ps1' 'src/foo/*.ps1') -and -not (Test-SchedulerOverlap 'src/a/*' 'src/b/*')) 'scope overlap incorrect'
}
Run-Case 'sched-core: reused pid does not occupy slot' {
    param($f)
    $p=Get-SchedulerPaths $f.Repo; [void][IO.Directory]::CreateDirectory($p.Out)
    [IO.File]::WriteAllText((Join-Path $p.Out 'pid-old.txt'),[string]$PID)
    (Get-Item (Join-Path $p.Out 'pid-old.txt')).LastWriteTime=(Get-Date).AddHours(-1)
    Assert-True ((Get-SchedulerTaskState $p @{task='old';status='done'}) -eq 'done') 'reused pid considered alive'
}
Run-Case 'sched-core: stale rate limit is ignored' {
    param($f)
    $old=$env:CODEX_HOME; $env:CODEX_HOME=Join-Path $f.Root 'codex'; $dir=Join-Path $env:CODEX_HOME 'sessions'; [void][IO.Directory]::CreateDirectory($dir)
    try { $file=Join-Path $dir 'rollout-test.jsonl'; [IO.File]::WriteAllText($file,'{"payload":{"rate_limits":{"primary":{"used_percent":99}}}}'); (Get-Item $file).LastWriteTime=(Get-Date).AddHours(-6); Assert-True (-not (Test-CodexRateLimit)) 'stale rate limit blocked' } finally { $env:CODEX_HOME=$old }
}
Run-Case 'sched-core: default dispatch omits empty options and restores model' {
    param($f)
    $p=Get-SchedulerPaths $f.Repo; Add-QueueItem $p @{task='model';agent='codex';model='test-model'}
    $script:capturedArgs=$null; $script:capturedModel=''; $old=$env:TRINITY_CODEX_MODEL; $env:TRINITY_CODEX_MODEL='original'
    function Invoke-SchedulerChild($paths,[string[]]$arguments) { $script:capturedArgs=$arguments; $script:capturedModel=$env:TRINITY_CODEX_MODEL; return $true }
    try { $null=Invoke-SchedulerTick $p; Assert-True ($script:capturedModel -eq 'test-model' -and $env:TRINITY_CODEX_MODEL -eq 'original' -and '-Scope' -notin $script:capturedArgs -and '-PromptFile' -notin $script:capturedArgs -and '-Model' -notin $script:capturedArgs) 'dispatch arguments or model incorrect' } finally { $env:TRINITY_CODEX_MODEL=$old; Remove-Item Function:Invoke-SchedulerChild }
}
