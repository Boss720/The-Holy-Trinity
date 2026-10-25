param([switch]$Keep)

$ErrorActionPreference = 'Stop'
$repoSource = Split-Path $PSScriptRoot -Parent
$passed = 0
$failed = 0
$skipped = 0
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
    Copy-Item -LiteralPath (Join-Path $script:repoSource 'trinity.sh') -Destination $repo
    Copy-Item -LiteralPath (Join-Path $script:repoSource 'scripts') -Destination $repo -Recurse
    Copy-Item -LiteralPath (Join-Path $script:repoSource '.gitattributes') -Destination $repo
    New-Item -ItemType Directory -Path (Join-Path $repo 'tests') -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $script:repoSource 'tests\fake-codex.cmd') -Destination (Join-Path $repo 'tests')
    Copy-Item -LiteralPath (Join-Path $script:repoSource 'tests\fake-codex.ps1') -Destination (Join-Path $repo 'tests')
    Copy-Item -LiteralPath (Join-Path $script:repoSource 'tests\fake-agy.cmd') -Destination (Join-Path $repo 'tests')
    Copy-Item -LiteralPath (Join-Path $script:repoSource 'tests\fake-agy.ps1') -Destination (Join-Path $repo 'tests')
    Copy-Item -LiteralPath (Join-Path $script:repoSource 'tests\fake-claude.cmd') -Destination (Join-Path $repo 'tests')
    Copy-Item -LiteralPath (Join-Path $script:repoSource 'tests\fake-claude.ps1') -Destination (Join-Path $repo 'tests')
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
        FakeClaude = Join-Path $repo 'tests\fake-claude.cmd'
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

# A case that cannot run here ends with Skip-Case: it is counted as skipped, never as passed.
function Skip-Case([string]$Reason) {
    $skip = [Exception]::new($Reason)
    $skip.Data['TrinitySkip'] = $true
    throw $skip
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
    # Agent selection env: every case starts with all three fakes usable and nothing disabled.
    $savedEnv = @{}
    foreach ($envName in 'CLAUDE_EXE', 'TRINITY_DISABLE', 'TRINITY_REVIEWER', 'FAKE_CODEX_LOGGED_OUT', 'FAKE_CLAUDE_LOGGED_OUT', 'FAKE_CLAUDE_MODE', 'TRINITY_AGY_HOME', 'FAKE_AGY_TRANSCRIPT') {
        $savedEnv[$envName] = [Environment]::GetEnvironmentVariable($envName)
        [Environment]::SetEnvironmentVariable($envName, $null)
    }
    try {
        $fixture = New-Fixture $TestCommand
        $env:CODEX_EXE = $fixture.FakeCodex
        $env:AGY_EXE = $fixture.FakeAgy
        $env:CLAUDE_EXE = $fixture.FakeClaude
        # Agy transcripts come from the fixture, never from the user's real ~/.gemini.
        $env:TRINITY_AGY_HOME = Join-Path $fixture.Root 'agy-home'
        $env:FAKE_CODEX_MODE = 'ok'
        $env:FAKE_AGY_MODE = 'ok'
        $env:FAKE_REVIEW_OUTPUT = $null
        & $Body $fixture
        $script:passed++
        Write-Output "PASS $Name"
    }
    catch {
        if ($_.Exception.Data['TrinitySkip']) {
            $script:skipped++
            Write-Output "SKIP ${Name}: $($_.Exception.Message)"
            return
        }
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
        foreach ($envName in $savedEnv.Keys) { [Environment]::SetEnvironmentVariable($envName, $savedEnv[$envName]) }
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

Run-Case 'Antigravity commit uses the final turn, not narration from earlier turns' {
    param($f)
    $env:FAKE_AGY_MODE = 'narrate'
    Start-AgyTask $f 'agy-narrate'
    $wait = Invoke-Trinity $f @('wait', 'agy-narrate', '-Timeout', '50')
    Assert-True ($wait.ExitCode -eq 0) "wait exit $($wait.ExitCode): $($wait.Output)"
    $subject = Invoke-Git $f.Repo @('log', '-1', '--format=%s', 'agent/antigravity/agy-narrate')
    Assert-True ($subject -eq 'agy-narrate: Fake narrated summary.') "commit subject came from narration: $subject"
    $result = [IO.File]::ReadAllText((Join-Path $f.Repo '.codex-out\result-agy-narrate.md'))
    Assert-True ($result -notmatch 'Running tests' -and $result -match 'Second paragraph of the summary') "result is not the final turn: $result"
    # Without a transcript the whole answer is kept, so nothing is lost.
    $env:FAKE_AGY_TRANSCRIPT = 'none'
    Remove-Item -LiteralPath (Join-Path $env:TRINITY_AGY_HOME 'brain') -Recurse -Force
    Start-AgyTask $f 'agy-narrate-plain'
    $wait = Invoke-Trinity $f @('wait', 'agy-narrate-plain', '-Timeout', '50')
    Assert-True ($wait.ExitCode -eq 0) "wait exit $($wait.ExitCode): $($wait.Output)"
    $result = [IO.File]::ReadAllText((Join-Path $f.Repo '.codex-out\result-agy-narrate-plain.md'))
    Assert-True ($result -match 'Running tests' -and $result -match 'Second paragraph of the summary') "fallback dropped text: $result"
}

Run-Case 'trinity.sh keeps arguments with spaces from Git Bash' {
    param($f)
    # trinity.cmd started from Git Bash breaks here: the fixture path has a space and the note needs quotes.
    # git.exe may be <Git>\cmd\git.exe or, under Git Bash, <Git>\mingw64\bin\git.exe: walk up to <Git>\bin\bash.exe.
    $bash = ''
    $git = Get-Command git -ErrorAction SilentlyContinue
    $dir = if ($git) { Split-Path $git.Source -Parent } else { '' }
    for ($i = 0; $i -lt 4 -and $dir -and -not $bash; $i++) {
        if (Test-Path -LiteralPath (Join-Path $dir 'bin\bash.exe')) { $bash = Join-Path $dir 'bin\bash.exe' }
        $dir = Split-Path $dir -Parent
    }
    if (-not $bash) { Skip-Case 'Git Bash not found' }
    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    Push-Location -LiteralPath $f.Repo
    try {
        $out = & $bash -c "./trinity.sh track task-sh 'note with spaces'" 2>&1
        $ok = $LASTEXITCODE
        # Git Bash would rewrite this note into a path under its install folder.
        $slashOut = & $bash -c "./trinity.sh track task-slash '/army fan out'" 2>&1
        $slash = $LASTEXITCODE
        & $bash -c './trinity.sh track Bad_Name x' 2>&1 | Out-Null
        $bad = $LASTEXITCODE
    }
    finally { Pop-Location; $ErrorActionPreference = $oldPreference }
    Assert-True ($ok -eq 0) "trinity.sh track failed ($ok): $($out -join ' ')"
    $board = Get-Content -Raw (Join-Path $f.Repo '.git\agent-board.md')
    Assert-True ($board -match '(?m)^- status: working: note with spaces') "note with spaces did not arrive intact: $board"
    Assert-True ($slash -eq 0 -and $board -match '(?m)^- status: working: /army fan out') "note starting with / was rewritten ($slash): $($slashOut -join ' ')"
    Assert-True ($bad -eq 1) "trinity.sh did not pass the exit code through: $bad"
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

Run-Case 'missing Antigravity CLI with Codex off fails before worktree or board entry' {
    param($f)
    $env:AGY_EXE = Join-Path $f.Root 'missing agy.exe'
    $env:TRINITY_DISABLE = 'codex'
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

Run-Case 'no Codex: dispatch codex routes to Antigravity and records run metadata' {
    param($f)
    $env:FAKE_CODEX_LOGGED_OUT = '1'
    Start-CodexTask $f 'task-route'
    $wait = Invoke-Trinity $f @('wait', 'task-route', '-Timeout', '50')
    Assert-True ($wait.ExitCode -eq 0) "wait exit $($wait.ExitCode): $($wait.Output)"
    $board = Get-Content -Raw (Join-Path $f.Repo '.git\agent-board.md')
    Assert-True ($board -match '(?m)^- agent: antigravity' -and $board -match 'agent/antigravity/task-route') "task was not routed to antigravity: $board"
    $out = Join-Path $f.Repo '.codex-out'
    $result = [IO.File]::ReadAllText((Join-Path $out 'result-task-route.md'))
    Assert-True ($result -match 'Fake Antigravity completed' -and $result -notmatch 'SYSTEM_MESSAGE') "unexpected result: $result"
    $meta = [IO.File]::ReadAllText((Join-Path $out 'meta-task-route.json')) | ConvertFrom-Json
    Assert-True ($meta.agent -eq 'antigravity' -and $meta.started -and $meta.finished -and $meta.exitCode -eq 0) "meta lacks run fields: $($meta | ConvertTo-Json -Compress)"
    Assert-True ($meta.model -eq 'Fake Gemini (High)' -and $meta.sessionId -eq '11111111-2222-3333-4444-555555555555' -and $meta.tokens.total -eq 125) "meta lacks agy fields: $($meta | ConvertTo-Json -Compress)"
    Assert-True (Test-Path (Join-Path $out 'agy-task-route.log')) 'agy --log-file was not passed'
}

Run-Case 'no headless worker at all fails with a clear message' {
    param($f)
    $env:TRINITY_DISABLE = 'codex,antigravity'
    $dispatch = Invoke-Trinity $f @('dispatch', 'codex', 'task-none', 'test prompt')
    Assert-True ($dispatch.ExitCode -ne 0 -and $dispatch.Output -match 'no headless worker') "unexpected dispatch result: $($dispatch.Output)"
    Assert-True (-not (Test-Path (Join-Path $f.Worktrees 'codex-task-none'))) 'worktree created without a worker'
}

Run-Case 'no Codex: merge review by Claude blocks P1, clean review merges' {
    param($f)
    Start-AgyTask $f 'task-rc'
    $wait = Invoke-Trinity $f @('wait', 'task-rc', '-Timeout', '50')
    Assert-True ($wait.ExitCode -eq 0) "wait exit $($wait.ExitCode): $($wait.Output)"
    $env:TRINITY_DISABLE = 'codex'
    $env:FAKE_REVIEW_OUTPUT = '- [P1] broken thing - a.txt:1'
    $blocked = Invoke-Trinity $f @('merge', 'task-rc', '-Yes')
    Assert-True ($blocked.ExitCode -ne 0 -and $blocked.Output -match 'reviewer: claude' -and $blocked.Output -match 'P0/P1 findings') "P1 from Claude should block: $($blocked.Output)"
    Assert-True (Test-Path (Join-Path $f.Repo '.codex-out\review-diff-task-rc.patch')) 'reviewer got no patch file'
    $env:FAKE_REVIEW_OUTPUT = $null
    $merge = Invoke-Trinity $f @('merge', 'task-rc', '-Yes')
    Assert-True ($merge.ExitCode -eq 0) "clean Claude review should merge: $($merge.Output)"
}

Run-Case 'no Codex or Claude: Antigravity reviews, then tests alone gate' {
    param($f)
    Start-CodexTask $f 'task-ra'
    $wait = Invoke-Trinity $f @('wait', 'task-ra', '-Timeout', '50')
    Assert-True ($wait.ExitCode -eq 0) "wait exit $($wait.ExitCode): $($wait.Output)"
    $env:TRINITY_DISABLE = 'codex'
    $env:FAKE_CLAUDE_LOGGED_OUT = '1'
    $env:FAKE_REVIEW_OUTPUT = '- [P0] data loss - a.txt:2'
    $blocked = Invoke-Trinity $f @('merge', 'task-ra', '-Yes')
    Assert-True ($blocked.ExitCode -ne 0 -and $blocked.Output -match 'reviewer: antigravity') "Antigravity review should block P0: $($blocked.Output)"
    $env:TRINITY_REVIEWER = 'none'
    $merge = Invoke-Trinity $f @('merge', 'task-ra', '-Yes')
    Assert-True ($merge.ExitCode -eq 0 -and $merge.Output -match 'Tests alone gate') "unreviewed merge should pass on tests: $($merge.Output)"
}

Run-Case 'init installs the toolkit with subagents and the army skill' {
    param($f)
    foreach ($rel in @('.claude', '.agent', 'CLAUDE.md', 'GEMINI.md')) { Copy-Item -LiteralPath (Join-Path $script:repoSource $rel) -Destination $f.Repo -Recurse -Force }
    $target = Join-Path $f.Root 'init target'
    New-Item -ItemType Directory -Path $target -Force | Out-Null
    & git -C $target init -b main 2>&1 | Out-Null
    $init = Invoke-Trinity $f @('init', $target)
    Assert-True ($init.ExitCode -eq 0) "init failed: $($init.Output)"
    foreach ($rel in @('.claude\skills\army\SKILL.md', '.claude\agents\codex-worker.md', 'scripts\dashboard.ps1', 'trinity.sh')) {
        $dst = Join-Path $target $rel
        Assert-True ((Test-Path -LiteralPath $dst) -and ([IO.File]::ReadAllText($dst) -eq [IO.File]::ReadAllText((Join-Path $script:repoSource $rel)))) "init did not install $rel"
    }
    Assert-True (@([IO.File]::ReadAllLines((Join-Path $target '.gitattributes'))) -contains '*.sh text eol=lf') 'init did not keep trinity.sh on LF line endings'
}

Run-Case 'init merges or upgrades the SessionStart hook in a kept settings.json' {
    param($f)
    foreach ($rel in @('.claude', '.agent', 'CLAUDE.md', 'GEMINI.md')) { Copy-Item -LiteralPath (Join-Path $script:repoSource $rel) -Destination $f.Repo -Recurse -Force }
    $utf8 = New-Object Text.UTF8Encoding($false)
    $custom = Join-Path $f.Root 'custom settings'
    $legacy = Join-Path $f.Root 'legacy settings'
    foreach ($dir in @($custom, $legacy)) {
        New-Item -ItemType Directory -Path (Join-Path $dir '.claude') -Force | Out-Null
        & git -C $dir init -b main 2>&1 | Out-Null
    }
    [IO.File]::WriteAllText((Join-Path $custom '.claude\settings.json'), '{ "permissions": { "allow": [ "Bash(ls)" ] } }', $utf8)
    $oldHook = '{ "hooks": { "SessionStart": [ { "hooks": [ { "type": "command", "command": "powershell -NoProfile -ExecutionPolicy Bypass -File scripts/trinity.ps1 status -Brief" } ] } ] } }'
    [IO.File]::WriteAllText((Join-Path $legacy '.claude\settings.json'), $oldHook, $utf8)
    foreach ($pass in 1, 2) {
        foreach ($dir in @($custom, $legacy)) {
            $init = Invoke-Trinity $f @('init', $dir)
            Assert-True ($init.ExitCode -eq 0) "init pass $pass failed: $($init.Output)"
        }
    }
    $merged = [IO.File]::ReadAllText((Join-Path $custom '.claude\settings.json')) | ConvertFrom-Json
    Assert-True (@($merged.permissions.allow) -contains 'Bash(ls)') 'merge dropped the existing permissions'
    Assert-True (@($merged.hooks.SessionStart).Count -eq 1) "hook merged $(@($merged.hooks.SessionStart).Count) times"
    Assert-True ($merged.hooks.SessionStart[0].hooks[0].command -match 'rev-parse --show-toplevel') 'merged hook is not the toolkit hook'
    Assert-True (Test-Path (Join-Path $custom '.codex-out\settings.json.bak')) 'no backup of the original settings.json'
    $upgraded = [IO.File]::ReadAllText((Join-Path $legacy '.claude\settings.json')) | ConvertFrom-Json
    Assert-True ($upgraded.hooks.SessionStart[0].hooks[0].command -match "Join-Path \(git rev-parse --show-toplevel\) 'scripts/trinity.ps1'") "legacy hook not upgraded: $($upgraded.hooks.SessionStart[0].hooks[0].command)"
}

Run-Case 'board rejects bad and duplicate task names and frees merged names' {
    param($f)
    $bad = Invoke-Trinity $f @('track', 'Bad_Name', 'x')
    Assert-True ($bad.ExitCode -ne 0 -and $bad.Output -match 'lowercase') "track accepted a bad name: $($bad.Output)"
    Start-CodexTask $f 'dup'
    $wait = Invoke-Trinity $f @('wait', 'dup', '-Timeout', '50')
    Assert-True ($wait.ExitCode -eq 0) "wait exit $($wait.ExitCode): $($wait.Output)"
    $again = Invoke-Trinity $f @('dispatch', 'codex', 'dup', '-Scope', 'tests/*', '-PromptFile', $f.Prompt)
    Assert-True ($again.ExitCode -ne 0 -and $again.Output -match 'already on the board') "duplicate dispatch not refused: $($again.Output)"
    $track = Invoke-Trinity $f @('track', 'dup', 'x')
    Assert-True ($track.ExitCode -ne 0 -and $track.Output -match 'belongs to codex') "track took a codex task: $($track.Output)"
    $merge = Invoke-Trinity $f @('merge', 'dup', '-Yes')
    Assert-True ($merge.ExitCode -eq 0) "merge failed: $($merge.Output)"
    Start-CodexTask $f 'dup'
    $board = Get-Content -Raw (Join-Path $f.Repo '.git\agent-board.md')
    Assert-True ([regex]::Matches($board, '(?m)^## dup\r?$').Count -eq 1) "board holds duplicate sections: $board"
    Assert-True ($board -notmatch '(?m)^- status: merged') "merged section was not replaced: $board"
    Invoke-Trinity $f @('wait', 'dup', '-Timeout', '50') | Out-Null
}

Run-Case 'agy.cmd on PATH counts as Antigravity' {
    param($f)
    $bin = Join-Path $f.Root 'agy bin'
    New-Item -ItemType Directory -Path $bin -Force | Out-Null
    Copy-Item -LiteralPath $f.FakeAgy -Destination (Join-Path $bin 'agy.cmd')
    Copy-Item -LiteralPath (Join-Path $f.Repo 'tests\fake-agy.ps1') -Destination $bin
    $env:AGY_EXE = $null
    $env:LOCALAPPDATA = Join-Path $f.Root 'isolated local app data'
    $env:PATH = $bin + ';' + $env:PATH
    $status = Invoke-Trinity $f @('status', '-Brief')
    Assert-True ($status.Output -match 'antigravity ok') "agy.cmd not found: $($status.Output)"
}

Run-Case 'pre-commit hook checks renamed files' {
    param($f)
    Copy-Item -LiteralPath (Join-Path $script:repoSource '.githooks') -Destination $f.Repo -Recurse
    Invoke-Git $f.Repo @('config', 'core.hooksPath', '.githooks') | Out-Null
    $utf8 = New-Object Text.UTF8Encoding($false)
    $body = (1..30 | ForEach-Object { "line $_" }) -join "`n"
    [IO.File]::WriteAllText((Join-Path $f.Repo 'notes.txt'), $body + "`n", $utf8)
    Invoke-Git $f.Repo @('add', 'notes.txt') | Out-Null
    Invoke-Git $f.Repo @('commit', '-m', 'notes') | Out-Null
    Invoke-Git $f.Repo @('mv', 'notes.txt', 'moved.txt') | Out-Null
    $key = 'sk-' + ('A' * 24)
    [IO.File]::WriteAllText((Join-Path $f.Repo 'moved.txt'), $body + "`nkey=$key`n", $utf8)
    Invoke-Git $f.Repo @('add', 'moved.txt') | Out-Null
    $status = Invoke-Git $f.Repo @('diff', '--cached', '--name-status')
    Assert-True ($status -match '^R') "fixture is not a rename: $status"
    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $out = & git -C $f.Repo commit -m 'rename with key' 2>&1 }
    finally { $ErrorActionPreference = $oldPreference }
    Assert-True ($LASTEXITCODE -ne 0 -and ($out -join ' ') -match 'moved.txt: possible secret') "hook let a renamed secret through: $($out -join ' ')"
}

Run-Case 'review and ask use Codex when it is available' {
    param($f)
    foreach ($reviewArgs in @(@('review'), @('review', '--base', 'main'), @('review', '--commit', 'HEAD'))) {
        $review = Invoke-Trinity $f $reviewArgs
        Assert-True ($review.ExitCode -eq 0 -and $review.Output -match 'reviewer: codex' -and $review.Output -match 'No findings') "codex $($reviewArgs -join ' ') failed: $($review.Output)"
    }
    $bare = Invoke-Trinity $f @('review', '--commit')
    Assert-True ($bare.ExitCode -ne 0 -and $bare.Output -match 'needs a value' -and $bare.Output -notmatch 'reviewer:') "bare --commit did not fail with usage: $($bare.Output)"
    $ask = Invoke-Trinity $f @('ask', 'hello')
    Assert-True ($ask.ExitCode -eq 0 -and $ask.Output -match 'asking: codex') "codex ask failed: $($ask.Output)"
}

Run-Case 'no Codex: review, ask, status and track work' {
    param($f)
    $env:TRINITY_DISABLE = 'codex'
    [IO.File]::WriteAllText((Join-Path $f.Repo 'README.md'), "changed`r`n", [System.Text.UTF8Encoding]::new($false))
    $review = Invoke-Trinity $f @('review')
    Assert-True ($review.ExitCode -eq 0 -and $review.Output -match 'reviewer: claude' -and $review.Output -match 'No findings') "review fallback failed: $($review.Output)"
    Assert-True ([IO.File]::ReadAllText((Join-Path $f.Repo '.codex-out\review-diff-last.patch')) -match 'changed') 'review patch lacks the uncommitted change'
    $ask = Invoke-Trinity $f @('ask', 'what', 'is', 'this')
    Assert-True ($ask.ExitCode -eq 0 -and $ask.Output -match 'asking: claude') "ask fallback failed: $($ask.Output)"
    Assert-True (Test-Path (Join-Path $f.Repo '.codex-out\codex-last.md')) 'ask did not save its answer'
    $status = Invoke-Trinity $f @('status', '-Brief')
    Assert-True ($status.Output -match 'codex unavailable \(disabled by TRINITY_DISABLE\)' -and $status.Output -match 'antigravity ok') "status lacks availability: $($status.Output)"
    $oldSession = $env:CLAUDE_CODE_SESSION_ID
    try {
        $env:CLAUDE_CODE_SESSION_ID = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
        $track = Invoke-Trinity $f @('track', 'task-own', 'doing', 'it')
        Assert-True ($track.ExitCode -eq 0) "track failed: $($track.Output)"
        $board = Get-Content -Raw (Join-Path $f.Repo '.git\agent-board.md')
        Assert-True ($board -match '(?m)^- session: aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee\r?\n- status: working: doing it') "track did not link the session: $board"
    }
    finally { $env:CLAUDE_CODE_SESSION_ID = $oldSession }
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

Run-Case 'dashboard deduplicates repo candidates before collection' {
    param($f)
    $oldHome = $env:TRINITY_HOME; $oldCodexHome = $env:CODEX_HOME; $oldAgyHome = $env:TRINITY_AGY_HOME; $oldClaudeHome = $env:CLAUDE_CONFIG_DIR; $oldDisable = $env:TRINITY_DISABLE; $oldCollectLog = $env:TRINITY_DASHBOARD_TEST_COLLECT_LOG
    try {
        $env:TRINITY_HOME = Join-Path $f.Root 'isolated profile\.trinity'
        $env:CODEX_HOME = Join-Path $f.Root 'codex-home'; $env:TRINITY_AGY_HOME = Join-Path $f.Root 'agy-home'; $env:CLAUDE_CONFIG_DIR = Join-Path $f.Root 'claude-home'; $env:TRINITY_DISABLE = 'codex'
        $collectLog = Join-Path $f.Root 'repo-collect.log'; $env:TRINITY_DASHBOARD_TEST_COLLECT_LOG = $collectLog
        New-Item -ItemType Directory -Path $env:TRINITY_HOME -Force | Out-Null
        $registryPath = [IO.Path]::GetFullPath($f.Repo).ToUpperInvariant().TrimEnd('\') + '\' + "`r`n" + [IO.Path]::GetFullPath($f.Repo) + "`r`n"
        [IO.File]::WriteAllText((Join-Path $env:TRINITY_HOME 'repos.txt'), $registryPath, [Text.UTF8Encoding]::new($false))
        $dashboard = Join-Path $f.Repo 'scripts\dashboard.ps1'; $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $json = & $powershell -NoProfile -ExecutionPolicy Bypass -File $dashboard -Once -Repos $f.Repo
        Assert-True ($LASTEXITCODE -eq 0) "dashboard exited $LASTEXITCODE"
        $state = ($json -join "`n") | ConvertFrom-Json
        $repos = @($state.repos)
        Assert-True ($repos.Count -eq 1) "expected one repo state, found $($repos.Count)"
        Assert-True ($repos[0].path -ieq ([IO.Path]::GetFullPath($f.Repo))) "unexpected repo state path: $($repos[0].path)"
        $collects = @([IO.File]::ReadAllLines($collectLog) | Where-Object { $_ -eq [IO.Path]::GetFullPath($f.Repo).ToLowerInvariant() })
        Assert-True ($collects.Count -eq 1) "repo was collected $($collects.Count) times"
    }
    finally { $env:TRINITY_HOME = $oldHome; $env:CODEX_HOME = $oldCodexHome; $env:TRINITY_AGY_HOME = $oldAgyHome; $env:CLAUDE_CONFIG_DIR = $oldClaudeHome; $env:TRINITY_DISABLE = $oldDisable; $env:TRINITY_DASHBOARD_TEST_COLLECT_LOG = $oldCollectLog }
}

Run-Case 'dashboard caches Claude summaries and rejects non-loopback clients' {
    param($f)
    $oldHome = $env:TRINITY_HOME; $oldCodexHome = $env:CODEX_HOME; $oldAgyHome = $env:TRINITY_AGY_HOME; $oldClaudeHome = $env:CLAUDE_CONFIG_DIR; $oldDisable = $env:TRINITY_DISABLE; $oldSummaryLog = $env:TRINITY_DASHBOARD_TEST_CLAUDE_SUMMARY_LOG
    $process = $null
    try {
        $env:TRINITY_HOME = Join-Path $f.Root 'isolated profile\.trinity'; $env:CODEX_HOME = Join-Path $f.Root 'codex-home'; $env:TRINITY_AGY_HOME = Join-Path $f.Root 'agy-home'; $env:CLAUDE_CONFIG_DIR = Join-Path $f.Root 'claude-home'; $env:TRINITY_DISABLE = 'codex'
        $summaryLog = Join-Path $f.Root 'claude-summary.log'; $env:TRINITY_DASHBOARD_TEST_CLAUDE_SUMMARY_LOG = $summaryLog
        $slug = [regex]::Replace([IO.Path]::GetFullPath($f.Repo), '[^A-Za-z0-9]', '-')
        $project = Join-Path $env:CLAUDE_CONFIG_DIR "projects\$slug"; New-Item -ItemType Directory -Path $project -Force | Out-Null
        $stampNow = [datetime]::UtcNow
        for ($i = 1; $i -le 7; $i++) {
            $id = "session-$i"; $stamp = $stampNow.AddMinutes(-8 + $i).ToString('o')
            $line = (@{ type='custom-title'; customTitle="Title $i"; timestamp=$stamp } | ConvertTo-Json -Compress) + "`r`n"
            $path = Join-Path $project "$id.jsonl"; [IO.File]::WriteAllText($path, $line, [Text.UTF8Encoding]::new($false)); [IO.File]::SetLastWriteTime($path, (Get-Date).AddMinutes(-8 + $i))
        }
        $tcp = New-Object System.Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0); $tcp.Start(); $port = $tcp.LocalEndpoint.Port; $tcp.Stop()
        $dashboard = Join-Path $f.Repo 'scripts\dashboard.ps1'
        $process = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -WindowStyle Hidden -PassThru -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"{0}"' -f $dashboard),'-Port',[string]$port,'-Repos',('"{0}"' -f $f.Repo))
        $deadline = (Get-Date).AddSeconds(15); $response = $null
        while (-not $response -and (Get-Date) -lt $deadline -and -not $process.HasExited) { try { $response = Invoke-WebRequest -Uri "http://localhost:$port/api/state" -UseBasicParsing -TimeoutSec 60 } catch { Start-Sleep -Milliseconds 100 } }
        if (-not $response) { Skip-Case 'HttpListener is unsupported or blocked in this environment' }
        $state = $response.Content | ConvertFrom-Json; $repoState = @($state.repos | Where-Object path -eq ([IO.Path]::GetFullPath($f.Repo)))[0]; $sessions = @($repoState.claudeSessions)
        Assert-True ($sessions.Count -eq 5) "expected 5 Claude sessions, found $($sessions.Count)"
        Assert-True ((@($sessions | ForEach-Object id) -join ',') -eq 'session-7,session-6,session-5,session-4,session-3') "Claude sessions were not the 5 newest: $(@($sessions | ForEach-Object id) -join ',')"
        Assert-True (@([IO.File]::ReadAllLines($summaryLog)).Count -eq 5) 'dashboard summarized files outside the newest 5'
        $changedPath = Join-Path $project 'session-7.jsonl'
        $changedStamp = [datetime]::UtcNow.ToString('o'); $changedLine = (@{ type='custom-title'; customTitle='Updated title'; timestamp=$changedStamp } | ConvertTo-Json -Compress) + "`r`n"
        [IO.File]::AppendAllText($changedPath, $changedLine, [Text.UTF8Encoding]::new($false))
        $updatedResponse = Invoke-WebRequest -Uri "http://localhost:$port/api/state" -UseBasicParsing -TimeoutSec 60
        $updatedState = $updatedResponse.Content | ConvertFrom-Json; $updatedRepo = @($updatedState.repos | Where-Object path -eq ([IO.Path]::GetFullPath($f.Repo)))[0]
        Assert-True ((@($updatedRepo.claudeSessions | Where-Object id -eq 'session-7')[0]).title -eq 'Updated title') 'changed Claude summary was not invalidated from cache'
        $addresses = @([Net.Dns]::GetHostAddresses([Net.Dns]::GetHostName()) | Where-Object { $_.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork -and -not [Net.IPAddress]::IsLoopback($_) })
        if (-not $addresses.Count) { Skip-Case 'No non-loopback IPv4 address is available' }
        $client = New-Object Net.Sockets.TcpClient
        try {
            $client.Connect($addresses[0], $port); $stream = $client.GetStream(); $bytes = [Text.Encoding]::ASCII.GetBytes("GET /api/state HTTP/1.1`r`nHost: localhost:$port`r`nConnection: close`r`n`r`n"); $stream.Write($bytes, 0, $bytes.Length); $statusLine = (New-Object IO.StreamReader($stream)).ReadLine()
        }
        finally { $client.Close() }
        Assert-True ($statusLine -match '^HTTP/1\.[01] 403 ') "non-loopback request returned: $statusLine"
        $localhost = Invoke-WebRequest -Uri "http://localhost:$port/api/state" -UseBasicParsing -TimeoutSec 60
        Assert-True ($localhost.StatusCode -eq 200) 'localhost request stopped returning 200'
    }
    finally { if ($process) { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue }; $env:TRINITY_HOME = $oldHome; $env:CODEX_HOME = $oldCodexHome; $env:TRINITY_AGY_HOME = $oldAgyHome; $env:CLAUDE_CONFIG_DIR = $oldClaudeHome; $env:TRINITY_DISABLE = $oldDisable; $env:TRINITY_DASHBOARD_TEST_CLAUDE_SUMMARY_LOG = $oldSummaryLog }
}

Run-Case 'dashboard serves one shared snapshot to concurrent clients' {
    param($f)
    $oldHome=$env:TRINITY_HOME; $oldCollectLog=$env:TRINITY_DASHBOARD_TEST_COLLECT_LOG; $oldDemand=$env:TRINITY_DASHBOARD_TEST_DEMAND_SECONDS; $process=$null
    try {
        $env:TRINITY_HOME=Join-Path $f.Root 'isolated dashboard home'; $env:TRINITY_DASHBOARD_TEST_COLLECT_LOG=Join-Path $f.Root 'collect.log'; Remove-Item $env:TRINITY_DASHBOARD_TEST_COLLECT_LOG -Force -ErrorAction SilentlyContinue
        $tcp=New-Object System.Net.Sockets.TcpListener([Net.IPAddress]::Loopback,0); $tcp.Start(); $port=$tcp.LocalEndpoint.Port; $tcp.Stop()
        $dashboard=Join-Path $f.Repo 'scripts\dashboard.ps1'; $process=Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -WindowStyle Hidden -PassThru -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"{0}"' -f $dashboard),'-Port',[string]$port,'-Repos',('"{0}"' -f $f.Repo))
        $first=$null; $deadline=(Get-Date).AddSeconds(15)
        while(-not $first -and (Get-Date)-lt $deadline -and -not $process.HasExited){try{$first=Invoke-WebRequest -Uri "http://localhost:$port/api/state" -UseBasicParsing -TimeoutSec 60}catch{Start-Sleep -Milliseconds 100}}
        if(-not $first){Skip-Case 'HttpListener is unsupported or blocked in this environment'}
        $before=@([IO.File]::ReadAllLines($env:TRINITY_DASHBOARD_TEST_COLLECT_LOG)).Count
        $bodies=@()
        # Keep the request objects alongside their asynchronous handles for response collection.
        $clients=@(); for($i=0;$i -lt 6;$i++){ $client=[Net.HttpWebRequest]::Create("http://localhost:$port/api/state"); $clients+=,$client }
        $pending=@(); foreach($client in $clients){$pending+=,$client.BeginGetResponse($null,$client)}
        foreach($async in $pending){$client=[Net.HttpWebRequest]$async.AsyncState; $response=$client.EndGetResponse($async); try{$reader=New-Object IO.StreamReader($response.GetResponseStream());$bodies+=,$reader.ReadToEnd();$reader.Dispose()}finally{$response.Close()}}
        Assert-True (@($bodies | Select-Object -Unique).Count -eq 1) 'concurrent state requests did not receive identical snapshot bodies'
        $after=@([IO.File]::ReadAllLines($env:TRINITY_DASHBOARD_TEST_COLLECT_LOG)).Count
        Assert-True (($after-$before)-le 2) "collector ran $($after-$before) times during six concurrent requests"
        $age=$first.Headers['X-Snapshot-Age-Ms']; Assert-True ($age -match '^\d+$') "snapshot age header was missing or invalid: $age"
    }
    finally { if($process){Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue}; $env:TRINITY_HOME=$oldHome; $env:TRINITY_DASHBOARD_TEST_COLLECT_LOG=$oldCollectLog; $env:TRINITY_DASHBOARD_TEST_DEMAND_SECONDS=$oldDemand }
}

Run-Case 'dashboard collector idles without clients' {
    param($f)
    $oldHome=$env:TRINITY_HOME; $oldCollectLog=$env:TRINITY_DASHBOARD_TEST_COLLECT_LOG; $oldDemand=$env:TRINITY_DASHBOARD_TEST_DEMAND_SECONDS; $process=$null
    try {
        $env:TRINITY_HOME=Join-Path $f.Root 'isolated dashboard home'; $env:TRINITY_DASHBOARD_TEST_COLLECT_LOG=Join-Path $f.Root 'collect.log'; $env:TRINITY_DASHBOARD_TEST_DEMAND_SECONDS='2'; Remove-Item $env:TRINITY_DASHBOARD_TEST_COLLECT_LOG -Force -ErrorAction SilentlyContinue
        $tcp=New-Object System.Net.Sockets.TcpListener([Net.IPAddress]::Loopback,0); $tcp.Start(); $port=$tcp.LocalEndpoint.Port; $tcp.Stop()
        $dashboard=Join-Path $f.Repo 'scripts\dashboard.ps1'; $process=Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -WindowStyle Hidden -PassThru -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"{0}"' -f $dashboard),'-Port',[string]$port,'-RefreshSeconds','1','-Repos',('"{0}"' -f $f.Repo))
        $response=$null; $deadline=(Get-Date).AddSeconds(15)
        while(-not $response -and (Get-Date)-lt $deadline -and -not $process.HasExited){try{$response=Invoke-WebRequest -Uri "http://localhost:$port/api/state" -UseBasicParsing -TimeoutSec 60}catch{Start-Sleep -Milliseconds 100}}
        if(-not $response){Skip-Case 'HttpListener is unsupported or blocked in this environment'}
        Start-Sleep -Seconds 4; $settled=@([IO.File]::ReadAllLines($env:TRINITY_DASHBOARD_TEST_COLLECT_LOG)).Count; Start-Sleep -Seconds 3
        $final=@([IO.File]::ReadAllLines($env:TRINITY_DASHBOARD_TEST_COLLECT_LOG)).Count
        Assert-True ($final -eq $settled) "collector continued running without clients ($settled to $final collections)"
    }
    finally { if($process){Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue}; $env:TRINITY_HOME=$oldHome; $env:TRINITY_DASHBOARD_TEST_COLLECT_LOG=$oldCollectLog; $env:TRINITY_DASHBOARD_TEST_DEMAND_SECONDS=$oldDemand }
}

Run-Case 'dashboard state reply carries snapshot age' {
    param($f)
    $oldHome=$env:TRINITY_HOME; $oldCollectLog=$env:TRINITY_DASHBOARD_TEST_COLLECT_LOG; $process=$null
    try {
        $env:TRINITY_HOME=Join-Path $f.Root 'isolated dashboard home'; $env:TRINITY_DASHBOARD_TEST_COLLECT_LOG=Join-Path $f.Root 'collect.log'; Remove-Item $env:TRINITY_DASHBOARD_TEST_COLLECT_LOG -Force -ErrorAction SilentlyContinue
        $tcp=New-Object System.Net.Sockets.TcpListener([Net.IPAddress]::Loopback,0); $tcp.Start(); $port=$tcp.LocalEndpoint.Port; $tcp.Stop()
        $dashboard=Join-Path $f.Repo 'scripts\dashboard.ps1'; $process=Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -WindowStyle Hidden -PassThru -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"{0}"' -f $dashboard),'-Port',[string]$port,'-Repos',('"{0}"' -f $f.Repo))
        $response=$null; $deadline=(Get-Date).AddSeconds(15)
        while(-not $response -and (Get-Date)-lt $deadline -and -not $process.HasExited){try{$response=Invoke-WebRequest -Uri "http://localhost:$port/api/state" -UseBasicParsing -TimeoutSec 60}catch{Start-Sleep -Milliseconds 100}}
        if(-not $response){Skip-Case 'HttpListener is unsupported or blocked in this environment'}
        $age=$response.Headers['X-Snapshot-Age-Ms']; Assert-True ($age -match '^\d+$') "snapshot age header was missing or invalid: $age"
    }
    finally { if($process){Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue}; $env:TRINITY_HOME=$oldHome; $env:TRINITY_DASHBOARD_TEST_COLLECT_LOG=$oldCollectLog }
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
        if ($process.HasExited -and -not $response) { Skip-Case 'HttpListener is unsupported or blocked in this environment' }
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
        $codexId = '11111111-2222-4333-8444-555555555555'; $agyId = 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee'; $legacyId = 'bbbbbbbb-cccc-4ddd-8eee-ffffffffffff'; $claudeId = '99999999-8888-4777-8666-555555555555'; $agentId = 'agent_fixture-01'
        # The fake API key is assembled here, not stored, so the pre-commit secret scan stays meaningful.
        $copyFixture = { param($Name, $Destination) [IO.File]::WriteAllText($Destination, ([IO.File]::ReadAllText((Join-Path $script:repoSource "tests\fixtures\dashboard\$Name")) -replace 'FIXTURE_FAKE_KEY', ('sk-' + 'abcdefghijklmnopqrstuvwxyz')), [Text.UTF8Encoding]::new($false)) }
        $codexSessions = Join-Path $env:CODEX_HOME 'sessions\2026\10\25'
        $agyLogs = Join-Path $f.Repo '.codex-out'
        New-Item -ItemType Directory -Path $codexSessions,$agyLogs -Force | Out-Null
        & $copyFixture 'codex-rollout.jsonl' (Join-Path $codexSessions "rollout-fixture-$codexId.jsonl")
        # Real Codex child rollouts carry the parent's id in session_id; the child's own id is only in the file name and payload.id.
        $codexChildId = '22222222-3333-4444-8555-666666666666'; $codexNextDay = Join-Path $env:CODEX_HOME 'sessions\2026\10\26'
        New-Item -ItemType Directory -Path $codexNextDay -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $codexNextDay "rollout-fixture-$codexChildId.jsonl"), "{`"timestamp`":`"2026-10-26T00:00:01Z`",`"type`":`"session_meta`",`"payload`":{`"session_id`":`"$codexId`",`"id`":`"$codexChildId`",`"parent_thread_id`":`"$codexId`",`"source`":{`"subagent`":{`"other`":`"guardian`"}}}}`r`n", [Text.UTF8Encoding]::new($false))
        New-Item -ItemType Directory -Path (Join-Path $env:TRINITY_AGY_HOME "brain\$agyId\.system_generated\logs") -Force | Out-Null
        & $copyFixture 'agy-transcript.jsonl' (Join-Path $env:TRINITY_AGY_HOME "brain\$agyId\.system_generated\logs\transcript.jsonl")
        $legacyDir = Join-Path $env:TRINITY_AGY_HOME "brain\$legacyId\.system_generated\logs"
        New-Item -ItemType Directory -Path $legacyDir -Force | Out-Null
        $legacyText = [IO.File]::ReadAllText((Join-Path $script:repoSource 'tests\fixtures\dashboard\agy-legacy-transcript.jsonl'))
        $legacyText = $legacyText.Replace('FIXTURE_TASK_PATH', ((Join-Path $agyLogs 'task-agy-legacy.md').Replace('\', '/'))).Replace('FIXTURE_WORKTREE', $f.Repo.Replace('\', '/'))
        [IO.File]::WriteAllText((Join-Path $legacyDir 'transcript.jsonl'), $legacyText, [Text.UTF8Encoding]::new($false))
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
        $sections = @('', '## codex-fixture', '- agent: codex', '- branch: -', '- worktree: -', '- scope: tests/*', '- status: done 2026-10-25 10:01', '', '## agy-fixture', '- agent: antigravity', '- branch: -', '- worktree: -', '- scope: tests/*', '- status: done 2026-10-25 10:01', '', '## agy-legacy', '- agent: antigravity', '- branch: -', "- worktree: $($f.Repo)", '- scope: tests/*', '- status: done 2026-10-25 11:00', '', '## claude-fixture', '- agent: claude', '- branch: -', '- worktree: -', '- scope: tests/*', "- session: $claudeId", '- status: working: fixture 2026-10-25 10:02') -join "`r`n"
        [IO.File]::WriteAllText($board, $sections + "`r`n", [Text.UTF8Encoding]::new($false))
        $dashboard = Join-Path $f.Repo 'scripts\dashboard.ps1'; $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $json = & $powershell -NoProfile -ExecutionPolicy Bypass -File $dashboard -Once -Repos $f.Repo
        Assert-True ($LASTEXITCODE -eq 0) "dashboard exited $LASTEXITCODE"
        $state = ($json -join "`n") | ConvertFrom-Json
        $tasks = @($state.repos | ForEach-Object { $_.tasks })
        $codex = $tasks | Where-Object task -eq 'codex-fixture' | Select-Object -First 1
        Assert-True ($codex.model -eq 'gpt-meta-fixture' -and $codex.effort -eq 'high' -and $codex.sessionId -eq $codexId) 'Codex log/meta fields were not collected'
        Assert-True ($codex.tokens.total -eq 134 -and $codex.contextWindow -eq 200000 -and $codex.toolCalls -eq 2 -and $codex.rateLimits.Count -eq 1) ("Codex rollout metrics were not collected: tokens=$($codex.tokens.total), context=$($codex.contextWindow), tools=$($codex.toolCalls), limits=$($codex.rateLimits.Count)")
        Assert-True ($codex.contextUsed -eq 80 -and $codex.steps -eq 1 -and $codex.thinkingSteps -eq 1 -and $codex.lastTool -eq 'apply_patch' -and $codex.filesTouched[0] -eq 'C:/wt/new/exec.txt' -and $codex.filesTouched[1] -eq 'tests/fixture-created.txt' -and $codex.filesTouched[2] -eq 'src/render.ps1' -and @($codex.filesTouched).Count -eq 3 -and $codex.backgroundTasks -eq 1) 'Codex v3 fields were not collected'
        Assert-True (@($codex.toolBreakdown).Count -eq 2 -and @($codex.toolBreakdown | Where-Object { $_.name -eq 'apply_patch' -and $_.count -eq 1 }).Count -eq 1) 'Codex tool breakdown is wrong'
        Assert-True ($codex.chat -eq "codex:$codexId") 'Codex chat key is missing'
        $codexSubs = @($codex.subChats)
        Assert-True ($codexSubs.Count -eq 1 -and $codexSubs[0].chat -eq "codex:$codexChildId" -and $codexSubs[0].title -eq 'guardian') ("Codex subagent chat was not collected: " + (($codexSubs | ForEach-Object { "$($_.chat)/$($_.title)" }) -join ', '))
        $agy = $tasks | Where-Object task -eq 'agy-fixture' | Select-Object -First 1
        Assert-True ($agy.model -eq 'Gemini Fixture (High)' -and $agy.tokens.input -eq 50 -and $agy.tokens.cached -eq 5 -and $agy.tokens.output -eq 15 -and $agy.toolCalls -eq 1) 'Antigravity transcript metrics were not collected'
        $legacy = $tasks | Where-Object task -eq 'agy-legacy' | Select-Object -First 1
        $legacyStart = ([datetime]::Parse('2026-10-25T00:00:00Z').ToLocalTime()).ToString("yyyy-MM-dd'T'HH:mm:ss")
        $legacyFinish = ([datetime]::Parse('2026-10-25T00:00:05Z').ToLocalTime()).ToString("yyyy-MM-dd'T'HH:mm:ss")
        Assert-True ($legacy.sessionId -eq $legacyId -and $legacy.model -eq 'Gemini 3.8 Legacy (High)' -and $legacy.chat -eq "agy:$legacyId" -and $legacy.tokens.total -eq 112) 'Legacy Antigravity task lookup, model, chat, or tokens are missing'
        Assert-True ($legacy.started -eq $legacyStart -and $legacy.finished -eq $legacyFinish -and $legacy.durationSec -eq 5) 'Legacy Antigravity transcript timing is wrong'
        Assert-True ($legacy.contextUsed -eq 57 -and $legacy.steps -eq 2 -and $legacy.thinkingSteps -eq 1 -and $legacy.toolCalls -eq 5 -and $legacy.backgroundTasks -eq 1 -and $legacy.lastTool -eq 'write_file') 'Legacy Antigravity v3 counts are wrong'
        Assert-True (@($legacy.toolBreakdown | Where-Object { $_.name -eq 'write_file' -and $_.count -eq 2 }).Count -eq 1 -and @($legacy.toolBreakdown | Where-Object { $_.name -eq 'manage_task' -and $_.count -eq 2 }).Count -eq 1 -and @($legacy.filesTouched).Count -eq 2 -and $legacy.filesTouched[0] -eq 'src/legacy.txt' -and $legacy.filesTouched[1] -eq 'src/second.txt') 'Legacy Antigravity tools or files are wrong'
        $claudeTask = $tasks | Where-Object task -eq 'claude-fixture' | Select-Object -First 1
        Assert-True ($claudeTask.contextUsed -eq 0 -and $claudeTask.steps -eq 0 -and $claudeTask.thinkingSteps -eq 0 -and @($claudeTask.toolBreakdown).Count -eq 0 -and @($claudeTask.filesTouched).Count -eq 0 -and $claudeTask.backgroundTasks -eq 0) 'Claude task v3 defaults are wrong'
        [IO.File]::WriteAllText((Join-Path $legacyDir 'transcript.jsonl'), $legacyText.Replace(' and changed setting `Model Selection` from None to Gemini 3.8 Legacy (High).', '.'), [Text.UTF8Encoding]::new($false))
        $cliDir = Join-Path $env:TRINITY_AGY_HOME 'log'; New-Item -ItemType Directory -Path $cliDir -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $cliDir 'cli-fixture.log'), "cascade_id:$legacyId label=`"Gemini CLI Fallback`"`r`n", [Text.UTF8Encoding]::new($false))
        $fallbackJson = & $powershell -NoProfile -ExecutionPolicy Bypass -File $dashboard -Once -Repos $f.Repo
        Assert-True ($LASTEXITCODE -eq 0) 'Dashboard failed during Antigravity model fallback check'
        $fallbackTask = @(($fallbackJson -join "`n" | ConvertFrom-Json).repos | ForEach-Object { $_.tasks } | Where-Object task -eq 'agy-legacy' | Select-Object -First 1)
        Assert-True ($fallbackTask -and $fallbackTask[0].model -eq 'Gemini CLI Fallback') 'Antigravity CLI log model fallback is missing'
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
        if (-not $response) { Skip-Case 'HttpListener is unsupported or blocked in this environment' }
        Assert-True ($response.Headers['X-Content-Type-Options'] -eq 'nosniff') 'response omitted nosniff header'
        foreach ($pair in @(@('bad','400'), @('codex:00000000-0000-0000-0000-000000000000','404'))) {
            $status=0; try { Invoke-WebRequest -Uri "http://localhost:$port/api/chat?id=$([uri]::EscapeDataString($pair[0]))" -UseBasicParsing -TimeoutSec 2 | Out-Null } catch { if ($_.Exception.Response) { $status=[int]$_.Exception.Response.StatusCode } }
            Assert-True ($status -eq [int]$pair[1]) "chat id $($pair[0]) returned $status"
        }
        # Raw request: http.sys answers 400 for a Host outside the listener prefix before the guard (403) sees it; both block.
        $client=New-Object Net.Sockets.TcpClient('127.0.0.1', $port); $hostLine=''
        try { $stream=$client.GetStream(); $bytes=[Text.Encoding]::ASCII.GetBytes("GET /api/state HTTP/1.1`r`nHost: evil.example:$port`r`nConnection: close`r`n`r`n"); $stream.Write($bytes,0,$bytes.Length); $hostLine=(New-Object IO.StreamReader($stream)).ReadLine() }
        finally { $client.Close() }
        Assert-True ($hostLine -match '^HTTP/1\.[01] (400|403) ') "invalid Host header returned: $hostLine"
    }
    finally { if ($process) { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue }; $env:CODEX_HOME=$oldCodexHome; $env:TRINITY_AGY_HOME=$oldAgyHome; $env:CLAUDE_CONFIG_DIR=$oldClaudeHome; $env:TRINITY_DISABLE=$oldDisable }
}

Write-Output "$passed passed, $failed failed, $skipped skipped"
if (-not $Keep) {
    foreach ($root in @($fixtures)) {
        Remove-Fixture ([pscustomobject]@{ Root = $root; Repo = (Join-Path $root 'repo with spaces') })
    }
}
if ($failed -gt 0) { exit 1 }
exit 0
