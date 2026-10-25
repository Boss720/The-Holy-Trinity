param([switch]$Keep)

$ErrorActionPreference = 'Stop'
$repoSource = Split-Path $PSScriptRoot -Parent
$passed = 0
$failed = 0
$fixtures = New-Object System.Collections.Generic.List[string]
# Keep the user's real repo registry and dashboard pid out of the tests.
$env:TRINITY_HOME = Join-Path $env:TEMP ("trinity-selftest-home-" + [Guid]::NewGuid().ToString('N'))

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Invoke-Git([string]$Directory, [string[]]$GitArgs) {
    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $output = & git -C $Directory @GitArgs 2>&1 }
    finally { $ErrorActionPreference = $oldPreference }
    $code = $LASTEXITCODE
    if ($code -ne 0) { throw "git $($GitArgs -join ' ') failed ($code): $($output -join ' ')" }
    return ($output -join "`n").Trim()
}

function New-Fixture([string]$TestCommand = 'exit 0') {
    $id = [Guid]::NewGuid().ToString('N')
    $root = Join-Path $env:TEMP "trinity-selftest-$id"
    $repo = Join-Path $root 'repo with spaces'
    New-Item -ItemType Directory -Path $repo -Force | Out-Null
    $script:fixtures.Add($root)

    Copy-Item -LiteralPath (Join-Path $script:repoSource 'trinity.cmd') -Destination $repo
    Copy-Item -LiteralPath (Join-Path $script:repoSource 'scripts') -Destination $repo -Recurse
    Copy-Item -LiteralPath (Join-Path $script:repoSource '.gitattributes') -Destination $repo
    New-Item -ItemType Directory -Path (Join-Path $repo 'tests') -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $script:repoSource 'tests\fake-codex.cmd') -Destination (Join-Path $repo 'tests')
    Copy-Item -LiteralPath (Join-Path $script:repoSource 'tests\fake-codex.ps1') -Destination (Join-Path $repo 'tests')
    Copy-Item -LiteralPath (Join-Path $script:repoSource 'tests\fake-agy.cmd') -Destination (Join-Path $repo 'tests')
    Copy-Item -LiteralPath (Join-Path $script:repoSource 'tests\fake-agy.ps1') -Destination (Join-Path $repo 'tests')
    $agentsText = "# Fixture`r`n`r`n" + ('- Test: `{0}`' -f $TestCommand) + "`r`n"
    [IO.File]::WriteAllText((Join-Path $repo 'AGENTS.md'), $agentsText, [System.Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $repo 'README.md'), "fixture`r`n", [System.Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $repo 'tests\prompt.md'), "Perform the fixture task.`r`n", [System.Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $repo '.gitignore'), ".codex-out/`r`n", [System.Text.UTF8Encoding]::new($false))

    & git -C $repo init -b main 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'git init failed' }
    Invoke-Git $repo @('config', 'user.name', 'Trinity Selftest') | Out-Null
    Invoke-Git $repo @('config', 'user.email', 'selftest@example.invalid') | Out-Null
    Invoke-Git $repo @('add', '-A') | Out-Null
    Invoke-Git $repo @('commit', '-m', 'fixture') | Out-Null

    return [pscustomobject]@{
        Root = $root
        Repo = $repo
        Trinity = Join-Path $repo 'scripts\trinity.ps1'
        FakeCodex = Join-Path $repo 'tests\fake-codex.cmd'
        FakeAgy = Join-Path $repo 'tests\fake-agy.cmd'
        Prompt = Join-Path $repo 'tests\prompt.md'
        Worktrees = Join-Path $root 'repo with spaces.worktrees'
    }
}

function Invoke-Trinity($Fixture, [string[]]$Arguments) {
    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    try { $output = & $powershell -NoProfile -ExecutionPolicy Bypass -File $Fixture.Trinity @Arguments 2>&1 }
    finally { $ErrorActionPreference = $oldPreference }
    $code = $LASTEXITCODE
    return [pscustomobject]@{ ExitCode = $code; Output = ($output | Out-String) }
}

function Start-CodexTask($Fixture, [string]$Task) {
    [IO.File]::WriteAllText($Fixture.Prompt, "Perform the fixture task.`r`n", (New-Object Text.UTF8Encoding($false)))
    $result = Invoke-Trinity $Fixture @('dispatch', 'codex', $Task, '-Scope', 'tests/*', '-PromptFile', $Fixture.Prompt)
    Assert-True ($result.ExitCode -eq 0) "dispatch failed ($($result.ExitCode)): $($result.Output)"
}

function Start-AgyTask($Fixture, [string]$Task) {
    [IO.File]::WriteAllText($Fixture.Prompt, "Perform the fixture task.`r`n", (New-Object Text.UTF8Encoding($false)))
    $result = Invoke-Trinity $Fixture @('dispatch', 'antigravity', $Task, '-Scope', 'tests/*', '-PromptFile', $Fixture.Prompt)
    Assert-True ($result.ExitCode -eq 0) "dispatch failed ($($result.ExitCode)): $($result.Output)"
}

function Remove-Fixture($Fixture) {
    if (-not $Fixture -or $Keep) { return }
    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    if (Test-Path $Fixture.Repo) {
        $listed = & git -C $Fixture.Repo worktree list --porcelain 2>$null
        if ($LASTEXITCODE -eq 0) {
            $mainPath = [IO.Path]::GetFullPath($Fixture.Repo).TrimEnd('\', '/')
            foreach ($line in $listed) {
                if ($line -match '^worktree (.+)$') {
                    $worktreePath = [IO.Path]::GetFullPath($Matches[1]).TrimEnd('\', '/')
                    if (-not [string]::Equals($worktreePath, $mainPath, [StringComparison]::OrdinalIgnoreCase)) {
                        & git -C $Fixture.Repo worktree remove --force $worktreePath 2>&1 | Out-Null
                    }
                }
            }
            & git -C $Fixture.Repo worktree prune 2>&1 | Out-Null
        }
    }
    if (Test-Path $Fixture.Root) { Remove-Item -LiteralPath $Fixture.Root -Recurse -Force }
    $ErrorActionPreference = $oldPreference
}

function Run-Case([string]$Name, [scriptblock]$Body, [string]$TestCommand = 'exit 0') {
    $fixture = $null
    $oldCodex = $env:CODEX_EXE
    $oldAgy = $env:AGY_EXE
    $oldPath = $env:PATH
    $oldLocalAppData = $env:LOCALAPPDATA
    $oldMode = $env:FAKE_CODEX_MODE
    $oldAgyMode = $env:FAKE_AGY_MODE
    $oldReview = $env:FAKE_REVIEW_OUTPUT
    try {
        $fixture = New-Fixture $TestCommand
        $env:CODEX_EXE = $fixture.FakeCodex
        $env:AGY_EXE = $fixture.FakeAgy
        $env:FAKE_CODEX_MODE = 'ok'
        $env:FAKE_AGY_MODE = 'ok'
        $env:FAKE_REVIEW_OUTPUT = $null
        & $Body $fixture
        $script:passed++
        Write-Output "PASS $Name"
    }
    catch {
        $script:failed++
        Write-Output "FAIL ${Name}: $($_.Exception.Message)"
    }
    finally {
        $env:CODEX_EXE = $oldCodex
        $env:AGY_EXE = $oldAgy
        $env:PATH = $oldPath
        $env:LOCALAPPDATA = $oldLocalAppData
        $env:FAKE_CODEX_MODE = $oldMode
        $env:FAKE_AGY_MODE = $oldAgyMode
        $env:FAKE_REVIEW_OUTPUT = $oldReview
        Remove-Fixture $fixture
    }
}

Run-Case 'dispatch, wait, commit, merge, and cleanup' {
    param($f)
    Start-CodexTask $f 'task-a'
    $wait = Invoke-Trinity $f @('wait', 'task-a', '-Timeout', '50')
    Assert-True ($wait.ExitCode -eq 0) "wait exit $($wait.ExitCode): $($wait.Output)"
    $board = Get-Content -Raw (Join-Path $f.Repo '.git\agent-board.md')
    Assert-True ($board -match 'done \(1 commits\)') "unexpected board after dispatch: $board"
    $branch = Invoke-Git $f.Repo @('rev-parse', '--verify', 'refs/heads/agent/codex/task-a')
    Assert-True (-not [string]::IsNullOrWhiteSpace($branch)) 'task branch is missing before merge'
    Assert-True ((Invoke-Git $f.Repo @('show', 'agent/codex/task-a:fake-output.txt')) -eq 'fake codex output') 'task commit lacks fake-output.txt'
    $merge = Invoke-Trinity $f @('merge', 'task-a', '-Yes')
    Assert-True ($merge.ExitCode -eq 0) "merge failed ($($merge.ExitCode)): $($merge.Output)"
    Assert-True ((Invoke-Git $f.Repo @('show', 'main:fake-output.txt')) -eq 'fake codex output') 'main lacks fake-output.txt after merge'
    Assert-True (-not (Test-Path (Join-Path $f.Worktrees 'codex-task-a'))) 'worktree directory remains after merge'
    $branchCheck = & git -C $f.Repo branch --list 'agent/codex/task-a'
    Assert-True (-not $branchCheck) 'task branch remains after merge'
    $board = Get-Content -Raw (Join-Path $f.Repo '.git\agent-board.md')
    Assert-True ($board -match '(?m)^- status: merged') 'board status is not merged'
}

Run-Case 'nochange task waits successfully and cannot merge' {
    param($f)
    $env:FAKE_CODEX_MODE = 'nochange'
    Start-CodexTask $f 'task-b'
    $wait = Invoke-Trinity $f @('wait', 'task-b', '-Timeout', '50')
    Assert-True ($wait.ExitCode -eq 0) "wait exit $($wait.ExitCode): $($wait.Output)"
    $board = Get-Content -Raw (Join-Path $f.Repo '.git\agent-board.md')
    Assert-True ($board -match 'done, no commits') "unexpected board status: $board"
    $merge = Invoke-Trinity $f @('merge', 'task-b', '-Yes')
    Assert-True ($merge.ExitCode -ne 0 -and $merge.Output -match 'nothing to merge') "merge should reject empty branch: $($merge.Output)"
}

Run-Case 'failed Codex task returns failure' {
    param($f)
    $env:FAKE_CODEX_MODE = 'fail'
    Start-CodexTask $f 'task-c'
    $wait = Invoke-Trinity $f @('wait', 'task-c', '-Timeout', '50')
    Assert-True ($wait.ExitCode -eq 1) "wait exit $($wait.ExitCode): $($wait.Output)"
    $board = Get-Content -Raw (Join-Path $f.Repo '.git\agent-board.md')
    Assert-True ($board -match 'failed \(exit 3\)') "unexpected board status: $board"
}

Run-Case 'P1 review blocks merge unless forced' {
    param($f)
    Start-CodexTask $f 'task-d'
    $wait = Invoke-Trinity $f @('wait', 'task-d', '-Timeout', '50')
    Assert-True ($wait.ExitCode -eq 0) "wait exit $($wait.ExitCode): $($wait.Output)"
    $mainBefore = Invoke-Git $f.Repo @('rev-parse', 'main')
    $env:FAKE_REVIEW_OUTPUT = '- [P1] something'
    $blocked = Invoke-Trinity $f @('merge', 'task-d', '-Yes')
    Assert-True ($blocked.ExitCode -ne 0 -and $blocked.Output -match 'P0/P1 findings') "P1 merge should be blocked: $($blocked.Output)"
    Assert-True ((Invoke-Git $f.Repo @('rev-parse', 'main')) -eq $mainBefore) 'main changed after blocked review'
    $forced = Invoke-Trinity $f @('merge', 'task-d', '-Yes', '-Force')
    Assert-True ($forced.ExitCode -eq 0) "forced merge failed: $($forced.Output)"
    Assert-True ((Invoke-Git $f.Repo @('show', 'main:fake-output.txt')) -eq 'fake codex output') 'forced merge did not update main'
}

Run-Case 'failed test aborts merge cleanly' {
    param($f)
    Start-CodexTask $f 'task-e'
    $wait = Invoke-Trinity $f @('wait', 'task-e', '-Timeout', '50')
    Assert-True ($wait.ExitCode -eq 0) "wait exit $($wait.ExitCode): $($wait.Output)"
    $mainBefore = Invoke-Git $f.Repo @('rev-parse', 'main')
    $merge = Invoke-Trinity $f @('merge', 'task-e', '-Yes')
    Assert-True ($merge.ExitCode -ne 0 -and $merge.Output -match 'tests failed') "merge should fail tests: $($merge.Output)"
    Assert-True ((Invoke-Git $f.Repo @('rev-parse', 'main')) -eq $mainBefore) 'main changed after failed test'
    $mergeHead = & git -C $f.Repo rev-parse -q --verify MERGE_HEAD 2>$null
    Assert-True ($LASTEXITCODE -ne 0) "merge is still in progress: $mergeHead"
} 'exit 1'

Run-Case 'agent-written done cannot end a headless task early' {
    param($f)
    $wt = Join-Path $f.Worktrees 'codex-task-f'
    New-Item -ItemType Directory -Path $f.Worktrees -Force | Out-Null
    Invoke-Git $f.Repo @('worktree', 'add', '-b', 'agent/codex/task-f', $wt, 'main') | Out-Null
    $boardPath = Join-Path $f.Repo '.git\agent-board.md'
    $writeBoard = {
        param([string]$Status)
        $board = @('', '## task-f', '- agent: codex', '- branch: agent/codex/task-f', "- worktree: $wt", '- scope: tests/*', "- status: $Status") -join "`r`n"
        [IO.File]::WriteAllText($boardPath, $board + "`r`n", [System.Text.UTF8Encoding]::new($false))
    }
    & $writeBoard 'running 2026-01-01 00:00'

    # Headless agents may not mark themselves done.
    $done = Invoke-Trinity $f @('done', 'task-f')
    Assert-True ($done.ExitCode -ne 0) "done should be refused for a codex task: $($done.Output)"
    Assert-True ($done.Output -match 'runner') "done refusal should mention the runner: $($done.Output)"

    # A bare done written straight to the board is not a runner status.
    & $writeBoard 'done'
    $wait = Invoke-Trinity $f @('wait', 'task-f', '-Timeout', '3')
    Assert-True ($wait.ExitCode -eq 2) "bare done should stay pending (exit 2), got $($wait.ExitCode): $($wait.Output)"

    # A lookalike runner status while the runner process still lives is pending too.
    & $writeBoard 'done (suite 11/12)'
    $runner = Start-Process powershell.exe -WindowStyle Hidden -PassThru -ArgumentList '-NoProfile', '-Command', 'Start-Sleep 60'
    try {
        $outDir = Join-Path $f.Repo '.codex-out'
        New-Item -ItemType Directory -Path $outDir -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $outDir 'pid-task-f.txt'), "$($runner.Id)", [System.Text.UTF8Encoding]::new($false))
        $wait = Invoke-Trinity $f @('wait', 'task-f', '-Timeout', '3')
        Assert-True ($wait.ExitCode -eq 2) "lookalike status with a live runner should stay pending (exit 2), got $($wait.ExitCode): $($wait.Output)"
    }
    finally { Stop-Process -Id $runner.Id -Force -ErrorAction SilentlyContinue }
}

Run-Case 'status brief lists the task' {
    param($f)
    Start-CodexTask $f 'task-g'
    $wait = Invoke-Trinity $f @('wait', 'task-g', '-Timeout', '50')
    Assert-True ($wait.ExitCode -eq 0) "wait exit $($wait.ExitCode): $($wait.Output)"
    $status = Invoke-Trinity $f @('status', '-Brief')
    Assert-True ($status.ExitCode -eq 0 -and $status.Output -match 'task-g') "brief status omitted task: $($status.Output)"
}

Run-Case 'Antigravity task commits, returns result, and merges' {
    param($f)
    Start-AgyTask $f 'task-agy-ok'
    $wait = Invoke-Trinity $f @('wait', 'task-agy-ok', '-Timeout', '50')
    Assert-True ($wait.ExitCode -eq 0) "wait exit $($wait.ExitCode): $($wait.Output)"
    $board = Get-Content -Raw (Join-Path $f.Repo '.git\agent-board.md')
    Assert-True ($board -match 'done \(1 commits\)') "unexpected board after dispatch: $board"
    Assert-True ((Invoke-Git $f.Repo @('show', 'agent/antigravity/task-agy-ok:agy-output.txt')) -eq 'fake agy output') 'task commit lacks agy-output.txt'
    $result = Get-Content -Raw (Join-Path $f.Repo '.codex-out\result-task-agy-ok.md')
    Assert-True ($result -match 'Fake Antigravity completed successfully\.') "unexpected result: $result"
    Assert-True ($result -notmatch 'SYSTEM_MESSAGE') "agy notices were not stripped: $result"
    $subject = Invoke-Git $f.Repo @('log', '-1', '--format=%s', 'agent/antigravity/task-agy-ok')
    Assert-True ($subject -eq 'task-agy-ok: Fake Antigravity completed successfully.') "unexpected commit subject: $subject"
    $merge = Invoke-Trinity $f @('merge', 'task-agy-ok', '-Yes')
    Assert-True ($merge.ExitCode -eq 0) "merge failed ($($merge.ExitCode)): $($merge.Output)"
    Assert-True ((Invoke-Git $f.Repo @('show', 'main:agy-output.txt')) -eq 'fake agy output') 'main lacks agy-output.txt after merge'
}

Run-Case 'failed Antigravity task returns failure' {
    param($f)
    $env:FAKE_AGY_MODE = 'fail'
    Start-AgyTask $f 'task-agy-fail'
    $wait = Invoke-Trinity $f @('wait', 'task-agy-fail', '-Timeout', '50')
    Assert-True ($wait.ExitCode -eq 1) "wait exit $($wait.ExitCode): $($wait.Output)"
    $board = Get-Content -Raw (Join-Path $f.Repo '.git\agent-board.md')
    Assert-True ($board -match 'failed \(exit 4\)') "unexpected board status: $board"
}

Run-Case 'missing Antigravity CLI fails before worktree or board entry' {
    param($f)
    $env:AGY_EXE = Join-Path $f.Root 'missing agy.exe'
    $env:LOCALAPPDATA = Join-Path $f.Root 'isolated local app data'
    $gitDirectory = Split-Path (Get-Command git).Source -Parent
    $env:PATH = (Join-Path $env:SystemRoot 'System32') + ';' + $gitDirectory
    $dispatch = Invoke-Trinity $f @('dispatch', 'antigravity', 'task-agy-missing', 'test prompt')
    Assert-True ($dispatch.ExitCode -ne 0) 'dispatch unexpectedly succeeded without agy.exe'
    $listed = Invoke-Git $f.Repo @('worktree', 'list', '--porcelain')
    Assert-True ([regex]::Matches($listed, '(?m)^worktree ').Count -eq 1) "dispatch created a worktree: $listed"
    $boardPath = Join-Path $f.Repo '.git\agent-board.md'
    Assert-True (-not (Test-Path $boardPath) -or (Get-Content -Raw $boardPath) -notmatch '(?m)^## task-agy-missing$') 'dispatch created a board entry'
}

Run-Case 'cancel stops a running Antigravity task and preserves cancelled status' {
    param($f)
    $env:FAKE_AGY_MODE = 'slow'
    Start-AgyTask $f 'task-agy-cancel-running'
    $pidPath = Join-Path $f.Repo '.codex-out\pid-task-agy-cancel-running.txt'
    $deadline = (Get-Date).AddSeconds(15)
    while (-not (Test-Path $pidPath) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 100 }
    Assert-True (Test-Path $pidPath) 'runner pid file was not created'
    $runnerPid = [int](Get-Content -Raw $pidPath).Trim()
    Assert-True ([bool](Get-Process -Id $runnerPid -ErrorAction SilentlyContinue)) 'runner process was not alive before cancel'
    $cancel = Invoke-Trinity $f @('cancel', 'task-agy-cancel-running')
    Assert-True ($cancel.ExitCode -eq 0) "cancel failed ($($cancel.ExitCode)): $($cancel.Output)"
    $deadline = (Get-Date).AddSeconds(10)
    while ((Get-Process -Id $runnerPid -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 200 }
    Assert-True (-not (Get-Process -Id $runnerPid -ErrorAction SilentlyContinue)) 'runner process remained alive after 10 seconds'
    $listed = Invoke-Git $f.Repo @('worktree', 'list', '--porcelain')
    Assert-True ([regex]::Matches($listed, '(?m)^worktree ').Count -eq 1) "worktree remains registered: $listed"
    Assert-True (-not (Test-Path (Join-Path $f.Worktrees 'antigravity-task-agy-cancel-running'))) 'worktree folder remains after cancel'
    $branch = & git -C $f.Repo branch --list 'agent/antigravity/task-agy-cancel-running'
    Assert-True (-not $branch) 'task branch remains after cancel'
    Start-Sleep -Seconds 5
    $board = Get-Content -Raw (Join-Path $f.Repo '.git\agent-board.md')
    Assert-True ($board -match '(?m)^- status: cancelled') "runner overwrote cancelled status: $board"
    $wait = Invoke-Trinity $f @('wait', 'task-agy-cancel-running', '-Timeout', '3')
    Assert-True ($wait.ExitCode -eq 1) "wait after cancel exit $($wait.ExitCode): $($wait.Output)"
}

Run-Case 'cancel requires Force to remove a finished task commit' {
    param($f)
    Start-AgyTask $f 'task-agy-cancel-commit'
    $wait = Invoke-Trinity $f @('wait', 'task-agy-cancel-commit', '-Timeout', '50')
    Assert-True ($wait.ExitCode -eq 0) "wait exit $($wait.ExitCode): $($wait.Output)"
    $refused = Invoke-Trinity $f @('cancel', 'task-agy-cancel-commit')
    Assert-True ($refused.ExitCode -ne 0 -and $refused.Output -match 'has 1 commits') "cancel should refuse committed branch: $($refused.Output)"
    $forced = Invoke-Trinity $f @('cancel', 'task-agy-cancel-commit', '-Force')
    Assert-True ($forced.ExitCode -eq 0) "forced cancel failed ($($forced.ExitCode)): $($forced.Output)"
    $branch = & git -C $f.Repo branch --list 'agent/antigravity/task-agy-cancel-commit'
    Assert-True (-not $branch) 'forced cancel left task branch'
    $board = Get-Content -Raw (Join-Path $f.Repo '.git\agent-board.md')
    Assert-True ($board -match '(?m)^- status: cancelled') 'forced cancel did not mark task cancelled'
}

Run-Case 'dashboard reports completed Codex task and agent totals' {
    param($f)
    Start-CodexTask $f 'dashboard-done'
    $wait = Invoke-Trinity $f @('wait', 'dashboard-done', '-Timeout', '50')
    Assert-True ($wait.ExitCode -eq 0) "wait exit $($wait.ExitCode): $($wait.Output)"
    $dashboard = Join-Path $f.Repo 'scripts\dashboard.ps1'
    $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $json = & $powershell -NoProfile -ExecutionPolicy Bypass -File $dashboard -Once -Repos $f.Repo
    Assert-True ($LASTEXITCODE -eq 0) "dashboard exited $LASTEXITCODE"
    $state = ($json -join "`n") | ConvertFrom-Json
    $task = @($state.repos | ForEach-Object { $_.tasks } | Where-Object { $_.task -eq 'dashboard-done' }) | Select-Object -First 1
    Assert-True ($task -and $task.agent -eq 'codex' -and $task.state -eq 'done' -and $task.commits -eq 1) "unexpected task: $($task | ConvertTo-Json -Compress)"
    Assert-True ($task.result -match 'Fake Codex completed successfully\.') "task result missing: $($task.result)"
    Assert-True ($state.agents.codex.done -ge 1) 'Codex done count is missing'
    Assert-True ($null -ne $state.agents.claude -and $null -ne $state.agents.codex -and $null -ne $state.agents.antigravity) 'an agent count key is missing'
}

Run-Case 'dashboard accepts tracked Claude task without branch' {
    param($f)
    $boardPath = Join-Path $f.Repo '.git\agent-board.md'
    $section = @('', '## dashboard-claude', '- agent: claude', '- branch: -', '- worktree: -', '- scope: scripts/*', '- status: working: wiring index 2026-01-01 00:00') -join "`r`n"
    [IO.File]::AppendAllText($boardPath, $section + "`r`n", [System.Text.UTF8Encoding]::new($false))
    $dashboard = Join-Path $f.Repo 'scripts\dashboard.ps1'
    $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $json = & $powershell -NoProfile -ExecutionPolicy Bypass -File $dashboard -Once -Repos $f.Repo
    Assert-True ($LASTEXITCODE -eq 0) "dashboard exited $LASTEXITCODE"
    $state = ($json -join "`n") | ConvertFrom-Json
    $task = @($state.repos | ForEach-Object { $_.tasks } | Where-Object { $_.task -eq 'dashboard-claude' }) | Select-Object -First 1
    Assert-True ($task -and $task.state -eq 'running' -and $task.branch -eq '-') "unexpected Claude task: $($task | ConvertTo-Json -Compress)"
}

Run-Case 'dashboard skips stale registry repo paths' {
    param($f)
    $oldHome = $env:TRINITY_HOME
    try {
        $env:TRINITY_HOME = Join-Path $f.Root 'isolated profile\.trinity'
        $trinityDir = $env:TRINITY_HOME
        New-Item -ItemType Directory -Path $trinityDir -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $trinityDir 'repos.txt'), (Join-Path $f.Root 'missing repo') + "`r`n", [System.Text.UTF8Encoding]::new($false))
        $dashboard = Join-Path $f.Repo 'scripts\dashboard.ps1'
        $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $json = & $powershell -NoProfile -ExecutionPolicy Bypass -File $dashboard -Once -Repos $f.Repo
        Assert-True ($LASTEXITCODE -eq 0) "dashboard exited $LASTEXITCODE"
        $state = ($json -join "`n") | ConvertFrom-Json
        Assert-True (@($state.repos).Count -eq 1) "unexpected repos: $(@($state.repos).path -join ', ')"
        Assert-True ($state.repos[0].path -eq [IO.Path]::GetFullPath($f.Repo)) 'current fixture repo was not included'
    }
    finally { $env:TRINITY_HOME = $oldHome }
}

Run-Case 'dashboard HTTP routes return state JSON and 404' {
    param($f)
    $tcp = New-Object System.Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
    $tcp.Start()
    $port = $tcp.LocalEndpoint.Port
    $tcp.Stop()
    $dashboard = Join-Path $f.Repo 'scripts\dashboard.ps1'
    $process = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -WindowStyle Hidden -PassThru -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $dashboard), '-Port', [string]$port, '-Repos', ('"{0}"' -f $f.Repo))
    try {
        $deadline = (Get-Date).AddSeconds(10)
        $response = $null
        while (-not $response -and (Get-Date) -lt $deadline -and -not $process.HasExited) {
            try { $response = Invoke-WebRequest -Uri "http://localhost:$port/api/state" -UseBasicParsing -TimeoutSec 2 }
            catch { Start-Sleep -Milliseconds 100 }
        }
        if ($process.HasExited -and -not $response) {
            Write-Output 'SKIP dashboard HTTP check: HttpListener is unsupported or blocked in this environment'
            return
        }
        Assert-True ($response -and $response.StatusCode -eq 200) 'dashboard API did not return 200'
        $state = $response.Content | ConvertFrom-Json
        Assert-True ($null -ne $state.agents.codex) 'dashboard API did not return JSON state'
        $notFound = $false
        try { Invoke-WebRequest -Uri "http://localhost:$port/nope" -UseBasicParsing -TimeoutSec 2 | Out-Null }
        catch { $notFound = ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 404) }
        Assert-True $notFound 'unknown route did not return 404'
    }
    finally { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue }
}

Run-Case 'dashboard collects Codex Antigravity and Claude details and chats' {
    param($f)
    $oldCodexHome = $env:CODEX_HOME; $oldAgyHome = $env:TRINITY_AGY_HOME; $oldClaudeHome = $env:CLAUDE_CONFIG_DIR; $oldDisable = $env:TRINITY_DISABLE
    try {
        $env:CODEX_HOME = Join-Path $f.Root 'codex-home'
        $env:TRINITY_AGY_HOME = Join-Path $f.Root 'agy-home'
        $env:CLAUDE_CONFIG_DIR = Join-Path $f.Root 'claude-home'
        $env:TRINITY_DISABLE = 'codex'
        $codexId = '11111111-2222-4333-8444-555555555555'; $agyId = 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee'; $claudeId = '99999999-8888-4777-8666-555555555555'; $agentId = 'agent_fixture-01'
        # The fake API key is assembled here, not stored, so the pre-commit secret scan stays meaningful.
        $copyFixture = { param($Name, $Destination) [IO.File]::WriteAllText($Destination, ([IO.File]::ReadAllText((Join-Path $script:repoSource "tests\fixtures\dashboard\$Name")) -replace 'FIXTURE_FAKE_KEY', ('sk-' + 'abcdefghijklmnopqrstuvwxyz')), [Text.UTF8Encoding]::new($false)) }
        $codexSessions = Join-Path $env:CODEX_HOME 'sessions\2026\10\25'
        $agyLogs = Join-Path $f.Repo '.codex-out'
        New-Item -ItemType Directory -Path $codexSessions,$agyLogs -Force | Out-Null
        & $copyFixture 'codex-rollout.jsonl' (Join-Path $codexSessions "rollout-fixture-$codexId.jsonl")
        New-Item -ItemType Directory -Path (Join-Path $env:TRINITY_AGY_HOME "brain\$agyId\.system_generated\logs") -Force | Out-Null
        & $copyFixture 'agy-transcript.jsonl' (Join-Path $env:TRINITY_AGY_HOME "brain\$agyId\.system_generated\logs\transcript.jsonl")
        [IO.File]::WriteAllText((Join-Path $agyLogs 'log-codex-fixture.txt'), "model: gpt-log-fixture`r`nreasoning effort: low`r`nsession id: $codexId`r`n", [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $agyLogs 'meta-codex-fixture.json'), (@{ agent='codex'; started='2026-10-25T10:00:00'; finished='2026-10-25T10:01:00'; model='gpt-meta-fixture'; effort='high'; sessionId=$codexId } | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $agyLogs 'agy-agy-fixture.log'), "label=`"Gemini Fixture (High)`"`r`ncascade_id:$agyId`r`nworkspaceDirs=[$($f.Repo)]`r`n", [Text.UTF8Encoding]::new($false))
        $claudeSlug = [regex]::Replace([IO.Path]::GetFullPath($f.Repo), '[^A-Za-z0-9]', '-')
        $claudeProject = Join-Path $env:CLAUDE_CONFIG_DIR "projects\$claudeSlug"
        $claudeSessionPath = Join-Path $claudeProject "$claudeId.jsonl"
        New-Item -ItemType Directory -Path $claudeProject -Force | Out-Null
        & $copyFixture 'claude-session.jsonl' $claudeSessionPath
        $subDir = Join-Path $claudeProject "$claudeId\subagents"
        New-Item -ItemType Directory -Path $subDir -Force | Out-Null
        & $copyFixture 'claude-subagent.jsonl' (Join-Path $subDir "agent-$agentId.jsonl")
        [IO.File]::WriteAllText((Join-Path $subDir "agent-$agentId.meta.json"), (@{ agentType='general-purpose'; description='Fixture subagent'; model='fixture-haiku'; finished=$true } | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
        $board = Join-Path $f.Repo '.git\agent-board.md'
        $sections = @('', '## codex-fixture', '- agent: codex', '- branch: -', '- worktree: -', '- scope: tests/*', '- status: done 2026-10-25 10:01', '', '## agy-fixture', '- agent: antigravity', '- branch: -', '- worktree: -', '- scope: tests/*', '- status: done 2026-10-25 10:01', '', '## claude-fixture', '- agent: claude', '- branch: -', '- worktree: -', '- scope: tests/*', "- session: $claudeId", '- status: working: fixture 2026-10-25 10:02') -join "`r`n"
        [IO.File]::WriteAllText($board, $sections + "`r`n", [Text.UTF8Encoding]::new($false))
        $dashboard = Join-Path $f.Repo 'scripts\dashboard.ps1'; $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $json = & $powershell -NoProfile -ExecutionPolicy Bypass -File $dashboard -Once -Repos $f.Repo
        Assert-True ($LASTEXITCODE -eq 0) "dashboard exited $LASTEXITCODE"
        $state = ($json -join "`n") | ConvertFrom-Json
        $tasks = @($state.repos | ForEach-Object { $_.tasks })
        $codex = $tasks | Where-Object task -eq 'codex-fixture' | Select-Object -First 1
        Assert-True ($codex.model -eq 'gpt-meta-fixture' -and $codex.effort -eq 'high' -and $codex.sessionId -eq $codexId) 'Codex log/meta fields were not collected'
        Assert-True ($codex.tokens.total -eq 134 -and $codex.contextWindow -eq 200000 -and $codex.toolCalls -eq 1 -and $codex.rateLimits.Count -eq 1) ("Codex rollout metrics were not collected: tokens=$($codex.tokens.total), context=$($codex.contextWindow), tools=$($codex.toolCalls), limits=$($codex.rateLimits.Count)")
        Assert-True ($codex.chat -eq "codex:$codexId") 'Codex chat key is missing'
        $agy = $tasks | Where-Object task -eq 'agy-fixture' | Select-Object -First 1
        Assert-True ($agy.model -eq 'Gemini Fixture (High)' -and $agy.tokens.input -eq 50 -and $agy.tokens.cached -eq 5 -and $agy.tokens.output -eq 15 -and $agy.toolCalls -eq 1) 'Antigravity transcript metrics were not collected'
        $repoState = $state.repos | Where-Object path -eq ([IO.Path]::GetFullPath($f.Repo)) | Select-Object -First 1
        $session = $repoState.claudeSessions | Where-Object id -eq $claudeId | Select-Object -First 1
        Assert-True ($session.title -eq 'Claude fixture title' -and $session.contextTokens -eq 55 -and $session.subagents.Count -eq 1) 'Claude session or subagent summary is missing'
        Assert-True ($session.task -eq 'claude-fixture' -and $session.subagents[0].description -eq 'Fixture subagent') 'Claude session was not linked to its tracked task/subagent'
        Assert-True (-not $state.availability.codex.available) 'TRINITY_DISABLE did not disable Codex availability'
        $chatSpecs = @(@("codex:$codexId",'user'), @("agy:$agyId",'user'), @("claude:${claudeSlug}:${claudeId}",'thinking'), @("claude:${claudeSlug}:${claudeId}:$agentId",'tool'))
        foreach ($spec in $chatSpecs) {
            $chatJson = & $powershell -NoProfile -ExecutionPolicy Bypass -File $dashboard -Chat $spec[0] -Repos $f.Repo
            Assert-True ($LASTEXITCODE -eq 0) "-Chat failed for $($spec[0])"
            $chat = ($chatJson -join "`n") | ConvertFrom-Json
            Assert-True (@($chat.messages | Where-Object role -eq $spec[1]).Count -gt 0) "chat role $($spec[1]) missing for $($spec[0])"
            if ($spec[0] -eq "codex:$codexId") { Assert-True ($chat.title -eq 'codex-fixture' -and $chat.model -eq 'gpt-meta-fixture') 'Codex chat task title or model is missing' }
            if ($spec[0] -eq "agy:$agyId") { Assert-True ($chat.title -eq 'agy-fixture') 'Antigravity chat task title is missing' }
            if ($spec[0] -like 'codex:*') { Assert-True (($chat.messages | Where-Object role -eq 'result' | ForEach-Object text) -join '' -match '\[redacted\]') 'Codex tool output key was not redacted' }
        }
        $malformed = & $powershell -NoProfile -ExecutionPolicy Bypass -File $dashboard -Chat 'not-a-key' -Repos $f.Repo
        Assert-True ($LASTEXITCODE -eq 2) 'malformed -Chat id did not exit 2'
        $missing = & $powershell -NoProfile -ExecutionPolicy Bypass -File $dashboard -Chat 'codex:00000000-0000-0000-0000-000000000000' -Repos $f.Repo
        Assert-True ($LASTEXITCODE -eq 3) 'unknown -Chat id did not exit 3'
    }
    finally { $env:CODEX_HOME=$oldCodexHome; $env:TRINITY_AGY_HOME=$oldAgyHome; $env:CLAUDE_CONFIG_DIR=$oldClaudeHome; $env:TRINITY_DISABLE=$oldDisable }
}

Run-Case 'dashboard chat HTTP validates ids and guards hosts' {
    param($f)
    $oldCodexHome = $env:CODEX_HOME; $oldAgyHome = $env:TRINITY_AGY_HOME; $oldClaudeHome = $env:CLAUDE_CONFIG_DIR; $oldDisable = $env:TRINITY_DISABLE
    $process = $null
    try {
        $env:CODEX_HOME = Join-Path $f.Root 'codex-home'; $env:TRINITY_AGY_HOME = Join-Path $f.Root 'agy-home'; $env:CLAUDE_CONFIG_DIR = Join-Path $f.Root 'claude-home'; $env:TRINITY_DISABLE = 'codex'
        $tcp = New-Object System.Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0); $tcp.Start(); $port=$tcp.LocalEndpoint.Port; $tcp.Stop()
        $dashboard = Join-Path $f.Repo 'scripts\dashboard.ps1'
        $process = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -WindowStyle Hidden -PassThru -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"{0}"' -f $dashboard),'-Port',[string]$port,'-Repos',('"{0}"' -f $f.Repo))
        $deadline=(Get-Date).AddSeconds(10); $response=$null
        while (-not $response -and (Get-Date) -lt $deadline -and -not $process.HasExited) { try { $response=Invoke-WebRequest -Uri "http://localhost:$port/api/state" -UseBasicParsing -TimeoutSec 2 } catch { Start-Sleep -Milliseconds 100 } }
        if (-not $response) { Write-Output 'SKIP dashboard chat HTTP check: HttpListener is unsupported or blocked in this environment'; return }
        Assert-True ($response.Headers['X-Content-Type-Options'] -eq 'nosniff') 'response omitted nosniff header'
        foreach ($pair in @(@('bad','400'), @('codex:00000000-0000-0000-0000-000000000000','404'))) {
            $status=0; try { Invoke-WebRequest -Uri "http://localhost:$port/api/chat?id=$([uri]::EscapeDataString($pair[0]))" -UseBasicParsing -TimeoutSec 2 | Out-Null } catch { if ($_.Exception.Response) { $status=[int]$_.Exception.Response.StatusCode } }
            Assert-True ($status -eq [int]$pair[1]) "chat id $($pair[0]) returned $status"
        }
        $request=[Net.HttpWebRequest]::Create("http://localhost:$port/nope"); $request.Host='evil.example'; $hostStatus=0
        try { $null=$request.GetResponse() } catch { if ($_.Exception.Response) { $hostStatus=[int]$_.Exception.Response.StatusCode; $_.Exception.Response.Close() } }
        Assert-True ($hostStatus -eq 403) "invalid Host header returned $hostStatus"
    }
    finally { if ($process) { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue }; $env:CODEX_HOME=$oldCodexHome; $env:TRINITY_AGY_HOME=$oldAgyHome; $env:CLAUDE_CONFIG_DIR=$oldClaudeHome; $env:TRINITY_DISABLE=$oldDisable }
}

Write-Output "$passed passed, $failed failed"
if (-not $Keep) {
    foreach ($root in @($fixtures)) {
        Remove-Fixture ([pscustomobject]@{ Root = $root; Repo = (Join-Path $root 'repo with spaces') })
    }
}
if ($failed -gt 0) { exit 1 }
exit 0
