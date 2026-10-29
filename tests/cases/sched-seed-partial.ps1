. (Join-Path $repoSource 'scripts\lib\scheduler.ps1')

Run-Case 'sched-seed-partial: unreadable source retries without persisting partial seed' {
    param($f)
    $p=Get-SchedulerPaths $f.Repo; $dir=Join-Path $p.Main '.trinity'; [void][IO.Directory]::CreateDirectory($dir)
    $locked=Join-Path $dir 'decisions-1.jsonl'; $tasksPath=Join-Path $dir 'scheduler-tasks.json'
    [IO.File]::WriteAllText($locked, '{"task":"locked","action":"started"}')
    [IO.File]::WriteAllText((Join-Path $dir 'decisions.jsonl'), '{"task":"readable","action":"started"}')
    foreach ($name in @('locked','readable')) {
        $null=Invoke-Git $f.Repo @('branch',"agent/codex/$name")
        [void][IO.Directory]::CreateDirectory((Join-Path $p.Worktrees "codex-$name"))
    }
    [IO.File]::WriteAllText($p.Board,"## locked`r`n- agent: codex`r`n- status: done`r`n## readable`r`n- agent: codex`r`n- status: done`r`n")
    $stream=[IO.File]::Open($locked,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    try { $null=Get-SchedulerStarted $p; Assert-True (-not (Test-Path $tasksPath)) 'partial seed was persisted' } finally { $stream.Dispose() }
    $items=@(Get-SchedulerStarted $p); $names=(@($items | ForEach-Object { $_.task }) | Sort-Object) -join ','
    Assert-True ((Test-Path $tasksPath) -and $names -eq 'locked,readable') "retry did not persist complete seed: $names"
}
