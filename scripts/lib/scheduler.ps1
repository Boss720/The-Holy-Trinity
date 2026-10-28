. (Join-Path $PSScriptRoot 'config.ps1')
. (Join-Path $PSScriptRoot 'board.ps1')

function Get-SchedulerPaths([string]$Repo) { Get-RepoPaths $Repo }
function Invoke-QueueLocked($Paths, [scriptblock]$Body) {
    $dir = Join-Path $Paths.Main '.trinity'; [void][IO.Directory]::CreateDirectory($dir)
    $path = Join-Path $dir 'queue.lock'; $lock = $null; $until = (Get-Date).AddSeconds(5)
    while (-not $lock) {
        try { $lock = [IO.File]::Open($path, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
        catch [IO.IOException] {
            if (Test-Path -LiteralPath $path) {
                try { if (((Get-Date) - (Get-Item -LiteralPath $path).LastWriteTime).TotalSeconds -gt 30) { Remove-Item -LiteralPath $path -Force -ErrorAction Stop } } catch { }
            }
            if ((Get-Date) -ge $until) { throw 'Timed out waiting for queue lock' }
            Start-Sleep -Milliseconds 50
        }
    }
    try { & $Body } finally { $lock.Dispose(); Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
}
function Read-QueueUnlocked($Paths) {
    $path = Join-Path $Paths.Main '.trinity\queue.json'
    if (-not (Test-Path -LiteralPath $path)) { return @{version=1;items=@()} }
    $queue = ConvertTo-TrinityMap (ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($path)) -ErrorAction Stop)
    if ($queue -isnot [hashtable] -or $queue.items -isnot [array]) { throw 'Invalid queue file' }
    return $queue
}
function Get-TrinityQueue($Paths) { Invoke-QueueLocked $Paths { Read-QueueUnlocked $Paths } }
function Add-QueueItem($Paths, $Item) {
    $item = ConvertTo-TrinityMap $Item
    if ($item -isnot [hashtable] -or [string]$item.task -cnotmatch '^[a-z0-9][a-z0-9-]{0,39}$') { throw 'Invalid task name' }
    if ($item.agent -cnotin @('codex','antigravity','claude')) { throw 'Invalid agent' }
    Invoke-QueueLocked $Paths {
        $q = Read-QueueUnlocked $Paths
        if (@($q.items | Where-Object { $_.task -eq $item.task }).Count) { throw 'Task already queued' }
        $entry = Get-BoardEntry $Paths $item.task
        if ($entry -and $entry.status -notmatch '^cancelled') { throw 'Task already on board' }
        foreach ($key in @('scope','promptFile','base','model','addedBy','waiting')) { if (-not $item.ContainsKey($key)) { $item[$key] = '' } }
        if (-not $item.addedAt) { $item.addedAt = (Get-Date).ToString('o') }
        $q.items = @($q.items) + @($item); Write-TrinityJson (Join-Path $Paths.Main '.trinity\queue.json') $q
    }
}
function Remove-QueueItem($Paths, [string]$Task) {
    Invoke-QueueLocked $Paths { $q=Read-QueueUnlocked $Paths; if (-not @($q.items | Where-Object { $_.task -eq $Task }).Count) { throw 'Task not queued' }; $q.items=@($q.items | Where-Object { $_.task -ne $Task }); Write-TrinityJson (Join-Path $Paths.Main '.trinity\queue.json') $q }
}
function Move-QueueItem($Paths, [string]$Task, [int]$Index) {
    Invoke-QueueLocked $Paths {
        $q=Read-QueueUnlocked $Paths; $items=New-Object Collections.ArrayList; foreach ($item in $q.items) { [void]$items.Add($item) }
        $found=-1; for ($i=0; $i -lt $items.Count; $i++) { if ($items[$i].task -eq $Task) { $found=$i; break } }
        if ($found -lt 0) { throw 'Task not queued' }; if ($Index -lt 0 -or $Index -ge $items.Count) { throw 'Queue index out of range' }
        $item=$items[$found]; $items.RemoveAt($found); $items.Insert($Index,$item); $q.items=@($items.ToArray()); Write-TrinityJson (Join-Path $Paths.Main '.trinity\queue.json') $q
    }
}
function Test-PauseSwitch($Paths) {
    $path=Join-Path $Paths.Main '.trinity\PAUSE'; if (Test-Path -LiteralPath $path) { return @{paused=$true;reason=([IO.File]::ReadAllText($path)).Trim()} }; return @{paused=$false;reason=''}
}
function Set-PauseSwitch($Paths, [string]$Reason) {
    $path=Join-Path $Paths.Main '.trinity\PAUSE'; [void][IO.Directory]::CreateDirectory((Split-Path $path -Parent)); [IO.File]::WriteAllText($path, (($Reason -replace '[\r\n]+',' ') + "`r`n"), (New-Object Text.UTF8Encoding($false)))
}
function Clear-PauseSwitch($Paths) { Remove-Item -LiteralPath (Join-Path $Paths.Main '.trinity\PAUSE') -Force -ErrorAction SilentlyContinue }
function Add-Decision($Paths, [string]$Task, [string]$Action, [string]$Reason, [int]$Round=0) {
    Invoke-QueueLocked $Paths {
        $path=Join-Path $Paths.Main '.trinity\decisions.jsonl'
        if ((Test-Path -LiteralPath $path) -and @([IO.File]::ReadAllLines($path)).Count -ge 2000) {
            $archive=Join-Path (Split-Path $path -Parent) ('decisions-' + (Get-Date -Format 'yyyyMMddHHmmss') + '.jsonl')
            while (Test-Path -LiteralPath $archive) { Start-Sleep -Milliseconds 100; $archive=Join-Path (Split-Path $path -Parent) ('decisions-' + (Get-Date -Format 'yyyyMMddHHmmss') + '.jsonl') }
            Move-Item -LiteralPath $path -Destination $archive
        }
        $record=@{at=(Get-Date).ToString('o');task=$Task;action=$Action;reason=$Reason;round=$Round} | ConvertTo-Json -Compress
        [IO.File]::AppendAllText($path, $record + "`n", (New-Object Text.UTF8Encoding($false)))
    }
}
function Get-Decisions($Paths, [int]$Last=20) {
    $dir=Join-Path $Paths.Main '.trinity'; $records=New-Object Collections.ArrayList
    if (Test-Path -LiteralPath $dir) {
        $files=@(Get-ChildItem -LiteralPath $dir -Filter 'decisions-*.jsonl' -File | Sort-Object Name); $current=Join-Path $dir 'decisions.jsonl'; if (Test-Path $current) { $files+=Get-Item $current }
        foreach ($file in $files) { foreach ($line in [IO.File]::ReadAllLines($file.FullName)) { try { if ($line.Trim()) { [void]$records.Add((ConvertTo-TrinityMap (ConvertFrom-Json $line -ErrorAction Stop))) } } catch { } } }
    }
    $all=@($records.ToArray()); [array]::Reverse($all); if ($Last -gt 0) { $all=@($all | Select-Object -First $Last) }; return $all
}
function Get-SchedulerTasks($Paths) {
    if (-not (Test-Path -LiteralPath $Paths.Board)) { return @() }
    foreach ($line in [IO.File]::ReadAllLines($Paths.Board)) { if ($line -match '^## (.+)$') { $entry=Get-BoardEntry $Paths $Matches[1]; if ($entry) { $entry } } }
}
function Get-SchedulerTaskState($Paths, $Entry) {
    $alive=$false; $pidPath=Join-Path $Paths.Out ("pid-{0}.txt" -f $Entry.task)
    if (Test-Path -LiteralPath $pidPath) { $runner=0; if ([int]::TryParse(([IO.File]::ReadAllText($pidPath)).Trim(),[ref]$runner) -and $runner -gt 0) { $alive=[bool](Get-Process -Id $runner -ErrorAction SilentlyContinue) } }
    $status=[string]$Entry.status
    if ($alive -or $status -match '^(started|running|working)(\s|:|$)') { return 'running' }
    if ($status -match '\(stalled') { return 'stalled' }
    foreach ($state in @('failed','merged','cancelled','done','ready','waiting')) { if ($status -match "^$state") { return $state } }; return 'other'
}
function Get-SlotUse($Paths, $Config) {
    $slots=@{}; foreach ($agent in @('codex','antigravity','claude')) { $slots[$agent]=@{used=0;max=[int]$Config.slots[$agent]} }
    foreach ($entry in @(Get-SchedulerTasks $Paths)) { if ($slots.ContainsKey([string]$entry.agent) -and (Get-SchedulerTaskState $Paths $entry) -eq 'running') { $slots[$entry.agent].used++ } }; return $slots
}
function Test-SchedulerOverlap([string]$Left, [string]$Right) {
    foreach ($a in $Left.Split(',')) { foreach ($b in $Right.Split(',')) {
        $x=($a.Trim() -replace '\\','/' -replace '/\*\*?$','').ToLowerInvariant(); $y=($b.Trim() -replace '\\','/' -replace '/\*\*?$','').ToLowerInvariant()
        if ($x -and $y -and $x -ne 'unspecified' -and $y -ne 'unspecified' -and ($x.StartsWith($y) -or $y.StartsWith($x))) { return $true }
    } }; return $false
}
function Test-CodexRateLimit {
    $codexHome=if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }; $sessions=Join-Path $codexHome 'sessions'
    try {
        $file=Get-ChildItem -LiteralPath $sessions -Filter 'rollout-*.jsonl' -Recurse -File -ErrorAction Stop | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($file) { $lines=[IO.File]::ReadAllLines($file.FullName); [array]::Reverse($lines); foreach ($line in $lines) { if ($line -notmatch 'rate_limits') { continue }; $record=ConvertFrom-Json $line; $rate=$record.payload.rate_limits; if ($rate) { foreach ($window in @($rate.primary,$rate.secondary)) { if ($window -and $window.used_percent -ge 95) { return $true } }; return $false } } }
    } catch { }; return $false
}
function Invoke-SchedulerChild($Paths, [string[]]$Arguments) {
    Push-Location $Paths.Main
    try { & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Paths.Main 'scripts\trinity.ps1') @Arguments | Out-Host; return ($LASTEXITCODE -eq 0) } finally { Pop-Location }
}
function Invoke-SchedulerTick($Paths, [scriptblock]$DispatchCommand, [scriptblock]$MergeCommand, [scriptblock]$ResumeCommand) {
    if (-not $DispatchCommand) { $DispatchCommand={ param($p,$item,$cfg) $argsList=@('dispatch',$item.agent,$item.task,'-Scope',$item.scope,'-PromptFile',$item.promptFile); if ($item.base) { $argsList+=@('-Base',$item.base) }; if ($item.model) { $argsList+=@('-Model',$item.model) }; $deadline=$cfg.deadlineMinutes; $envDeadline=0; if ([int]::TryParse($env:TRINITY_DEADLINE_MINUTES,[ref]$envDeadline) -and $envDeadline -gt 0) { $deadline=$envDeadline }; $argsList+=@('-DeadlineMinutes',[string]$deadline); Invoke-SchedulerChild $p $argsList } }
    if (-not $MergeCommand) { $MergeCommand={ param($p,$task,$dry) $flag=if ($dry) { '-DryRun' } else { '-Yes' }; Invoke-SchedulerChild $p @('merge',$task,$flag) } }
    if (-not $ResumeCommand) { $ResumeCommand={ param($p,$task,$feedback) Invoke-SchedulerChild $p @('resume',$task,'-FeedbackFile',$feedback) } }
    $cfg=Get-TrinityConfig $Paths; $result=@{started=@();waiting=@{};autopilot=@()}; $pause=Test-PauseSwitch $Paths
    $tasks=@(Get-SchedulerTasks $Paths); $slots=Get-SlotUse $Paths $cfg; $availability=if (-not $pause.paused) { Get-AgentAvailability } else { @{} }; $rate=if (-not $pause.paused) { Test-CodexRateLimit } else { $false }
    $queue=Get-TrinityQueue $Paths
    foreach ($item in @($queue.items)) {
        $reason=''; $agent=[string]$item.agent
        if ($pause.paused) { $reason='paused' }
        elseif (-not $availability[$agent].available) { $reason='agent unavailable' }
        elseif ($agent -eq 'codex' -and $rate) { $reason='rate limit' }
        elseif ($slots[$agent].used -ge $slots[$agent].max) { $reason='no free slot' }
        else { foreach ($task in $tasks) { if ((Get-SchedulerTaskState $Paths $task) -eq 'running' -and (Test-SchedulerOverlap $item.scope $task.scope)) { $reason="scope overlaps $($task.task)"; break } } }
        if (-not $reason) {
            try { $ok=& $DispatchCommand $Paths $item $cfg; if ($ok -eq $false) { throw 'dispatch failed' }; Remove-QueueItem $Paths $item.task; Add-Decision $Paths $item.task 'started' 'dispatched' 0; $result.started+=@($item.task); $slots[$agent].used++; $tasks+=@(@{task=$item.task;agent=$agent;scope=$item.scope;status='running'}); continue }
            catch { $reason='agent unavailable'; Add-Decision $Paths $item.task 'failed' ("dispatch: " + $_.Exception.Message) 0 }
        }
        $result.waiting[$item.task]=$reason
        Invoke-QueueLocked $Paths { $q=Read-QueueUnlocked $Paths; foreach ($queued in $q.items) { if ($queued.task -eq $item.task) { $queued.waiting=$reason } }; Write-TrinityJson (Join-Path $Paths.Main '.trinity\queue.json') $q }
    }
    if ($pause.paused) { $recent=@(Get-Decisions $Paths 0 | Where-Object { $_.action -eq 'paused' -and ([datetimeoffset]::Parse($_.at)) -gt (Get-Date).AddHours(-1) }); if (-not $recent.Count) { Add-Decision $Paths '' 'paused' $pause.reason 0 } }
    elseif ($cfg.autopilot.enabled) {
        $decisions=@(Get-Decisions $Paths 0); $hour=@($decisions | Where-Object { $_.action -eq 'started' -and ([datetimeoffset]::Parse($_.at)) -gt (Get-Date).AddHours(-1) }).Count
        $failures=0; foreach ($d in $decisions) { if ($d.action -eq 'failed') { $failures++ } elseif ($d.action -in @('started','resumed','skipped','limit','paused')) { continue } else { break } }
        $limit=''; if ($hour -ge $cfg.autopilot.maxTasksPerHour) { $limit="limit: $hour tasks per hour" } elseif ($failures -ge $cfg.autopilot.maxConsecutiveFailures) { $limit="limit: $failures consecutive failures" }
        if ($limit) { Set-PauseSwitch $Paths $limit; Add-Decision $Paths '' 'limit' $limit 0; $result.autopilot+=@('limit') }
        else {
            foreach ($task in $tasks) {
                $state=Get-SchedulerTaskState $Paths $task; if ($state -notin @('done','failed')) { continue }
                $history=@($decisions | Where-Object { $_.task -eq $task.task }); if ($history.Count -and $history[0].action -in @('ready','merged','failed')) { continue }
                $round=@($history | Where-Object { $_.action -eq 'resumed' }).Count; $clean=$false
                if ($state -eq 'done') { try { $clean=(& $MergeCommand $Paths $task.task $true) -ne $false } catch { $clean=$false } }
                if ($clean) {
                    $cleanRuns=0; foreach ($d in $decisions) { if ($d.action -eq 'failed') { break }; if ($d.action -in @('merged','ready')) { $cleanRuns++ } }
                    if ($cfg.autoMerge -and -not $cfg.autopilot.approval -and $cleanRuns -ge $cfg.autopilot.cleanRunsBeforeAutoMerge) { try { if ((& $MergeCommand $Paths $task.task $false) -eq $false) { throw 'merge failed' }; Add-Decision $Paths $task.task 'merged' 'merge gate clean' $round; $result.autopilot+=@('merged') } catch { Add-Decision $Paths $task.task 'failed' $_.Exception.Message $round; $result.autopilot+=@('failed') } }
                    else { Set-BoardStatus $Paths $task.task 'ready: merge gate clean'; Add-Decision $Paths $task.task 'ready' 'merge gate clean' $round; $result.autopilot+=@('ready') }
                } elseif ($round -lt $cfg.maxRounds) {
                    [void][IO.Directory]::CreateDirectory($Paths.Out); $feedback=Join-Path $Paths.Out ("feedback-{0}-scheduler.md" -f $task.task); $review=Join-Path $Paths.Out ("review-{0}.md" -f $task.task); $log=Join-Path $Paths.Out ("log-{0}.txt" -f $task.task)
                    $text=if (Test-Path $review) { [IO.File]::ReadAllText($review) } elseif (Test-Path $log) { (Get-Content -LiteralPath $log -Tail 100) -join "`r`n" } else { "Task $($task.task) failed or merge gate was not clean." }; [IO.File]::WriteAllText($feedback,$text,(New-Object Text.UTF8Encoding($false)))
                    try { if ((& $ResumeCommand $Paths $task.task $feedback) -eq $false) { throw 'resume failed' }; Add-Decision $Paths $task.task 'resumed' 'retry after failure' ($round+1); $result.autopilot+=@('resumed') } catch { Add-Decision $Paths $task.task 'failed' $_.Exception.Message $round; $result.autopilot+=@('failed') }
                } else { Add-Decision $Paths $task.task 'failed' 'maximum rounds reached' $round; $result.autopilot+=@('failed') }; break
            }
        }
    }
    $next=@((Get-TrinityQueue $Paths).items | Select-Object -First 1); $proc=Get-Process -Id $PID; $heartbeat=@{pid=$PID;startedAt=$proc.StartTime.ToString('o');processStart=$proc.StartTime.ToString('o');lastTickAt=(Get-Date).ToString('o');now=$(if ($pause.paused) { 'paused' } else { 'idle' });next=$(if ($next.Count) { $next[0].task } else { '' })}; Write-TrinityJson (Join-Path $Paths.Main '.trinity\scheduler.json') $heartbeat
    return $result
}
