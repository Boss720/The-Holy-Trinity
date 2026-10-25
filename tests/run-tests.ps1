param([switch]$Keep)

$ErrorActionPreference = 'Stop'
$repoSource = Split-Path $PSScriptRoot -Parent
$passed = 0
$failed = 0
$fixtures = New-Object System.Collections.Generic.List[string]

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
        Prompt = Join-Path $repo 'tests\prompt.md'
        Worktrees = Join-Path $root 'repo with spaces.worktrees'
    }
}

function Invoke-Trinity($Fixture, [string[]]$Arguments) {
    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Fixture.Trinity @Arguments 2>&1 }
    finally { $ErrorActionPreference = $oldPreference }
    $code = $LASTEXITCODE
    return [pscustomobject]@{ ExitCode = $code; Output = ($output | Out-String) }
}

function Start-CodexTask($Fixture, [string]$Task) {
    [IO.File]::WriteAllText($Fixture.Prompt, "Perform the fixture task.`r`n", (New-Object Text.UTF8Encoding($false)))
    $result = Invoke-Trinity $Fixture @('dispatch', 'codex', $Task, '-Scope', 'tests/*', '-PromptFile', $Fixture.Prompt)
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
    $oldMode = $env:FAKE_CODEX_MODE
    $oldReview = $env:FAKE_REVIEW_OUTPUT
    try {
        $fixture = New-Fixture $TestCommand
        $env:CODEX_EXE = $fixture.FakeCodex
        $env:FAKE_CODEX_MODE = 'ok'
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
        $env:FAKE_CODEX_MODE = $oldMode
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

Run-Case 'bare codex done remains pending until runner finishes' {
    param($f)
    $wt = Join-Path $f.Worktrees 'codex-task-f'
    New-Item -ItemType Directory -Path $f.Worktrees -Force | Out-Null
    Invoke-Git $f.Repo @('worktree', 'add', '-b', 'agent/codex/task-f', $wt, 'main') | Out-Null
    $board = @(
        '',
        '## task-f',
        '- agent: codex',
        '- branch: agent/codex/task-f',
        "- worktree: $wt",
        '- scope: tests/*',
        '- status: started 2026-01-01 00:00'
    ) -join "`r`n"
    [IO.File]::AppendAllText((Join-Path $f.Repo '.git\agent-board.md'), $board + "`r`n", [System.Text.UTF8Encoding]::new($false))
    $done = Invoke-Trinity $f @('done', 'task-f')
    Assert-True ($done.ExitCode -eq 0) "done failed: $($done.Output)"
    $wait = Invoke-Trinity $f @('wait', 'task-f', '-Timeout', '3')
    Assert-True ($wait.ExitCode -eq 2) "bare done should timeout with exit 2, got $($wait.ExitCode): $($wait.Output)"
    Assert-True ($wait.Output -match 'status: done') "wait did not report bare done: $($wait.Output)"
}

Run-Case 'status brief lists the task' {
    param($f)
    Start-CodexTask $f 'task-g'
    $wait = Invoke-Trinity $f @('wait', 'task-g', '-Timeout', '50')
    Assert-True ($wait.ExitCode -eq 0) "wait exit $($wait.ExitCode): $($wait.Output)"
    $status = Invoke-Trinity $f @('status', '-Brief')
    Assert-True ($status.ExitCode -eq 0 -and $status.Output -match 'task-g') "brief status omitted task: $($status.Output)"
}

Write-Output "$passed passed, $failed failed"
if (-not $Keep) {
    foreach ($root in @($fixtures)) {
        Remove-Fixture ([pscustomobject]@{ Root = $root; Repo = (Join-Path $root 'repo with spaces') })
    }
}
if ($failed -gt 0) { exit 1 }
exit 0
