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
    foreach ($name in @('one','two','three')) { Add-QueueItem $p @{task=$name;agent='codex';promptFile=$f.Prompt} }
    Move-QueueItem $p 'three' 0; Remove-QueueItem $p 'two'; $q=Get-TrinityQueue $p
    Assert-True (($q.items.task -join ',') -eq 'three,one') 'queue order incorrect'
    $lock=Join-Path $f.Repo '.trinity\queue.lock'; [IO.File]::WriteAllText($lock,'stale'); (Get-Item $lock).LastWriteTime=(Get-Date).AddSeconds(-31)
    $null=Get-TrinityQueue $p; Assert-True (-not (Test-Path $lock)) 'stale lock not removed'
    $stream=[IO.File]::Open($lock,[IO.FileMode]::CreateNew,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    $lib=Join-Path $repoSource 'scripts\lib\scheduler.ps1'
    $job=Start-Job -ScriptBlock { param($lib,$repo) . $lib; $p=Get-SchedulerPaths $repo; Add-QueueItem $p @{task='later';agent='codex';promptFile=(Join-Path $repo 'tests\prompt.md')} } -ArgumentList $lib,$f.Repo
    try { Start-Sleep -Seconds 2; Assert-True ($job.State -eq 'Running') 'second writer did not wait' } finally { $stream.Dispose(); Remove-Item $lock -Force; $null=Wait-Job $job -Timeout 10 }
    $errors=@(Receive-Job $job -ErrorAction SilentlyContinue -ErrorVariable jobErrors); Remove-Job $job -Force
    Assert-True (-not $jobErrors -and @((Get-TrinityQueue $p).items | Where-Object { $_.task -eq 'later' }).Count -eq 1) 'waiting writer failed'
}
Run-Case 'sched-core: pause marks all queued items' {
    param($f)
    $p=Get-SchedulerPaths $f.Repo; Add-QueueItem $p @{task='one';agent='codex';promptFile=$f.Prompt}; Add-QueueItem $p @{task='two';agent='codex';promptFile=$f.Prompt}; Set-PauseSwitch $p 'user'
    $r=Invoke-SchedulerTick $p -DispatchCommand { throw 'must not dispatch' }
    Assert-True ($r.waiting.one -eq 'paused' -and $r.waiting.two -eq 'paused' -and @((Get-TrinityQueue $p).items | Where-Object { $_.waiting -eq 'paused' }).Count -eq 2) 'pause failed'
}
Run-Case 'sched-core: slots block then dispatch' {
    param($f)
    $p=Get-SchedulerPaths $f.Repo; $null=Set-TrinityConfig $p @{slots=@{codex=0}}; Add-QueueItem $p @{task='one';agent='codex';promptFile=$f.Prompt}
    $calls=New-Object Collections.ArrayList; $fake={ param($paths,$item,$config) [void]$calls.Add($item.task); return $true }
    $r=Invoke-SchedulerTick $p -DispatchCommand $fake; Assert-True ($r.waiting.one -eq 'no free slot') 'slot did not block'
    $null=Set-TrinityConfig $p @{slots=@{codex=1}}; $r=Invoke-SchedulerTick $p -DispatchCommand $fake
    Assert-True ($calls.Count -eq 1 -and $r.started[0] -eq 'one' -and (Get-TrinityQueue $p).items.Count -eq 0 -and @(Get-Decisions $p 1)[0].action -eq 'started') ("dispatch failed calls=$($calls.Count) started=$($r.started -join ',') queue=$((Get-TrinityQueue $p).items.Count) decisions=$((Get-Decisions $p 1 | ConvertTo-Json -Compress)) waiting=$($r.waiting.one)")
}
Run-Case 'sched-core: running scope blocks overlap' {
    param($f)
    $p=Get-SchedulerPaths $f.Repo; [void][IO.Directory]::CreateDirectory((Join-Path $p.Worktrees 'claude-busy')); [IO.File]::WriteAllText($p.Board,"## busy`r`n- agent: claude`r`n- scope: src/auth/*`r`n- status: running`r`n")
    Add-QueueItem $p @{task='one';agent='codex';promptFile=$f.Prompt;scope='src/auth/forms/*'}; $r=Invoke-SchedulerTick $p -DispatchCommand { throw 'unexpected dispatch' }
    Assert-True ($r.waiting.one -eq 'scope overlaps busy') 'overlap not blocked'
}
Run-Case 'sched-core: autopilot ready resume and limit' {
    param($f)
    $p=Get-SchedulerPaths $f.Repo; $null=Set-TrinityConfig $p @{autopilot=@{enabled=$true;maxConsecutiveFailures=2}}
    foreach ($name in @('done-task','failed-task')) {
        $null=Invoke-Git $f.Repo @('branch', "agent/codex/$name")
        [void][IO.Directory]::CreateDirectory((Join-Path $p.Worktrees "codex-$name"))
        Set-SchedulerStarted $p $name $true; Add-Decision $p $name 'started' 'dispatched' 0
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
    $p=Get-SchedulerPaths $f.Repo; Add-QueueItem $p @{task='retry';agent='codex';promptFile=$f.Prompt;scope='src/*'}
    $calls=New-Object Collections.ArrayList; $fake={ [void]$calls.Add(1); throw 'failure' }
    $null=Invoke-SchedulerTick $p -DispatchCommand $fake; $r=Invoke-SchedulerTick $p -DispatchCommand $fake
    Assert-True ($calls.Count -eq 1 -and $r.waiting.retry -eq 'retry backoff' -and @((Get-Decisions $p 0) | Where-Object { $_.action -eq 'failed' }).Count -eq 1) 'backoff failed'
    [void][IO.Directory]::CreateDirectory((Join-Path $p.Worktrees 'codex-retry')); [IO.File]::WriteAllText($p.Board,"## retry`r`n- agent: codex`r`n- status: running`r`n")
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
    $p=Get-SchedulerPaths $f.Repo; Add-QueueItem $p @{task='model';agent='codex';promptFile=$f.Prompt;model='test-model'}
    $script:capturedArgs=$null; $script:capturedModel=''; $old=$env:TRINITY_CODEX_MODEL; $env:TRINITY_CODEX_MODEL='original'
    function Invoke-SchedulerChild($paths,[string[]]$arguments) { $script:capturedArgs=$arguments; $script:capturedModel=$env:TRINITY_CODEX_MODEL; return $true }
    try { $null=Invoke-SchedulerTick $p; Assert-True ($script:capturedModel -eq 'test-model' -and $env:TRINITY_CODEX_MODEL -eq 'original' -and '-Scope' -notin $script:capturedArgs -and '-PromptFile' -in $script:capturedArgs -and '-Model' -notin $script:capturedArgs) 'dispatch arguments or model incorrect' } finally { $env:TRINITY_CODEX_MODEL=$old; Remove-Item Function:Invoke-SchedulerChild }
}

Run-Case 'sched-core: unpause resets failure limit' {
    param($f)
    $p=Get-SchedulerPaths $f.Repo; $null=Set-TrinityConfig $p @{autopilot=@{enabled=$true;maxConsecutiveFailures=1}}
    Add-Decision $p 'old' 'failed' 'failure' 0; $null=Invoke-SchedulerTick $p
    Assert-True (Test-PauseSwitch $p).paused 'limit did not pause'
    Clear-PauseSwitch $p; $null=Invoke-SchedulerTick $p
    Assert-True (-not (Test-PauseSwitch $p).paused -and @((Get-Decisions $p 0) | Where-Object { $_.action -eq 'unpaused' }).Count -eq 1) 'unpause did not reset failure count'
}
Run-Case 'sched-core: missing prompt rejected and legacy item waits' {
    param($f)
    $p=Get-SchedulerPaths $f.Repo; $threw=$false
    try { Add-QueueItem $p @{task='bad';agent='codex'} } catch { $threw=$_.Exception.Message -match 'promptFile' }
    Assert-True $threw 'empty prompt accepted'
    $threw=$false; try { Add-QueueItem $p @{task='bad';agent='codex';promptFile='missing'} } catch { $threw=$true }; Assert-True $threw 'missing prompt accepted'
    Write-TrinityJson (Join-Path $p.Main '.trinity\queue.json') @{version=1;items=@(@{task='legacy';agent='codex';promptFile='';scope=''})}
    $r=Invoke-SchedulerTick $p -DispatchCommand { throw 'unexpected dispatch' }
    Assert-True ($r.waiting.legacy -eq 'waiting: no prompt file' -and @((Get-Decisions $p 0) | Where-Object { $_.action -eq 'failed' }).Count -eq 0) 'legacy item was attempted'
}
Run-Case 'sched-core: recovered dispatch becomes autopilot eligible' {
    param($f)
    $p=Get-SchedulerPaths $f.Repo; $null=Set-TrinityConfig $p @{autopilot=@{enabled=$true;maxConsecutiveFailures=1}}
    Add-Decision $p 'half' 'failed' 'dispatch: failed' 0
    Add-QueueItem $p @{task='half';agent='codex';promptFile=$f.Prompt}
    $null=Invoke-Git $f.Repo @('branch','agent/codex/half'); [void][IO.Directory]::CreateDirectory((Join-Path $p.Worktrees 'codex-half'))
    [IO.File]::WriteAllText($p.Board,"## half`r`n- agent: codex`r`n- status: done`r`n")
    $r=Invoke-SchedulerTick $p -MergeCommand { $true }; if ($r.autopilot -notcontains 'ready') { $r=Invoke-SchedulerTick $p -MergeCommand { $true } }
    Assert-True (-not (Test-PauseSwitch $p).paused -and $r.autopilot -contains 'ready' -and @((Get-Decisions $p 0) | Where-Object { $_.task -eq 'half' -and $_.action -eq 'started' }).Count -eq 1) 'recovered task not eligible'
}
Run-Case 'sched-core: successful dispatch survives concurrent queue removal' {
    param($f)
    $p=Get-SchedulerPaths $f.Repo; Add-QueueItem $p @{task='gone';agent='codex';promptFile=$f.Prompt}
    $r=Invoke-SchedulerTick $p -DispatchCommand { param($paths,$item) Remove-QueueItem $paths $item.task; $true }
    $d=@(Get-Decisions $p 0); Assert-True ($r.started -contains 'gone' -and @($d | Where-Object { $_.action -eq 'started' }).Count -eq 1 -and @($d | Where-Object { $_.action -eq 'failed' }).Count -eq 0) 'successful dispatch misclassified'
}
Run-Case 'sched-core: corrupt queue recovery' {
    param($f)
    $p=Get-SchedulerPaths $f.Repo; [void][IO.Directory]::CreateDirectory((Join-Path $p.Main '.trinity')); [IO.File]::WriteAllText((Join-Path $p.Main '.trinity\queue.json'),'{broken')
    $q=Get-TrinityQueue $p
    Assert-True ($q.items.Count -eq 0 -and @(Get-ChildItem (Join-Path $p.Main '.trinity') -Filter 'queue.json.corrupt-*').Count -eq 1 -and @(Get-Decisions $p 1)[0].reason -eq 'corrupt queue recovered') 'corrupt queue recovery failed'
}
Run-Case 'sched-core: stalled status takes precedence' {
    param($f)
    $p=Get-SchedulerPaths $f.Repo; Assert-True ((Get-SchedulerTaskState $p @{task='x';status='running (stalled: timeout)'}) -eq 'stalled') 'stalled classified running'
}
Run-Case 'sched-core: daemon records tick error' {
    param($f)
    $dir=Join-Path $f.Repo '.trinity'; [void][IO.Directory]::CreateDirectory($dir)
    [IO.File]::WriteAllText((Join-Path $dir 'trinity.json'),'{"slots":null}')
    $exe=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $output=& $exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $f.Repo 'scripts\scheduler.ps1') -Repo $f.Repo -Once 2>&1
    $h=ConvertFrom-Json ([IO.File]::ReadAllText((Join-Path $dir 'scheduler.json')))
    Assert-True ($LASTEXITCODE -eq 0 -and $h.now -match '^error:' -and (Test-Path (Join-Path $f.Repo '.codex-out\scheduler-error.log'))) "tick error not recorded: $output"
}

Run-Case 'sched-core: cancelled and merged entries can be requeued' {
    param($f)
    $p=Get-SchedulerPaths $f.Repo; $calls=New-Object Collections.ArrayList
    foreach ($state in @('cancelled','merged')) {
        [IO.File]::WriteAllText($p.Board,"## $state`r`n- agent: codex`r`n- status: $state`r`n")
        Add-QueueItem $p @{task=$state;agent='codex';promptFile=$f.Prompt;scope='src/*'}
        $null=Invoke-SchedulerTick $p -DispatchCommand { param($paths,$item) [void]$calls.Add($item.task); $true }
    }
    Assert-True (($calls -join ',') -eq 'cancelled,merged') 'terminal entries prevented dispatch'
}
Run-Case 'sched-core: tracked and missing worktrees count correctly' {
    param($f)
    $p=Get-SchedulerPaths $f.Repo; $recent=(Get-Date).ToString('yyyy-MM-dd HH:mm'); $old=(Get-Date).AddHours(-3).ToString('yyyy-MM-dd HH:mm')
    [IO.File]::WriteAllText($p.Board,"## tracked`r`n- agent: claude`r`n- branch: -`r`n- worktree: -`r`n- scope: unspecified`r`n- status: working: test $recent`r`n## stale`r`n- agent: codex`r`n- branch: -`r`n- worktree: -`r`n- status: working: test $old`r`n## missing`r`n- agent: codex`r`n- worktree: missing-path`r`n- status: running`r`n")
    $slots=Get-SlotUse $p (Get-TrinityConfig $p); Assert-True ($slots.claude.used -eq 1 -and $slots.codex.used -eq 0) 'tracked or missing slot count incorrect'
    Add-QueueItem $p @{task='new';agent='codex';promptFile=$f.Prompt}; $r=Invoke-SchedulerTick $p -DispatchCommand { $true }
    Assert-True ($r.started -contains 'new') 'tracked or missing worktree blocked overlap'
}
Run-Case 'sched-core: limits checked before each dispatch' {
    param($f)
    $p=Get-SchedulerPaths $f.Repo; $null=Set-TrinityConfig $p @{autopilot=@{enabled=$true;maxTasksPerHour=1;maxConsecutiveFailures=1}}
    foreach ($name in @('one','two')) { Add-QueueItem $p @{task=$name;agent='codex';promptFile=$f.Prompt;scope="$name/*"} }
    $calls=New-Object Collections.ArrayList; $r=Invoke-SchedulerTick $p -DispatchCommand { param($paths,$item) [void]$calls.Add($item.task); $true }
    Assert-True ($calls.Count -eq 1 -and (Test-PauseSwitch $p).paused -and $r.waiting.two -eq 'paused') 'hourly limit allowed second dispatch'
    Clear-PauseSwitch $p; $r=Invoke-SchedulerTick $p -DispatchCommand { $true }
    Assert-True ($r.started -contains 'two') 'unpause did not reset hourly count'
}
Run-Case 'sched-core: failure limit checked during queue' {
    param($f)
    $p=Get-SchedulerPaths $f.Repo; $null=Set-TrinityConfig $p @{autopilot=@{enabled=$true;maxConsecutiveFailures=1}}
    foreach ($name in @('one','two')) { Add-QueueItem $p @{task=$name;agent='codex';promptFile=$f.Prompt;scope="$name/*"} }
    $calls=New-Object Collections.ArrayList; $r=Invoke-SchedulerTick $p -DispatchCommand { [void]$calls.Add(1); throw 'bad' }
    Assert-True ($calls.Count -eq 1 -and (Test-PauseSwitch $p).paused -and $r.waiting.two -eq 'paused') 'failure limit allowed second dispatch'
}
Run-Case 'sched-core: configured models and ignored explicit model' {
    param($f)
    $p=Get-SchedulerPaths $f.Repo; $null=Set-TrinityConfig $p @{models=@{codex='configured';claude='configured-claude'}}
    $script:modelsSeen=New-Object Collections.ArrayList
    function Invoke-SchedulerChild($paths,[string[]]$arguments) { [void]$script:modelsSeen.Add($env:TRINITY_CODEX_MODEL); return $true }
    $old=$env:TRINITY_CODEX_MODEL; $env:TRINITY_CODEX_MODEL='original'
    try {
        Add-QueueItem $p @{task='c';agent='codex';promptFile=$f.Prompt;scope='c/*'}; $null=Invoke-SchedulerTick $p
        Add-QueueItem $p @{task='a';agent='claude';promptFile=$f.Prompt;model='explicit';scope='a/*'}; $null=Invoke-SchedulerTick $p
        Assert-True ($script:modelsSeen[0] -eq 'configured' -and $script:modelsSeen[1] -eq 'original' -and $env:TRINITY_CODEX_MODEL -eq 'original') 'model environment incorrect'
        Assert-True (@((Get-Decisions $p 0) | Where-Object { $_.task -eq 'a' -and $_.reason -eq 'model ignored for claude' }).Count -eq 1) 'ignored model decision missing'
    } finally { $env:TRINITY_CODEX_MODEL=$old; Remove-Item Function:Invoke-SchedulerChild }
}
Run-Case 'sched-core: default merge dry run is supported' {
    param($f)
    $p=Get-SchedulerPaths $f.Repo; $null=Set-TrinityConfig $p @{autopilot=@{enabled=$true}}
    $null=Invoke-Git $f.Repo @('branch','agent/codex/done'); [void][IO.Directory]::CreateDirectory((Join-Path $p.Worktrees 'codex-done')); Set-SchedulerStarted $p 'done' $true; Add-Decision $p 'done' 'started' 'dispatched' 0
    [IO.File]::WriteAllText($p.Board,"## done`r`n- agent: codex`r`n- status: done`r`n")
    $script:mergeArgs=@(); function Invoke-SchedulerChild($paths,[string[]]$arguments) { $script:mergeArgs=$arguments; return $true }
    try { $null=Invoke-SchedulerTick $p; Assert-True ($script:mergeArgs -contains '-DryRun' -and ([IO.File]::ReadAllText((Join-Path $repoSource 'scripts\trinity.ps1')) -match '\[switch\]\s*\$DryRun')) 'dry run missing from command or parameter block' } finally { Remove-Item Function:Invoke-SchedulerChild }
}

Run-Case 'sched-core: queue sharing violation preserves file' {
    param($f)
    $p=Get-SchedulerPaths $f.Repo; Add-QueueItem $p @{task='locked';agent='codex';promptFile=$f.Prompt}
    $path=Join-Path $p.Main '.trinity\queue.json'; $stream=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None); $threw=$false
    try { try { $null=Get-TrinityQueue $p } catch { $threw=$true } } finally { $stream.Dispose() }
    Assert-True ($threw -and (Test-Path $path) -and (Get-TrinityQueue $p).items[0].task -eq 'locked' -and @(Get-ChildItem (Split-Path $path) -Filter 'queue.json.corrupt-*').Count -eq 0) 'locked queue was lost'
}
Run-Case 'sched-core: gate errors wait and findings resume' {
    param($f)
    $p=Get-SchedulerPaths $f.Repo; $null=Set-TrinityConfig $p @{autopilot=@{enabled=$true}}
    $null=Invoke-Git $f.Repo @('branch','agent/codex/gate'); [void][IO.Directory]::CreateDirectory((Join-Path $p.Worktrees 'codex-gate')); Set-SchedulerStarted $p 'gate' $true
    [IO.File]::WriteAllText($p.Board,"## gate`r`n- agent: codex`r`n- status: done`r`n")
    $calls=New-Object Collections.ArrayList; $resumes=New-Object Collections.ArrayList
    $gate={ [void]$calls.Add(1); @{success=$false;output='reviewer unavailable'} }; $resume={ [void]$resumes.Add(1); $true }
    $null=Invoke-SchedulerTick $p -MergeCommand $gate -ResumeCommand $resume; $null=Invoke-SchedulerTick $p -MergeCommand $gate -ResumeCommand $resume
    $d=@(Get-Decisions $p 1)[0]; Assert-True ($calls.Count -eq 1 -and $resumes.Count -eq 0 -and $d.action -eq 'gate-error' -and $d.reason -eq 'reviewer unavailable' -and $d.round -eq 0) 'gate error retried or resumed'
    $path=Join-Path $p.Main '.trinity\decisions.jsonl'; $text=[IO.File]::ReadAllText($path).Replace($d.at, (Get-Date).AddMinutes(-11).ToString('o')); [IO.File]::WriteAllText($path,$text)
    $null=Invoke-SchedulerTick $p -MergeCommand { @{success=$false;output='dry run: tests failed (exit 1)'} } -ResumeCommand $resume
    Assert-True ($resumes.Count -eq 1 -and @(Get-Decisions $p 1)[0].action -eq 'resumed') 'findings did not resume'
}
Run-Case 'sched-core: unpause without pause preserves limits' {
    param($f)
    $p=Get-SchedulerPaths $f.Repo; $null=Set-TrinityConfig $p @{autopilot=@{enabled=$true;maxConsecutiveFailures=1}}; Add-Decision $p 'x' 'failed' 'failed' 0; Clear-PauseSwitch $p
    $null=Invoke-SchedulerTick $p; Assert-True ((Test-PauseSwitch $p).paused -and @((Get-Decisions $p 0) | Where-Object { $_.action -eq 'unpaused' }).Count -eq 0) 'unpause bypassed limit'
}
Run-Case 'sched-core: ownership survives decision rotation and prunes' {
    param($f)
    $p=Get-SchedulerPaths $f.Repo; $null=Set-TrinityConfig $p @{autopilot=@{enabled=$true}}; Add-QueueItem $p @{task='owned';agent='codex';promptFile=$f.Prompt}
    $null=Invoke-SchedulerTick $p -DispatchCommand { $true }; $null=Invoke-Git $f.Repo @('branch','agent/codex/owned'); [void][IO.Directory]::CreateDirectory((Join-Path $p.Worktrees 'codex-owned'))
    [IO.File]::WriteAllText((Join-Path $p.Main '.trinity\decisions.jsonl'),''); [IO.File]::WriteAllText($p.Board,"## owned`r`n- agent: codex`r`n- status: done`r`n")
    $r=Invoke-SchedulerTick $p -MergeCommand { $true }; Assert-True ($r.autopilot -contains 'ready') 'ownership lost with decision log'
    [IO.File]::WriteAllText($p.Board,"## owned`r`n- agent: codex`r`n- status: cancelled`r`n"); $null=Invoke-SchedulerTick $p; Assert-True (@(Get-SchedulerStarted $p).Count -eq 0) 'cancelled ownership not pruned'
}
Run-Case 'sched-core: idle skips probes and rate cache observes newest file' {
    param($f)
    $p=Get-SchedulerPaths $f.Repo; $script:schedulerAvailabilityAt=$null; $script:probeCalls=0
    function Get-CachedAgentAvailability { $script:probeCalls++; return @{} }; function Test-CodexRateLimit { $script:probeCalls++; return $false }
    try { $null=Invoke-SchedulerTick $p; Assert-True ($script:probeCalls -eq 0) 'idle probes ran' } finally { Remove-Item Function:Get-CachedAgentAvailability; Remove-Item Function:Test-CodexRateLimit; . (Join-Path $repoSource 'scripts\lib\scheduler.ps1') }
    $old=$env:CODEX_HOME; $env:CODEX_HOME=Join-Path $f.Root 'codex-cache'; $d=Get-Date; $dir=Join-Path $env:CODEX_HOME ('sessions\' + $d.ToString('yyyy') + '\' + $d.ToString('MM') + '\' + $d.ToString('dd')); [void][IO.Directory]::CreateDirectory($dir)
    try { $file=Join-Path $dir 'rollout-test.jsonl'; [IO.File]::WriteAllText($file,'{"payload":{"rate_limits":{"primary":{"used_percent":99}}}}'); Assert-True (Test-CodexRateLimit) 'rate limit missed'; [IO.File]::WriteAllText($file,'{"payload":{"rate_limits":{"primary":{"used_percent":0}}}}'); (Get-Item $file).LastWriteTimeUtc=(Get-Date).ToUniversalTime().AddSeconds(2); Assert-True (-not (Test-CodexRateLimit)) 'changed rollout cache not invalidated' } finally { $env:CODEX_HOME=$old }
}
Run-Case 'sched-core: rate limit reads real date folders and looks back a week' {
    param($f)
    $old=$env:CODEX_HOME; $env:CODEX_HOME=Join-Path $f.Root 'codex-week'
    try {
        $d=(Get-Date).AddDays(-5); $dir=Join-Path $env:CODEX_HOME ('sessions\' + $d.ToString('yyyy') + '\' + $d.ToString('MM') + '\' + $d.ToString('dd')); [void][IO.Directory]::CreateDirectory($dir)
        $file=Join-Path $dir 'rollout-week.jsonl'; [IO.File]::WriteAllText($file,'{"payload":{"rate_limits":{"secondary":{"used_percent":99,"window_minutes":10080}}}}')
        Assert-True (Test-CodexRateLimit) 'weekly reading in older folder missed'
    } finally { $env:CODEX_HOME=$old }
}
Run-Case 'sched-core: default dry run survives child stderr and classifies findings' {
    param($f)
    $p=Get-SchedulerPaths $f.Repo; $null=Set-TrinityConfig $p @{autopilot=@{enabled=$true}}
    [IO.File]::WriteAllText((Join-Path $f.Repo 'scripts\trinity.ps1'),"[Console]::Error.WriteLine('trinity: noisy stderr')`r`n[Console]::Out.WriteLine('- [P1] x')`r`nexit 1`r`n")
    $r=Invoke-SchedulerChild $p @('merge','t','-DryRun') -Capture
    Assert-True (-not $r.success -and $r.output -match '\[P1\] x' -and $r.output -match 'noisy stderr') "capture lost output: $($r.output)"
    $null=Invoke-Git $f.Repo @('branch','agent/codex/noisy'); [void][IO.Directory]::CreateDirectory((Join-Path $p.Worktrees 'codex-noisy')); Set-SchedulerStarted $p 'noisy' $true
    [IO.File]::WriteAllText($p.Board,"## noisy`r`n- agent: codex`r`n- status: done`r`n"); $resumes=New-Object Collections.ArrayList
    $null=Invoke-SchedulerTick $p -ResumeCommand { [void]$resumes.Add(1); $true }
    Assert-True ($resumes.Count -eq 1 -and @(Get-Decisions $p 1)[0].action -eq 'resumed') 'stderr findings classified as gate-error'
}
Run-Case 'sched-core: repeated gate errors become gate-stuck once' {
    param($f)
    $p=Get-SchedulerPaths $f.Repo; $null=Set-TrinityConfig $p @{autopilot=@{enabled=$true;maxConsecutiveFailures=5}}
    $null=Invoke-Git $f.Repo @('branch','agent/codex/stuck'); [void][IO.Directory]::CreateDirectory((Join-Path $p.Worktrees 'codex-stuck')); Set-SchedulerStarted $p 'stuck' $true
    [IO.File]::WriteAllText($p.Board,"## stuck`r`n- agent: codex`r`n- status: done`r`n")
    $calls=New-Object Collections.ArrayList; $gate={ [void]$calls.Add(1); @{success=$false;output='review output unparsed'} }
    $path=Join-Path $p.Main '.trinity\decisions.jsonl'
    for ($i=0; $i -lt 4; $i++) {
        $null=Invoke-SchedulerTick $p -MergeCommand $gate
        if (Test-Path $path) { $text=[IO.File]::ReadAllText($path) -replace '"at":"[^"]+"',('"at":"' + (Get-Date).AddMinutes(-11).ToString('o') + '"'); [IO.File]::WriteAllText($path,$text) }
    }
    $d=@(Get-Decisions $p 0)
    Assert-True ($calls.Count -eq 3 -and @($d | Where-Object { $_.action -eq 'gate-error' }).Count -eq 3 -and @($d | Where-Object { $_.action -eq 'gate-stuck' }).Count -eq 1) "gate-stuck wrong calls=$($calls.Count)"
    $cfg=Get-TrinityConfig $p; $cfg.autopilot.maxConsecutiveFailures=1
    Assert-True ((Get-SchedulerLimit $cfg $d) -eq 'limit: 1 consecutive failures') 'gate-stuck not counted once'
}
Run-Case 'sched-core: scheduler-tasks corrupt file recovered and io error kept' {
    param($f)
    $p=Get-SchedulerPaths $f.Repo; $path=Join-Path $p.Main '.trinity\scheduler-tasks.json'; [void][IO.Directory]::CreateDirectory((Split-Path $path))
    [IO.File]::WriteAllText($path,'{"task":')
    $items=@(Get-SchedulerStarted $p)
    Assert-True ($items.Count -eq 0 -and -not (Test-Path $path) -and @(Get-ChildItem (Split-Path $path) -Filter 'scheduler-tasks.json.corrupt-*').Count -eq 1 -and @(Get-Decisions $p 1)[0].reason -match 'corrupt scheduler-tasks') 'corrupt started file not recovered'
    Set-SchedulerStarted $p 'keep' $true; $stream=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None); $threw=$false
    try { try { $null=Get-SchedulerStarted $p } catch { $threw=$true } } finally { $stream.Dispose() }
    Assert-True ($threw -and @(Get-SchedulerStarted $p).Count -eq 1 -and @(Get-ChildItem (Split-Path $path) -Filter 'scheduler-tasks.json.corrupt-*').Count -eq 1) 'io error treated as corrupt'
}
Run-Case 'sched-core: stale started entries are pruned' {
    param($f)
    $p=Get-SchedulerPaths $f.Repo; $now=(Get-Date).ToString('o'); $old=(Get-Date).AddMinutes(-30).ToString('o'); $ancient=(Get-Date).AddDays(-15).ToString('o')
    foreach ($name in @('keep','ancient')) { $null=Invoke-Git $f.Repo @('branch',"agent/codex/$name") }
    [IO.File]::WriteAllText($p.Board,"## keep`r`n- agent: codex`r`n- status: done`r`n## ancient`r`n- agent: codex`r`n- status: done`r`n## nobranch`r`n- agent: codex`r`n- status: done`r`n")
    Write-TrinityJson (Join-Path $p.Main '.trinity\scheduler-tasks.json') @(@{task='keep';startedAt=$now},@{task='ancient';startedAt=$ancient},@{task='nobranch';startedAt=$now},@{task='noboard';startedAt=$old},@{task='fresh-noboard';startedAt=$now})
    $null=Invoke-SchedulerTick $p
    $left=(@(Get-SchedulerStarted $p | ForEach-Object { $_.task }) | Sort-Object) -join ','
    Assert-True ($left -eq 'fresh-noboard,keep') "pruning wrong: $left"
}
