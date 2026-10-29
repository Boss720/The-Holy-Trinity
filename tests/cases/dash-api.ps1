. (Join-Path $script:repoSource 'scripts\dashboard.ps1') -LibraryOnly

Run-Case 'dash-api: page actions match server allow-list and documented commands' {
    param($f)
    $page = [IO.File]::ReadAllText((Join-Path $script:repoSource 'scripts\dashboard.html'))
    $server = [IO.File]::ReadAllText((Join-Path $script:repoSource 'scripts\dashboard.ps1'))
    $pageActions = New-Object System.Collections.Generic.List[string]
    foreach ($expression in [regex]::Matches($page, '\baction\s*:\s*([^,\r\n}]+)')) {
        $expressionText = $expression.Groups[1].Value
        if ($expressionText -match "^\s*mode\s*===\s*'queue'\s*\?\s*'([^']+)'\s*:\s*'([^']+)'") {
            $pageActions.Add($Matches[1]); $pageActions.Add($Matches[2])
        }
        else { foreach ($literal in [regex]::Matches($expressionText, "'([^']+)'") ) { $pageActions.Add($literal.Groups[1].Value) } }
    }
    foreach ($match in [regex]::Matches($page, "requestAction\(\s*'([^']+)'") ) { $pageActions.Add($match.Groups[1].Value) }
    $pageActions = @($pageActions | Sort-Object -Unique)
    $serverActions = @($script:DashboardActionAllowList | Sort-Object -Unique)
    Assert-True (($pageActions -join ',') -ceq ($serverActions -join ',')) "page actions do not exactly match the server allow-list: page=[$($pageActions -join ',')] server=[$($serverActions -join ',')]"

    $reviewCommand = Get-DashboardActionCommand 'review-task' 'api-task' '0123456789ab'
    Assert-True ($reviewCommand -ceq 'trinity merge api-task -DryRun') 'review-task command does not match the documented merge dry-run verb'
    $resumeCommand = Get-DashboardActionCommand 'resume' 'api-task' '0123456789ab'
    Assert-True ($resumeCommand -ceq 'trinity resume api-task -FeedbackFile .codex-out\feedback-api-task-0123456789ab.md') 'resume command does not match the CLI contract'
    $retryCommand = Get-DashboardActionCommand 'retry' 'api-task' '0123456789ab'
    Assert-True ($retryCommand -ceq 'trinity retry api-task') 'retry command does not match the CLI contract'
    $queueCommand = Get-DashboardActionCommand 'queue-add' 'queued-api' '0123456789ab' 'codex' 'tests/*'
    Assert-True ($queueCommand -ceq ('trinity queue add codex queued-api -Scope "tests/*" -PromptFile .codex-out\prompt-queued-api.md' + "`ntrinity scheduler start")) 'queue-add command does not match the CLI contract'
    $pauseCommand = Get-DashboardActionCommand 'pause' '' '0123456789ab' '' '' 'user: stop'
    Assert-True ($pauseCommand -ceq ('trinity pause "user: stop"' + "`ntrinity scheduler stop")) 'pause command does not match the CLI contract'
    $unpauseCommand = Get-DashboardActionCommand 'unpause' '' '0123456789ab'
    Assert-True ($unpauseCommand -ceq 'trinity unpause') 'unpause command does not match the CLI contract'
    Assert-True ($server.Contains("WriteAllText((Join-Path `$pauseDir 'PAUSE')")) 'pause route does not write the PAUSE switch before starting the scheduler action'

    $stub = @'
$target = Join-Path $PSScriptRoot '..\.codex-out\api-invocations.txt'
[IO.File]::AppendAllText($target, ((@($args) -join '|') + "`r`n"), (New-Object Text.UTF8Encoding($false)))
exit 0
'@
    [IO.File]::WriteAllText((Join-Path $f.Repo 'scripts\trinity.ps1'), $stub, (New-Object Text.UTF8Encoding($false)))
    $promptPath = Join-Path $f.Repo '.codex-out\prompt-queued-api.md'
    [void][IO.Directory]::CreateDirectory((Split-Path $promptPath -Parent))
    [IO.File]::WriteAllText($promptPath, 'Run queued task', (New-Object Text.UTF8Encoding($false)))
    $script:Jobs = @{}
    $processCases = @(
        @{ id='000000000001'; action='resume'; task='api-task'; command=(Get-DashboardActionCommand 'resume' 'api-task' '000000000001'); agent=''; scope=''; prompt='.codex-out\feedback-api-task-000000000001.md' },
        @{ id='000000000002'; action='retry'; task='api-task'; command=$retryCommand; agent=''; scope=''; prompt='' },
        @{ id='000000000003'; action='queue-add'; task='queued-api'; command=$queueCommand; agent='codex'; scope='tests/*'; prompt='.codex-out\prompt-queued-api.md' },
        @{ id='000000000004'; action='pause'; task=''; command=$pauseCommand; agent=''; scope=''; prompt='' },
        @{ id='000000000005'; action='unpause'; task=''; command=$unpauseCommand; agent=''; scope=''; prompt='' },
        @{ id='000000000006'; action='review-task'; task='api-task'; command=$reviewCommand; agent=''; scope=''; prompt=''; worktree=$f.Repo }
    )
    foreach ($processCase in $processCases) {
        $worktree = if ($processCase.ContainsKey('worktree')) { $processCase.worktree } else { '' }
        Start-ActionProcess $processCase.id $processCase.action $processCase.task $f.Repo $worktree $processCase.command $processCase.agent $processCase.scope $processCase.prompt
        $job = $script:Jobs[$processCase.id]
        $deadline = (Get-Date).AddSeconds(15)
        while ($job.state -eq 'running' -and (Get-Date) -lt $deadline) { Update-ActionJobs; Start-Sleep -Milliseconds 100; $job = $script:Jobs[$processCase.id] }
        Assert-True ($job.state -eq 'done' -and $job.exitCode -eq 0) "$($processCase.action) process mapping failed: $(Read-JobOutput $job)"
    }
    $invocations = [IO.File]::ReadAllText((Join-Path $f.Repo '.codex-out\api-invocations.txt'))
    foreach ($verb in @('resume|api-task|-FeedbackFile|.codex-out\feedback-api-task-000000000001.md', 'retry|api-task', 'queue|add|codex|queued-api|-Scope|tests/*|-PromptFile|.codex-out\prompt-queued-api.md', 'scheduler|start', 'scheduler|stop', 'unpause', 'merge|api-task|-DryRun')) {
        Assert-True ($invocations.Contains($verb)) "expected CLI invocation was missing: $verb"
    }
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $f.Repo '.codex-out\jobs\000000000003.ps1'))) 'queue-add left its temporary runner script behind'
    foreach ($action in @('resume','retry','queue-add','pause','unpause')) {
        Assert-True ($server.Contains("elseif (`$Action -eq '$action')") -or $server.Contains("'${action}' {")) "server process mapping is missing for $action"
    }
}

Run-Case 'dash-api: merge accepts ready tasks from section 4' {
    param($f)
    $page = [IO.File]::ReadAllText((Join-Path $script:repoSource 'scripts\dashboard.html'))
    $readyTask = [pscustomobject]@{ state = 'ready'; branch = 'agent/codex/ready-api' }
    Assert-True ((Get-TaskState 'ready: clean review' $false) -eq 'ready') 'server did not expose ready as a task state'
    Assert-True (Test-DashboardTaskActionState 'merge' $readyTask $false) 'server rejected merge for a ready task'
    Assert-True ((Get-DashboardActionCommand 'merge' 'ready-api' '0123456789ab') -eq 'trinity merge ready-api -Yes') 'ready merge used the wrong CLI command'
    Assert-True ($page -match "const mergeable = state === 'done' \|\| state === 'ready';") 'page no longer offers merge for ready tasks'
}

Run-Case 'dash-api: cancel is limited to server-supported task states' {
    param($f)
    $page = [IO.File]::ReadAllText((Join-Path $script:repoSource 'scripts\dashboard.html'))
    $pageMatch = [regex]::Match($page, 'const CANCELABLE_STATES\s*=\s*\[([^\]]+)\]')
    Assert-True $pageMatch.Success 'page cancel-state allow-list is missing'
    $pageStates = @([regex]::Matches($pageMatch.Groups[1].Value, "'([^']+)'") | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
    $serverStates = @($script:DashboardCancelAllowedStates | Sort-Object -Unique)
    Assert-True (($pageStates -join ',') -ceq ($serverStates -join ',')) "page/server cancel states differ: page=[$($pageStates -join ',')] server=[$($serverStates -join ',')]"
    Assert-True ($page -match 'if \(cancelOk\)\s*\{\s*const cancelCmd') 'page still renders Cancel outside the allowed-state check'
    foreach ($state in @('done','ready','merged','cancelled')) {
        Assert-True (-not (Test-DashboardTaskActionState 'cancel' ([pscustomobject]@{ state = $state }) $false)) "server allowed Cancel for $state"
    }
    foreach ($state in @('queued','running','failed','stalled')) {
        Assert-True (Test-DashboardTaskActionState 'cancel' ([pscustomobject]@{ state = $state }) $false) "server rejected Cancel for allowed state $state"
    }
}
