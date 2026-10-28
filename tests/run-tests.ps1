param([switch]$Keep, [string]$Only)

$ErrorActionPreference = 'Stop'
$repoSource = Split-Path $PSScriptRoot -Parent
$passed = 0
$failed = 0
$skipped = 0
$fixtures = New-Object System.Collections.Generic.List[string]
# GitHub runners hand out an 8.3 TEMP (a RUNNER~1 profile folder) while git and the toolkit report the long form, so the same
# fixture path would compare unequal. Run the whole suite on the long form.
Add-Type -Namespace TrinitySelfTest -Name Win32 -MemberDefinition '[System.Runtime.InteropServices.DllImport("kernel32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)] public static extern uint GetLongPathName(string shortPath, System.Text.StringBuilder longPath, uint bufferSize);'
$longTemp = New-Object System.Text.StringBuilder 1024
if ([TrinitySelfTest.Win32]::GetLongPathName($env:TEMP, $longTemp, 1024) -gt 0) { $env:TEMP = $longTemp.ToString(); $env:TMP = $env:TEMP }
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
    if ($script:Only -and $Name -notlike "*$($script:Only)*") { return }
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
    foreach ($envName in 'CLAUDE_EXE', 'TRINITY_DISABLE', 'TRINITY_REVIEWER', 'FAKE_CODEX_LOGGED_OUT', 'FAKE_CLAUDE_LOGGED_OUT', 'FAKE_CLAUDE_MODE', 'TRINITY_AGY_HOME', 'FAKE_AGY_TRANSCRIPT', 'TRINITY_ORCHESTRATOR', 'CODEX_THREAD_ID', 'CLAUDECODE', 'CLAUDE_CODE_SESSION_ID', 'ANTIGRAVITY_AGENT', 'ANTIGRAVITY_CONVERSATION_ID') {
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

# Run the CLI in its own script scope to avoid a shell startup for every housekeeping assertion.
function Invoke-CliTrinity($Fixture, [string[]]$Arguments) {
    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $cliParams = @{ Command = $Arguments[0] }
    $positionals = @()
    for ($i = 1; $i -lt $Arguments.Count; $i++) {
        $arg = $Arguments[$i]
        if ($arg -in @('-Json', '-Yes', '-Force')) { $cliParams[$arg.Substring(1)] = $true }
        elseif ($arg -in @('-Timeout', '-OlderThanDays')) { $cliParams[$arg.Substring(1)] = $Arguments[++$i] }
        else { $positionals += $arg }
    }
    $cliParams.Rest = $positionals
    $global:LASTEXITCODE = 0
    try { $output = & $Fixture.Trinity @cliParams *>&1 }
    finally { $ErrorActionPreference = $oldPreference }
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($output | Out-String) }
}

# CLI housekeeping fixtures use board files only inside their temporary repository.
function Set-CliTask($f, [string]$task, [string]$status, [string]$agent = 'codex') {
    $board = Join-Path $f.Repo '.git\agent-board.md'
    $text = "`r`n## $task`r`n- agent: $agent`r`n- branch: agent/$agent/$task`r`n- worktree: $(Join-Path $f.Worktrees "$agent-$task")`r`n- scope: tests/*`r`n- status: $status`r`n"
    [IO.File]::AppendAllText($board, $text, (New-Object Text.UTF8Encoding($false)))
}

Run-Case 'orchestrator detection order and status brief' {
    param($f)
    $env:CLAUDECODE = '1'
    $env:CODEX_THREAD_ID = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
    $status = Invoke-Trinity $f @('status', '-Brief')
    Assert-True ($status.ExitCode -eq 0 -and $status.Output -match '(?m)^agents:.*\r?\norchestrator: codex') "Codex detection failed: $($status.Output)"
    $env:ANTIGRAVITY_AGENT = '1'
    $status = Invoke-Trinity $f @('status', '-Brief')
    Assert-True ($status.Output -match 'orchestrator: antigravity') 'Antigravity did not beat inherited Codex'
    $env:TRINITY_ORCHESTRATOR = 'claude'
    $status = Invoke-Trinity $f @('status', '-Brief')
    Assert-True ($status.Output -match 'orchestrator: claude') 'orchestrator env override failed'
    $status = Invoke-Trinity $f @('status', '-Brief', '-Agent', 'codex')
    Assert-True ($status.Output -match 'orchestrator: codex') '-Agent did not beat env override'
    $env:TRINITY_ORCHESTRATOR = 'invalid'
    $status = Invoke-Trinity $f @('status', '-Brief')
    Assert-True ($status.Output -match 'orchestrator: antigravity') 'invalid env override was accepted'
    $env:ANTIGRAVITY_AGENT = $null; $env:CODEX_THREAD_ID = $null
    $status = Invoke-Trinity $f @('status', '-Brief')
    Assert-True ($status.Output -match 'orchestrator: claude') 'Claude detection failed'
    $env:CLAUDECODE = $null
    $status = Invoke-Trinity $f @('status', '-Brief')
    Assert-True ($status.Output -match 'orchestrator: claude') 'default orchestrator changed'
    $bad = Invoke-Trinity $f @('status', '-Agent', 'invalid')
    Assert-True ($bad.ExitCode -ne 0) 'invalid -Agent was accepted'
}

Run-Case 'orchestrator track links sessions preserves start and permits done' {
    param($f)
    foreach ($agent in @('codex', 'antigravity')) {
        $task = "own-$agent"
        $env:CODEX_THREAD_ID = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
        $env:ANTIGRAVITY_CONVERSATION_ID = '11111111-2222-3333-4444-555555555555'
        $session = if ($agent -eq 'codex') { $env:CODEX_THREAD_ID } else { $env:ANTIGRAVITY_CONVERSATION_ID }
        $track = Invoke-Trinity $f @('track', $task, 'doing work', '-Agent', $agent)
        Assert-True ($track.ExitCode -eq 0) "track failed: $($track.Output)"
        $board = Get-Content -Raw (Join-Path $f.Repo '.git\agent-board.md')
        Assert-True ($board -match "- agent: $agent" -and $board -match "- session: $session" -and $board -match '- branch: -') "track fields missing: $board"
        $metaFile = Join-Path $f.Repo ".codex-out\meta-$task.json"
        $meta = Get-Content -Raw $metaFile | ConvertFrom-Json
        Assert-True ($meta.agent -eq $agent -and $meta.sessionId -eq $session -and $meta.started) 'track metadata missing'
        $meta.started = '2001-01-01T00:00:00'
        [IO.File]::WriteAllText($metaFile, ($meta | ConvertTo-Json))
        $again = Invoke-Trinity $f @('track', $task, 'more work', '-Agent', $agent)
        $meta = Get-Content -Raw $metaFile | ConvertFrom-Json
        Assert-True ($again.ExitCode -eq 0 -and $meta.started -eq '2001-01-01T00:00:00') 'track reset started'
        $other = if ($agent -eq 'codex') { 'claude' } else { 'codex' }
        $refused = Invoke-Trinity $f @('track', $task, 'take over', '-Agent', $other)
        Assert-True ($refused.ExitCode -ne 0 -and $refused.Output -match "belongs to $agent") 'track stole another agent task'
        $done = Invoke-Trinity $f @('done', $task, 'finished', '-Agent', $other)
        Assert-True ($done.ExitCode -eq 0 -and $done.Output -match 'done: finished') "tracked done failed: $($done.Output)"
        $wait = Invoke-Trinity $f @('wait', $task, '-Timeout', '10')
        Assert-True ($wait.ExitCode -eq 0) "wait did not finish a tracked $agent task: $($wait.Output)"
    }
    $env:CODEX_THREAD_ID = 'not-a-guid'
    $track = Invoke-Trinity $f @('track', 'invalid-session', 'work', '-Agent', 'codex')
    $meta = Get-Content -Raw (Join-Path $f.Repo '.codex-out\meta-invalid-session.json') | ConvertFrom-Json
    Assert-True ($track.ExitCode -eq 0 -and -not $meta.sessionId) 'invalid session id was stored'
}

Run-Case 'orchestrator reviewer avoids author and honors explicit preference' {
    param($f)
    $review = Invoke-Trinity $f @('review', '-Agent', 'codex')
    Assert-True ($review.ExitCode -eq 0 -and $review.Output -match 'reviewer: claude') "Codex reviewed itself: $($review.Output)"
    $ask = Invoke-Trinity $f @('ask', 'hello', '-Agent', 'codex')
    Assert-True ($ask.ExitCode -eq 0 -and $ask.Output -match 'asking: claude') "Codex answered itself: $($ask.Output)"
    $env:TRINITY_REVIEWER = 'codex'
    $review = Invoke-Trinity $f @('review', '-Agent', 'codex')
    Assert-True ($review.Output -match 'reviewer: codex') 'explicit reviewer did not win'
    $env:TRINITY_REVIEWER = $null
    $env:TRINITY_DISABLE = 'claude,antigravity'
    $review = Invoke-Trinity $f @('review', '-Agent', 'codex')
    Assert-True ($review.ExitCode -eq 0 -and $review.Output -match 'reviewer: codex') 'sole available author was not used'
}

Run-Case 'orchestrator headless Claude commits parses result and refuses done' {
    param($f)
    $env:CLAUDECODE = '1'
    $run = Invoke-Trinity $f @('run', 'claude', 'claude-headless', '-Headless', '-PromptFile', $f.Prompt, '-Timeout', '60')
    Assert-True ($run.ExitCode -eq 0 -and $run.Output -match 'done \(1 commits\)') "headless Claude failed: $($run.Output)"
    $result = Get-Content -Raw (Join-Path $f.Repo '.codex-out\result-claude-headless.md')
    Assert-True ($result.Trim() -eq 'Fake Claude completed the task.') "JSON result not parsed: $result"
    $meta = Get-Content -Raw (Join-Path $f.Repo '.codex-out\meta-claude-headless.json') | ConvertFrom-Json
    Assert-True ($meta.agent -eq 'claude' -and $meta.sessionId -eq 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee' -and $meta.tokens.total -eq 2 -and $meta.durationSec -eq 0.01 -and $meta.costUsd -eq 0.01 -and $meta.model -eq 'fake-claude') 'Claude metadata missing'
    $taskFile = Get-Content -Raw (Join-Path $f.Repo '.codex-out\task-claude-headless.md')
    Assert-True ($taskFile -match 'Do not run git commit' -and $taskFile -notmatch 'then run in your worktree') 'Claude got interactive task rules'
    $done = Invoke-Trinity $f @('done', 'claude-headless')
    Assert-True ($done.ExitCode -ne 0 -and $done.Output -match 'its runner marks it done') 'done accepted headless Claude'
    $committed = Invoke-Git $f.Repo @('show', 'agent/claude/claude-headless:fake-claude.txt')
    Assert-True ($committed -eq 'fake Claude edit') 'Claude edit was not committed'
    $interactive = Invoke-Trinity $f @('dispatch', 'claude', 'claude-interactive', '-PromptFile', $f.Prompt)
    $board = Get-Content -Raw (Join-Path $f.Repo '.git\agent-board.md')
    Assert-True ($interactive.ExitCode -eq 0 -and $board -match 'waiting for claude session') 'interactive Claude dispatch changed'
    $doneInteractive = Invoke-Trinity $f @('done', 'claude-interactive', 'finished', 'by', 'hand')
    Assert-True ($doneInteractive.ExitCode -eq 0) "done refused an interactive Claude task: $($doneInteractive.Output)"
    $waitInteractive = Invoke-Trinity $f @('wait', 'claude-interactive', '-Timeout', '10')
    Assert-True ($waitInteractive.ExitCode -eq 0) "wait did not finish an interactive Claude task marked done: $($waitInteractive.Output)"
}

Run-Case 'orchestrator fallback uses headless Claude last and done refuses Codex' {
    param($f)
    $env:TRINITY_DISABLE = 'codex,antigravity'
    $run = Invoke-Trinity $f @('run', 'codex', 'claude-fallback', '-PromptFile', $f.Prompt, '-Timeout', '60')
    Assert-True ($run.ExitCode -eq 0 -and $run.Output -match 'routing claude-fallback to claude' -and $run.Output -match 'done \(1 commits\)') "Claude fallback failed: $($run.Output)"
    $env:TRINITY_DISABLE = $null
    Start-CodexTask $f 'codex-done'
    $done = Invoke-Trinity $f @('done', 'codex-done')
    Assert-True ($done.ExitCode -ne 0 -and $done.Output -match 'its runner marks it done') 'done accepted dispatched Codex'
    $wait = Invoke-Trinity $f @('wait', 'codex-done', '-Timeout', '60')
    Assert-True ($wait.ExitCode -eq 0) "Codex fixture did not finish: $($wait.Output)"
}

Run-Case 'cli-s5a show text, ASCII JSON, missing branch and unknown task' {
    param($f)
    Set-CliTask $f 'inspect' 'done (1 commits) 2026-01-01 00:00'
    Invoke-Git $f.Repo @('branch', 'agent/codex/inspect') | Out-Null
    $out = Join-Path $f.Repo '.codex-out'
    New-Item -ItemType Directory -Path $out -Force | Out-Null
    [IO.File]::WriteAllLines((Join-Path $out 'result-inspect.md'), [string[]](1..45 | ForEach-Object { "summary $_" }))
    [IO.File]::WriteAllLines((Join-Path $out 'log-inspect.txt'), [string[]](1..25 | ForEach-Object { "line $_" }))
    [IO.File]::AppendAllText((Join-Path $out 'log-inspect.txt'), [string][char]0x263a, (New-Object Text.UTF8Encoding($false)))
    $before = Get-Content -Raw (Join-Path $f.Repo '.git\agent-board.md')
    $show = Invoke-CliTrinity $f @('show', 'inspect')
    Assert-True ($show.ExitCode -eq 0 -and $show.Output -match 'name: inspect' -and $show.Output -match 'agent: codex' -and $show.Output -match 'commitsAhead: 0' -and $show.Output -match 'scope: tests/\*') "show fields absent: $($show.Output)"
    $json = Invoke-CliTrinity $f @('show', 'inspect', '-Json')
    $detail = $json.Output | ConvertFrom-Json
    Assert-True ($json.ExitCode -eq 0 -and $json.Output -notmatch '[^\x00-\x7f]' -and $detail.state -eq 'done' -and $detail.logTail.EndsWith([string][char]0x263a)) 'show JSON invalid or not ASCII'
    Assert-True ($detail.resultSummary -match 'summary 40$' -and $detail.resultSummary -notmatch 'summary 41' -and $detail.logTail -match 'line 25' -and $detail.logTail -notmatch 'line 5\r?\n') 'summary or log limit wrong'
    Assert-True ($detail.resultPath -eq (Join-Path $out 'result-inspect.md') -and $detail.logPath -eq (Join-Path $out 'log-inspect.txt')) 'file paths missing'
    Assert-True ((Get-Content -Raw (Join-Path $f.Repo '.git\agent-board.md')) -ceq $before) 'show changed board'
    Invoke-Git $f.Repo @('branch', '-D', 'agent/codex/inspect') | Out-Null
    $gone = Invoke-CliTrinity $f @('show', 'inspect', '-Json')
    Assert-True (($gone.Output | ConvertFrom-Json).diffstat -eq 'branch gone') 'deleted branch not reported'
    $unknown = Invoke-CliTrinity $f @('show', 'absent')
    Assert-True ($unknown.ExitCode -eq 1 -and $unknown.Output -match 'unknown task') 'unknown task accepted'
    $retry = Invoke-CliTrinity $f @('retry', 'inspect')
    Assert-True ($retry.ExitCode -eq 1 -and $retry.Output -match 'done') 'retry accepted done task'
}

Run-Case 'cli-s5a retry failed fake task preserves attempts and scope' {
    param($f)
    $out = Join-Path $f.Repo '.codex-out'
    New-Item -ItemType Directory -Path $out -Force | Out-Null
    Set-CliTask $f 'again' 'failed (exit 3) 2026-01-01 00:00'
    # Exercise task-file prompt recovery and stale worktree cleanup without a first worker run.
    $wt = Join-Path $f.Worktrees 'codex-again'
    Invoke-Git $f.Repo @('worktree', 'add', '-b', 'agent/codex/again', $wt, 'main') | Out-Null
    [IO.File]::WriteAllText((Join-Path $out 'task-again.md'), "# Task`r`n`r`n## Request`r`n`r`nRetry this exact prompt.`r`n`r`n## Rules`r`nold rules")
    [IO.File]::WriteAllText((Join-Path $out 'log-again.txt'), 'old failure')
    [IO.File]::WriteAllText((Join-Path $out 'result-again.md'), 'old result')
    $retryRunner = $null
    try {
        $retry = Invoke-CliTrinity $f @('retry', 'again')
        $pidFile = Join-Path $out 'pid-again.txt'
        if (Test-Path $pidFile) { $retryRunner = Get-Process -Id ([int](Get-Content -Raw $pidFile)) -ErrorAction SilentlyContinue }
        Assert-True ($retry.ExitCode -eq 0) "retry failed: $($retry.Output)"
        $wait = Invoke-CliTrinity $f @('wait', 'again', '-Timeout', '20')
        Assert-True ($wait.ExitCode -eq 0) "retry worker failed: $($wait.Output)"
        Assert-True ((Get-Content -Raw (Join-Path $out 'log-again.attempt1.txt')) -eq 'old failure') 'old log lost'
        Assert-True ((Get-Content -Raw (Join-Path $out 'result-again.attempt1.md')) -eq 'old result') 'old result lost'
        Assert-True ((Get-Content -Raw (Join-Path $out 'prompt-again.md')) -eq 'Retry this exact prompt.') 'recovered prompt changed'
        $taskText = Get-Content -Raw (Join-Path $out 'task-again.md')
        Assert-True ($taskText -match 'scope: tests/\*' -and $taskText -match 'Retry this exact prompt') 'redispatch lost scope/prompt'
    }
    finally {
        if ($retryRunner) {
            if (-not $retryRunner.HasExited) { $retryRunner.Kill(); [void]$retryRunner.WaitForExit(2000) }
            $retryRunner.Dispose()
        }
    }

    Set-CliTask $f 'missing' 'cancelled 2026-01-01 00:00' 'claude'
    $retry = Invoke-CliTrinity $f @('retry', 'missing')
    Assert-True ($retry.ExitCode -eq 1 -and $retry.Output -match 'missing prompt') 'retry without prompt accepted'
    $out = Join-Path $f.Repo '.codex-out'
    [IO.File]::WriteAllText((Join-Path $out 'prompt-missing.md'), 'original prompt')
    Invoke-Git $f.Repo @('branch', 'agent/claude/missing') | Out-Null
    # A commit on the task branch must require -Force.
    Invoke-Git $f.Repo @('checkout', 'agent/claude/missing') | Out-Null
    [IO.File]::WriteAllText((Join-Path $f.Repo 'extra.txt'), 'committed')
    Invoke-Git $f.Repo @('add', 'extra.txt') | Out-Null
    Invoke-Git $f.Repo @('commit', '-m', 'extra') | Out-Null
    Invoke-Git $f.Repo @('checkout', 'main') | Out-Null
    $retry = Invoke-CliTrinity $f @('retry', 'missing')
    Assert-True ($retry.ExitCode -eq 1 -and $retry.Output -match 'commits.*-Force') 'retry dropped commits without Force'
}

Run-Case 'cli-s5a clean previews, archives only old finished tasks, and keeps branches' {
    param($f)
    Set-CliTask $f 'old' 'merged 2020-01-01 00:00'
    Set-CliTask $f 'done' 'done 2020-01-01 00:00'
    Set-CliTask $f 'fresh' ("cancelled " + (Get-Date -Format 'yyyy-MM-dd HH:mm'))
    Invoke-Git $f.Repo @('branch', 'agent/codex/old') | Out-Null
    $out = Join-Path $f.Repo '.codex-out'
    New-Item -ItemType Directory -Path $out -Force | Out-Null
    foreach ($name in @('task-old.md','prompt-old.md','result-old.attempt1.md','log-old.txt','agy-old.log','agyout-old.json','meta-old.json','pid-old.txt','run-old.cmd','result-done.md','result-old-other.md')) {
        [IO.File]::WriteAllText((Join-Path $out $name), $name)
    }
    $boardPath = Join-Path $f.Repo '.git\agent-board.md'
    $before = Get-Content -Raw $boardPath
    $preview = Invoke-CliTrinity $f @('clean', '-OlderThanDays', '7')
    Assert-True ($preview.ExitCode -eq 0 -and $preview.Output -match 'old: merged' -and $preview.Output -notmatch 'done:|fresh:') 'clean candidate selection wrong'
    Assert-True ((Get-Content -Raw $boardPath) -ceq $before) 'preview changed board'
    Assert-True (-not (Test-Path (Join-Path $out 'archive'))) 'preview created archive'
    $clean = Invoke-CliTrinity $f @('clean', '-OlderThanDays', '7', '-Yes')
    Assert-True ($clean.ExitCode -eq 0) "clean failed: $($clean.Output)"
    Assert-True ((Get-Content -Raw $boardPath) -notmatch '## old\r?\n' -and (Get-Content -Raw $boardPath) -match '## done') 'clean board removal incorrect'
    Assert-True ((Get-Content -Raw (Join-Path $out 'archive\old\log-old.txt')) -eq 'log-old.txt') 'archive lost content'
    Assert-True (Test-Path (Join-Path $out 'archive\old\result-old.attempt1.md')) 'attempt not archived'
    Assert-True ((Test-Path (Join-Path $out 'result-done.md')) -and (Test-Path (Join-Path $out 'result-old-other.md'))) 'unrelated files archived'
    Assert-True ([bool](Invoke-Git $f.Repo @('branch', '--list', 'agent/codex/old'))) 'clean deleted branch'
    $again = Invoke-CliTrinity $f @('clean', '-Yes')
    Assert-True ($again.ExitCode -eq 0) 'second clean failed'
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
    $env:TRINITY_DISABLE = 'codex,claude'
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
    $env:TRINITY_DISABLE = 'codex,antigravity,claude'
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

# A GitHub release zip: the toolkit files in a folder with spaces, no .git anywhere around it.
function New-ReleaseCopy($Fixture) {
    $kit = Join-Path $Fixture.Root 'release copy\trinity-v0.0.0'
    New-Item -ItemType Directory -Path $kit -Force | Out-Null
    foreach ($rel in @('VERSION', 'trinity.cmd', 'trinity.sh', 'install.cmd', 'install.ps1', 'AGENTS.md', 'CLAUDE.md', 'GEMINI.md', 'scripts', '.agent', '.claude', '.githooks')) {
        $src = Join-Path $script:repoSource $rel
        if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src -Destination $kit -Recurse -Force }
    }
    [pscustomobject]@{ Kit = $kit; Trinity = (Join-Path $kit 'scripts\trinity.ps1'); Version = ([IO.File]::ReadAllText((Join-Path $script:repoSource 'VERSION'))).Trim() }
}

function Invoke-InFolder([string]$Folder, [scriptblock]$Body) {
    Push-Location -LiteralPath $Folder
    try { & $Body } finally { Pop-Location }
}

Run-Case 'release copy without .git: version and help run, repo commands say what is wrong' {
    param($f)
    $rel = New-ReleaseCopy $f
    Assert-True (-not (Test-Path (Join-Path $rel.Kit '.git'))) 'release copy must not be a git repo'
    Invoke-InFolder $f.Root {
        $version = Invoke-Trinity $rel @('version')
        Assert-True ($version.ExitCode -eq 0 -and $version.Output.Trim() -eq "trinity $($rel.Version)") "version output: $($version.Output)"
        $help = Invoke-Trinity $rel @('help')
        Assert-True ($help.ExitCode -eq 0 -and $help.Output -match 'doctor' -and $help.Output -match 'init <path>') "help output: $($help.Output)"
        $status = Invoke-Trinity $rel @('status')
        Assert-True ($status.ExitCode -ne 0 -and $status.Output -match 'not inside a git repo' -and $status.Output -match 'trinity init') "status outside a repo: $($status.Output)"
    }
    Assert-True (-not (Test-Path (Join-Path $rel.Kit '.codex-out'))) 'a repo-free command created .codex-out inside the release copy'
}

Run-Case 'release copy works on the repo of the current folder, not on a repo around the copy' {
    param($f)
    $outer = Join-Path $f.Root 'outer repo'
    New-Item -ItemType Directory -Path $outer -Force | Out-Null
    & git -C $outer init -b main 2>&1 | Out-Null
    $rel = New-ReleaseCopy ([pscustomobject]@{ Root = $outer })
    Invoke-InFolder $f.Root {
        $status = Invoke-Trinity $rel @('status')
        Assert-True ($status.ExitCode -ne 0 -and $status.Output -match 'not inside a git repo') "a repo around the release copy was used: $($status.Output)"
    }
    Invoke-InFolder $f.Repo {
        $status = Invoke-Trinity $rel @('status')
        Assert-True ($status.ExitCode -eq 0 -and $status.Output -match 'main checkout: branch=main') "status in the project folder: $($status.Output)"
    }
    Assert-True (Test-Path (Join-Path $f.Repo '.codex-out')) 'state was not created in the project repo'
    Assert-True (-not (Test-Path (Join-Path $rel.Kit '.codex-out'))) 'state was created inside the release copy'
}

Run-Case 'release copy: init installs a working copy into a project, version matches' {
    param($f)
    $rel = New-ReleaseCopy $f
    $target = Join-Path $f.Root 'my project'
    New-Item -ItemType Directory -Path $target -Force | Out-Null
    & git -C $target init -b main 2>&1 | Out-Null
    Invoke-InFolder $f.Root {
        $init = Invoke-Trinity $rel @('init', $target)
        Assert-True ($init.ExitCode -eq 0) "init failed: $($init.Output)"
    }
    foreach ($relPath in @('VERSION', 'trinity.cmd', 'scripts\trinity.ps1', 'scripts\lib\board.ps1', 'AGENTS.md', '.claude\settings.json')) {
        Assert-True (Test-Path -LiteralPath (Join-Path $target $relPath)) "init did not install $relPath"
    }
    if (Test-Path -LiteralPath (Join-Path $rel.Kit 'scripts\doctor.ps1')) {
        Assert-True (Test-Path -LiteralPath (Join-Path $target 'scripts\doctor.ps1')) 'init did not install scripts\doctor.ps1'
    }
    $installed = [pscustomobject]@{ Trinity = (Join-Path $target 'scripts\trinity.ps1') }
    Invoke-InFolder $target {
        $version = Invoke-Trinity $installed @('version')
        Assert-True ($version.Output.Trim() -eq "trinity $($rel.Version)") "installed version: $($version.Output)"
        $status = Invoke-Trinity $installed @('status')
        Assert-True ($status.ExitCode -eq 0 -and $status.Output -match 'main checkout') "status in the initialized project: $($status.Output)"
    }
}

Run-Case 'release copy as the only install: dispatch, wait and merge work on the project of the current folder' {
    param($f)
    $rel = New-ReleaseCopy $f
    $utf8 = New-Object Text.UTF8Encoding($false)
    $proj = Join-Path $f.Root 'plain project'
    New-Item -ItemType Directory -Path $proj -Force | Out-Null
    & git -C $proj init -b main 2>&1 | Out-Null
    Invoke-Git $proj @('config', 'user.name', 'Trinity Selftest') | Out-Null
    Invoke-Git $proj @('config', 'user.email', 'selftest@example.invalid') | Out-Null
    [IO.File]::WriteAllText((Join-Path $proj 'AGENTS.md'), ("# Plain`r`n`r`n" + '- Test: `exit 0`' + "`r`n"), $utf8)
    [IO.File]::WriteAllText((Join-Path $proj '.gitignore'), ".codex-out/`r`n", $utf8)
    Invoke-Git $proj @('add', '-A') | Out-Null
    Invoke-Git $proj @('commit', '-m', 'first') | Out-Null
    $prompt = Join-Path $f.Root 'plain-prompt.md'
    [IO.File]::WriteAllText($prompt, "Perform the fixture task.`r`n", $utf8)
    Invoke-InFolder $proj {
        $dispatch = Invoke-Trinity $rel @('dispatch', 'codex', 'rc-task', '-Scope', 'src/*', '-PromptFile', $prompt)
        Assert-True ($dispatch.ExitCode -eq 0) "dispatch failed ($($dispatch.ExitCode)): $($dispatch.Output)"
        $wait = Invoke-Trinity $rel @('wait', 'rc-task', '-Timeout', '50')
        Assert-True ($wait.ExitCode -eq 0) "wait exit $($wait.ExitCode): $($wait.Output)"
        $merge = Invoke-Trinity $rel @('merge', 'rc-task', '-Yes')
        Assert-True ($merge.ExitCode -eq 0) "merge failed ($($merge.ExitCode)): $($merge.Output)"
    }
    Assert-True ((Invoke-Git $proj @('show', 'main:fake-output.txt')) -eq 'fake codex output') 'project main lacks the merged file'
    Assert-True (-not (Test-Path (Join-Path $rel.Kit '.codex-out'))) 'state was created inside the release copy'
    & git -C $proj worktree prune 2>&1 | Out-Null
}

# doctor and the installer run from a release copy; git identity and logins are isolated from the real machine.
function Test-GlobalConfigOverride {
    $text = (& git --version 2>$null | Out-String)
    if ($text -notmatch 'git version (\d+)\.(\d+)') { return $false }
    return ([int]$Matches[1] -gt 2 -or ([int]$Matches[1] -eq 2 -and [int]$Matches[2] -ge 32))
}

function Invoke-WithGitConfig([string]$GlobalConfig, [scriptblock]$Body) {
    $names = 'GIT_CONFIG_GLOBAL', 'GIT_CONFIG_NOSYSTEM', 'TRINITY_DOCTOR_SKIP_LOGIN'
    $saved = @{}
    foreach ($n in $names) { $saved[$n] = [Environment]::GetEnvironmentVariable($n) }
    try {
        $env:GIT_CONFIG_GLOBAL = $GlobalConfig
        $env:GIT_CONFIG_NOSYSTEM = '1'
        $env:TRINITY_DOCTOR_SKIP_LOGIN = '1'
        & $Body
    }
    finally { foreach ($n in $names) { [Environment]::SetEnvironmentVariable($n, $saved[$n]) } }
}

function Invoke-Installer($Kit, [string[]]$Arguments) {
    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $output = & (Join-Path $Kit.Kit 'install.cmd') @Arguments 2>&1 }
    finally { $ErrorActionPreference = $oldPreference }
    $code = $LASTEXITCODE
    return [pscustomobject]@{ ExitCode = $code; Output = ($output | Out-String) }
}

function New-GitConfigFile($Fixture, [string]$Name, [bool]$WithIdentity) {
    $path = Join-Path $Fixture.Root $Name
    $text = if ($WithIdentity) { "[user]`r`n`tname = Selftest`r`n`temail = selftest@example.invalid`r`n" } else { "" }
    [IO.File]::WriteAllText($path, $text, (New-Object Text.UTF8Encoding($false)))
    return $path
}

Run-Case 'release copy: doctor passes with a git identity, prints a summary and valid -Json' {
    param($f)
    $rel = New-ReleaseCopy $f
    if (-not (Test-Path -LiteralPath (Join-Path $rel.Kit 'scripts\doctor.ps1'))) { return }
    if (-not (Test-GlobalConfigOverride)) { return }
    $cfg = New-GitConfigFile $f 'gitconfig-ok' $true
    Invoke-InFolder $f.Root {
        Invoke-WithGitConfig $cfg {
            $text = Invoke-Trinity $rel @('doctor')
            Assert-True ($text.ExitCode -eq 0) "doctor exit $($text.ExitCode): $($text.Output)"
            Assert-True ($text.Output -match '\[ OK \] git ' -and $text.Output -match 'doctor: \d+ ok, \d+ warnings, 0 failures') "doctor output: $($text.Output)"
            $json = Invoke-Trinity $rel @('doctor', '-Json')
            Assert-True ($json.ExitCode -eq 0) "doctor -Json exit $($json.ExitCode): $($json.Output)"
            $parsed = $json.Output | ConvertFrom-Json
            Assert-True ($parsed.fail -eq 0 -and $parsed.version -eq $rel.Version) "doctor -Json content: $($json.Output)"
            $names = @($parsed.checks | ForEach-Object { $_.name })
            foreach ($want in 'git', 'git-identity', 'workers') { Assert-True ($names -contains $want) "doctor -Json lacks the $want check" }
        }
    }
}

Run-Case 'release copy: doctor fails and says how to fix a missing git identity' {
    param($f)
    $rel = New-ReleaseCopy $f
    if (-not (Test-Path -LiteralPath (Join-Path $rel.Kit 'scripts\doctor.ps1'))) { return }
    if (-not (Test-GlobalConfigOverride)) { return }
    $cfg = New-GitConfigFile $f 'gitconfig-empty' $false
    Invoke-InFolder $f.Root {
        Invoke-WithGitConfig $cfg {
            $r = Invoke-Trinity $rel @('doctor')
            Assert-True ($r.ExitCode -eq 1) "doctor exit $($r.ExitCode): $($r.Output)"
            Assert-True ($r.Output -match '\[FAIL\] git-identity' -and $r.Output -match 'fix: git config --global user\.name') "doctor output: $($r.Output)"
        }
    }
}

Run-Case 'release copy: install.cmd -Check follows doctor, rejects bad options, changes nothing' {
    param($f)
    $rel = New-ReleaseCopy $f
    if (-not (Test-Path -LiteralPath (Join-Path $rel.Kit 'install.cmd'))) { return }
    if (-not (Test-GlobalConfigOverride)) { return }
    $cfg = New-GitConfigFile $f 'gitconfig-ok' $true
    $pathBefore = [Environment]::GetEnvironmentVariable('Path', 'User')
    Invoke-InFolder $f.Root {
        Invoke-WithGitConfig $cfg {
            $check = Invoke-Installer $rel @('-Check')
            Assert-True ($check.ExitCode -eq 0 -and $check.Output -match 'doctor: ') "install.cmd -Check exit $($check.ExitCode): $($check.Output)"
            $help = Invoke-Installer $rel @('-Help')
            Assert-True ($help.ExitCode -eq 0 -and $help.Output -match '-AddToPath') "install.cmd -Help: $($help.Output)"
            $bogus = Invoke-Installer $rel @('-Bogus')
            Assert-True ($bogus.ExitCode -eq 2 -and $bogus.Output -match 'unknown option') "install.cmd -Bogus exit $($bogus.ExitCode): $($bogus.Output)"
            $mixed = Invoke-Installer $rel @('-Check', '-AddToPath')
            Assert-True ($mixed.ExitCode -eq 2) "install.cmd -Check -AddToPath exit $($mixed.ExitCode): $($mixed.Output)"
        }
    }
    Assert-True ([Environment]::GetEnvironmentVariable('Path', 'User') -eq $pathBefore) 'install.cmd -Check changed the User PATH'
}

function Get-RawPathValue([string]$KeyName) {
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($KeyName)
    if (-not $key) { return $null }
    try { return [pscustomobject]@{ Text = [string]$key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames); Kind = [string]$key.GetValueKind('Path') } }
    finally { $key.Close() }
}

Run-Case 'release copy: install.cmd -AddToPath and -RemoveFromPath keep %VAR% entries and restore the PATH exactly' {
    param($f)
    $rel = New-ReleaseCopy $f
    if (-not (Test-Path -LiteralPath (Join-Path $rel.Kit 'install.cmd'))) { return }
    if (-not (Test-GlobalConfigOverride)) { return }
    $cfg = New-GitConfigFile $f 'gitconfig-ok' $true
    # A throwaway registry key stands in for HKCU\Environment; the real User PATH is never written.
    $keyName = 'Software\TrinitySelftest-' + [Guid]::NewGuid().ToString('N')
    $realBefore = [Environment]::GetEnvironmentVariable('Path', 'User')
    $savedKey = $env:TRINITY_USER_ENV_KEY
    $savedHome = $env:TRINITY_HOME
    $seed = '%USERPROFILE%\selftest-bin;C:\selftest-other'
    try {
        $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($keyName)
        $key.SetValue('Path', $seed, [Microsoft.Win32.RegistryValueKind]::ExpandString)
        $key.Close()
        $env:TRINITY_USER_ENV_KEY = $keyName
        $env:TRINITY_HOME = Join-Path $f.Root 'trinity-home'
        Invoke-InFolder $f.Root {
            Invoke-WithGitConfig $cfg {
                $add = Invoke-Installer $rel @('-AddToPath', '-Yes')
                Assert-True ($add.ExitCode -eq 0 -and $add.Output -match 'Added .* to User PATH') "-AddToPath exit $($add.ExitCode): $($add.Output)"
                $after = Get-RawPathValue $keyName
                Assert-True ($after.Text.StartsWith($seed + ';') -and $after.Text.EndsWith('\release copy\trinity-v0.0.0', [StringComparison]::OrdinalIgnoreCase)) "PATH after add: $($after.Text)"
                Assert-True ($after.Kind -eq 'ExpandString') "PATH kind after add: $($after.Kind)"
                $again = Invoke-Installer $rel @('-AddToPath', '-Yes')
                Assert-True ($again.ExitCode -eq 0 -and $again.Output -match 'already contains') "second -AddToPath: $($again.Output)"
                Assert-True ((Get-RawPathValue $keyName).Text -eq $after.Text) 'second -AddToPath changed the PATH'
                $remove = Invoke-Installer $rel @('-RemoveFromPath', '-Yes')
                Assert-True ($remove.ExitCode -eq 0 -and $remove.Output -match 'Removed ') "-RemoveFromPath exit $($remove.ExitCode): $($remove.Output)"
                $restored = Get-RawPathValue $keyName
                Assert-True ($restored.Text -eq $seed -and $restored.Kind -eq 'ExpandString') "PATH after remove: $($restored.Text) ($($restored.Kind))"
                Assert-True (Test-Path -LiteralPath (Join-Path $env:TRINITY_HOME 'user-path-backup.txt')) 'no PATH backup file'
            }
        }
    }
    finally {
        $env:TRINITY_USER_ENV_KEY = $savedKey
        $env:TRINITY_HOME = $savedHome
        try { [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($keyName, $false) } catch { }
    }
    Assert-True ([Environment]::GetEnvironmentVariable('Path', 'User') -eq $realBefore) 'the real User PATH changed'
}

Run-Case 'dispatch in a repo without commits or without the base branch says what to do' {
    param($f)
    $rel = New-ReleaseCopy $f
    $utf8 = New-Object Text.UTF8Encoding($false)
    $proj = Join-Path $f.Root 'empty project'
    New-Item -ItemType Directory -Path $proj -Force | Out-Null
    & git -C $proj init -b main 2>&1 | Out-Null
    Invoke-Git $proj @('config', 'user.name', 'Trinity Selftest') | Out-Null
    Invoke-Git $proj @('config', 'user.email', 'selftest@example.invalid') | Out-Null
    $prompt = Join-Path $f.Root 'empty-prompt.md'
    [IO.File]::WriteAllText($prompt, "Perform the fixture task.`r`n", $utf8)
    Invoke-InFolder $proj {
        $none = Invoke-Trinity $rel @('dispatch', 'codex', 'ec-task', '-Scope', 'src/*', '-PromptFile', $prompt)
        Assert-True ($none.ExitCode -ne 0 -and $none.Output -match 'no commits yet' -and $none.Output -match 'first commit') "dispatch without commits: $($none.Output)"
    }
    [IO.File]::WriteAllText((Join-Path $proj 'a.txt'), "a`r`n", $utf8)
    Invoke-Git $proj @('add', '-A') | Out-Null
    Invoke-Git $proj @('commit', '-m', 'first') | Out-Null
    Invoke-Git $proj @('branch', '-m', 'trunk') | Out-Null
    Invoke-InFolder $proj {
        $trunk = Invoke-Trinity $rel @('dispatch', 'codex', 'ec-task', '-Scope', 'src/*', '-PromptFile', $prompt)
        Assert-True ($trunk.ExitCode -ne 0 -and $trunk.Output -match "branch 'main' does not exist" -and $trunk.Output -match 'git branch -m main') "dispatch without main: $($trunk.Output)"
    }
    $board = Join-Path $proj '.git\agent-board.md'
    Assert-True ((-not (Test-Path $board)) -or ((Get-Content -Raw $board) -notmatch 'ec-task')) 'a refused dispatch left a board entry'
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
    $env:TRINITY_REVIEWER = 'claude'
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

Run-Case 'dashboard once adds health server and attention state' {
    param($f)
    $boardPath = Join-Path $f.Repo '.git\agent-board.md'
    $section = @('', '## attention-failed', '- agent: codex', '- branch: -', '- worktree: -', '- scope: tests/*', '- status: failed command 2026-10-25 10:01', '', '## attention-done', '- agent: antigravity', '- branch: -', '- worktree: -', '- scope: tests/*', '- status: done 2026-10-25 10:02', '', '## attention-merged', '- agent: claude', '- branch: -', '- worktree: -', '- scope: tests/*', '- status: merged 2026-10-25 10:03') -join "`r`n"
    [IO.File]::AppendAllText($boardPath, $section + "`r`n", [Text.UTF8Encoding]::new($false))
    $dashboard = Join-Path $f.Repo 'scripts\dashboard.ps1'; $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $json = & $powershell -NoProfile -ExecutionPolicy Bypass -File $dashboard -Once -Repos $f.Repo
    Assert-True ($LASTEXITCODE -eq 0) "dashboard exited $LASTEXITCODE"
    $state = ($json -join "`n") | ConvertFrom-Json
    Assert-True ($null -ne $state.server -and $state.server.listenerScope -eq 'loopback' -and $state.server.scriptHash -match '^[0-9a-f]{12}$' -and $state.server.scriptHashOnDisk -match '^[0-9a-f]{12}$' -and $state.server.collectMs -ge 0 -and $state.server.avgCollectMs -ge 0) 'server state has invalid shape'
    Assert-True (@($state.attention).Count -eq 2) "unexpected attention items: $(@($state.attention | ForEach-Object { $_.task + ':' + $_.reason }) -join ', ')"
    Assert-True (@($state.health).Count -ge 7) 'health rows are missing'
    $failed = @($state.attention | Where-Object task -eq 'attention-failed' | Select-Object -First 1)
    $done = @($state.attention | Where-Object task -eq 'attention-done' | Select-Object -First 1)
    Assert-True ($failed.Count -eq 1 -and $failed[0].reason -eq 'failed' -and $failed[0].repoPath -eq [IO.Path]::GetFullPath($f.Repo) -and $failed[0].agent -eq 'codex' -and $failed[0].since -match '^2026-10-25T10:01:00') 'failed attention item is invalid'
    Assert-True ($done.Count -eq 1 -and $done[0].reason -eq 'done-unmerged') 'done attention item is invalid'
    foreach ($item in @($state.attention)) { Assert-True ($item.detail -and $item.since -match '^\d{4}-\d\d-\d\dT') "attention item missing detail or ISO time: $($item.task)" }
    foreach ($row in @($state.health)) { Assert-True ($row.id -match '^[a-z0-9-]+$' -and $row.label -and $row.status -in @('ok','warn','fail') -and $row.detail) "invalid health row: $($row | ConvertTo-Json -Compress)" }
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
        # State is served from a shared snapshot refreshed every few seconds, so wait for the refresh to pick up the change.
        $updatedTitle = $null; $refreshDeadline = (Get-Date).AddSeconds(20)
        while ($updatedTitle -ne 'Updated title' -and (Get-Date) -lt $refreshDeadline) {
            $updatedState = (Invoke-WebRequest -Uri "http://localhost:$port/api/state" -UseBasicParsing -TimeoutSec 60).Content | ConvertFrom-Json
            $updatedRepo = @($updatedState.repos | Where-Object path -eq ([IO.Path]::GetFullPath($f.Repo)))[0]
            $updatedTitle = (@($updatedRepo.claudeSessions | Where-Object id -eq 'session-7')[0]).title
            if ($updatedTitle -ne 'Updated title') { Start-Sleep -Milliseconds 500 }
        }
        Assert-True ($updatedTitle -eq 'Updated title') 'changed Claude summary was not invalidated from cache'
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
        if(-not $first -and $process.HasExited){Skip-Case 'HttpListener is unsupported or blocked in this environment'}; Assert-True ([bool]$first) 'dashboard never answered /api/state'
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
        if(-not $response -and $process.HasExited){Skip-Case 'HttpListener is unsupported or blocked in this environment'}; Assert-True ([bool]$response) 'dashboard never answered /api/state'
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
        if(-not $response -and $process.HasExited){Skip-Case 'HttpListener is unsupported or blocked in this environment'}; Assert-True ([bool]$response) 'dashboard never answered /api/state'
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
        # Forged localhost Host from a non-loopback address: HTTP.sys routes it, the app's loopback check refuses it (403).
        $lanIp = [Net.Dns]::GetHostAddresses([Net.Dns]::GetHostName()) | Where-Object { $_.AddressFamily -eq 'InterNetwork' -and -not [Net.IPAddress]::IsLoopback($_) } | Select-Object -First 1
        if (-not $lanIp) { Skip-Case 'no non-loopback IPv4 address to test the loopback guard' }
        $client=New-Object Net.Sockets.TcpClient($lanIp.ToString(), $port); $hostLine=''
        try { $stream=$client.GetStream(); $bytes=[Text.Encoding]::ASCII.GetBytes("GET /api/state HTTP/1.1`r`nHost: localhost:$port`r`nConnection: close`r`n`r`n"); $stream.Write($bytes,0,$bytes.Length); $hostLine=(New-Object IO.StreamReader($stream)).ReadLine() }
        finally { $client.Close() }
        Assert-True ($hostLine -match '^HTTP/1\.[01] 403 ') "forged-Host request from a LAN address was not refused: $hostLine"
        $blockedState=$null; $blockedDeadline=(Get-Date).AddSeconds(8)
        while ((Get-Date) -lt $blockedDeadline) {
            try { $blockedResponse=Invoke-WebRequest -Uri "http://localhost:$port/api/state" -UseBasicParsing -TimeoutSec 2; $blockedState=$blockedResponse.Content | ConvertFrom-Json; if ($blockedState.server.blockedRemoteCount -ge 1) { break } } catch { }
            Start-Sleep -Milliseconds 150
        }
        Assert-True ($blockedState -and $blockedState.server.blockedRemoteCount -ge 1) 'blockedRemoteCount did not increment in /api/state after bad Host request'
    }
    finally { if ($process) { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue }; $env:CODEX_HOME=$oldCodexHome; $env:TRINITY_AGY_HOME=$oldAgyHome; $env:CLAUDE_CONFIG_DIR=$oldClaudeHome; $env:TRINITY_DISABLE=$oldDisable }
}

Run-Case 'dashboard task read endpoints diff log and merge checks' {
    param($f)
    $process=$null
    try {
        Invoke-Git $f.Repo @('checkout','-b','agent/codex/read-task') | Out-Null
        [IO.File]::WriteAllText((Join-Path $f.Repo 'added.txt'), "added line`n")
        [IO.File]::WriteAllText((Join-Path $f.Repo 'README.md'), "branch line`n")
        Invoke-Git $f.Repo @('add','-A') | Out-Null; Invoke-Git $f.Repo @('commit','-m','task changes') | Out-Null
        Invoke-Git $f.Repo @('checkout','main') | Out-Null
        $board=Join-Path $f.Repo '.git\agent-board.md'
        [IO.File]::WriteAllText($board, "## read-task`r`n- agent: codex`r`n- branch: agent/codex/read-task`r`n- scope: *`r`n- status: done`r`n`r`n## branchless`r`n- agent: claude`r`n- branch: -`r`n- status: done`r`n")
        New-Item -ItemType Directory -Path (Join-Path $f.Repo '.codex-out') -Force | Out-Null
        $log=Join-Path $f.Repo '.codex-out\log-read-task.txt'; [IO.File]::WriteAllText($log, "first`n"+[char]27+'[31m')
        # Exercise helpers even on hosts where HttpListener is unavailable.
        & {
            . (Join-Path $f.Repo 'scripts\dashboard.ps1') -LibraryOnly
            $task=[pscustomobject]@{ task='read-task'; branch='agent/codex/read-task'; scope='*'; state='done'; agent='codex' }
            $diff=Get-TaskDiff $f.Repo $task
            Assert-True ($diff.stat.files -eq 2 -and $diff.stat.added -eq 2 -and $diff.stat.deleted -eq 1 -and $diff.patch.Contains('+added line')) 'diff contents or totals incorrect'
            Assert-True (@($diff.files | Where-Object { $_.status -eq 'A' }).Count -eq 1) 'added file absent'
            $tail=Get-TaskLog $f.Repo $task -1
            Assert-True ($tail.text.Contains('\x1b') -and $tail.exists) 'log control was not escaped'
            [IO.File]::AppendAllText($log,'new text')
            $next=Get-TaskLog $f.Repo $task $tail.nextOffset
            Assert-True ($next.text -eq 'new text' -and $next.offset -eq $tail.nextOffset) 'log offsets lost continuity'
            $reset=Get-TaskLog $f.Repo $task 999999
            Assert-True $reset.reset 'rotated log did not reset'
            # Split both two- and three-byte characters at the 64 KiB read boundary.
            foreach ($code in @(0xE9,0x20AC)) {
                $character=[string][char]$code
                $prefix='a'*65535
                [IO.File]::WriteAllText($log,($prefix+$character+'z'),[Text.UTF8Encoding]::new($false))
                $first=Get-TaskLog $f.Repo $task 0
                $second=Get-TaskLog $f.Repo $task $first.nextOffset
                Assert-True ($first.text -eq $prefix -and $first.nextOffset -eq 65535 -and $second.text -eq ($character+'z') -and $second.nextOffset -eq $second.size) 'split UTF-8 log lost text or byte offsets'
                Assert-True (($first.text+$second.text).IndexOf([char]0xFFFD) -lt 0) 'split UTF-8 log contains a replacement character'
                $json=Convert-StateToJson $second
                Assert-True ($json -notmatch '[^\x00-\x7f]' -and ($json | ConvertFrom-Json).text -eq $second.text) 'split UTF-8 log JSON was not ASCII-safe or failed round trip'
                $inside=Get-TaskLog $f.Repo $task 65536
                Assert-True ($inside.text -eq 'z' -and $inside.nextOffset -eq $inside.size) 'leading UTF-8 continuation bytes were not skipped'
            }
            [IO.File]::WriteAllBytes($log,[byte[]]@(0xE2,0x82))
            $partial=Get-TaskLog $f.Repo $task 0
            Assert-True ($partial.text -eq '' -and $partial.nextOffset -eq 0) 'partial EOF character was consumed'
            $again=Get-TaskLog $f.Repo $task $partial.nextOffset
            Assert-True ($again.text -eq '' -and $again.nextOffset -eq 0) 'partial EOF poll did not remain bounded'
            [IO.File]::WriteAllBytes($log,[byte[]]@(0xE2,0x82,0xAC))
            $complete=Get-TaskLog $f.Repo $task $partial.nextOffset
            Assert-True ($complete.text -eq [string][char]0x20AC -and $complete.nextOffset -eq 3) 'completed EOF character was not reread'
            $secret='sk-' + ('FakeToken1234'*3)
            [IO.File]::WriteAllText($log,($secret+[char]27),[Text.UTF8Encoding]::new($false))
            $redacted=Get-TaskLog $f.Repo $task 0
            Assert-True ($redacted.text -eq '[redacted]\x1b' -and $redacted.nextOffset -eq (Get-Item -LiteralPath $log).Length) 'log secret was not redacted with raw byte offset'
            $check=Get-TaskMergeCheck $f.Repo $task
            Assert-True ($check.canMerge -and $check.ahead -eq 1) 'clean done branch cannot merge'
            $task.state='running'; [IO.File]::WriteAllText((Join-Path $f.Repo '.codex-out\pid-read-task.txt'),[string]$PID)
            $check=Get-TaskMergeCheck $f.Repo $task
            Assert-True (($check.blockers.id -contains 'runner-alive') -and ($check.blockers.id -contains 'not-done')) 'running task blockers absent'
            Remove-Item -LiteralPath (Join-Path $f.Repo '.codex-out\pid-read-task.txt'); $task.state='done'
            [IO.File]::WriteAllText((Join-Path $f.Repo 'dirty.txt'),'dirty')
            Assert-True ((Get-TaskMergeCheck $f.Repo $task).blockers.id -contains 'main-dirty') 'dirty main blocker absent'
            Remove-Item -LiteralPath (Join-Path $f.Repo 'dirty.txt')
            $task.scope='scripts/*'; $check=Get-TaskMergeCheck $f.Repo $task
            Assert-True (($check.blockers.id -contains 'scope-violation') -and ($check.scopeViolations -contains 'added.txt')) 'scope violation absent'
            [IO.File]::WriteAllText((Join-Path $f.Repo 'README.md'), "main line`n")
            Invoke-Git $f.Repo @('add','README.md') | Out-Null; Invoke-Git $f.Repo @('commit','-m','main conflict') | Out-Null
            $check=Get-TaskMergeCheck $f.Repo $task
            Assert-True (($check.blockers.id -contains 'conflicts') -and ($check.conflicts -contains 'README.md')) 'conflicted path absent'
        }
        $tcp=New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,0); $tcp.Start(); $port=$tcp.LocalEndpoint.Port; $tcp.Stop()
        $dashboard=Join-Path $f.Repo 'scripts\dashboard.ps1'
        $process=Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -WindowStyle Hidden -PassThru -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"{0}"' -f $dashboard),'-Port',[string]$port,'-Repos',('"{0}"' -f $f.Repo))
        $response=$null; $deadline=(Get-Date).AddSeconds(10)
        while (-not $response -and (Get-Date) -lt $deadline -and -not $process.HasExited) { try { $response=Invoke-WebRequest "http://localhost:$port/api/state" -UseBasicParsing -TimeoutSec 2 } catch { Start-Sleep -Milliseconds 100 } }
        if (-not $response -and $process.HasExited) { Skip-Case 'HttpListener is unsupported or blocked in this environment (task helpers passed)' }
        Assert-True ([bool]$response) 'dashboard never answered state'
        $query='repo='+[uri]::EscapeDataString($f.Repo)+'&task=read-task'
        foreach ($route in 'diff','log','merge-check') {
            $reply=Invoke-WebRequest "http://localhost:$port/api/task/$($route)?$query" -UseBasicParsing -TimeoutSec 10
            Assert-True ($reply.StatusCode -eq 200) "task $route failed"
        }
        $secret='sk-' + ('FakeToken1234'*3)
        [IO.File]::WriteAllText($log,($secret+[char]0xE9+[char]0x20AC),[Text.UTF8Encoding]::new($false))
        $reply=Invoke-WebRequest "http://localhost:$port/api/task/log?$query&offset=0" -UseBasicParsing -TimeoutSec 10
        $body=$reply.Content | ConvertFrom-Json
        Assert-True ($body.text -eq ('[redacted]'+[char]0xE9+[char]0x20AC) -and $body.nextOffset -eq (Get-Item -LiteralPath $log).Length) 'HTTP log redaction or raw offset incorrect'
        Assert-True ($reply.Content -notmatch '[^\x00-\x7f]' -and -not $reply.Content.Contains($secret)) 'HTTP log JSON was not ASCII-safe or leaked secret'
        foreach ($pair in @(@('repo=unknown&task=read-task',404),@('repo=unknown&task=../bad',400),@(('repo='+[uri]::EscapeDataString($f.Repo)+'&task=branchless'),409),@(('repo='+[uri]::EscapeDataString($f.Repo)+'&task=missing'),404))) {
            $status=0; try { Invoke-WebRequest "http://localhost:$port/api/task/diff?$($pair[0])" -UseBasicParsing -TimeoutSec 5 | Out-Null } catch { if ($_.Exception.Response) { $status=[int]$_.Exception.Response.StatusCode } }
            Assert-True ($status -eq $pair[1]) "task validation returned $status instead of $($pair[1])"
        }
    } finally { if ($process) { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue } }
}
Run-Case 'dashboard dispatch validation is read-only and checks conflicts' {
    param($f)
    & {
        . (Join-Path $f.Repo 'scripts\dashboard.ps1') -LibraryOnly
        $repo=[pscustomobject]@{ path=$f.Repo; tasks=@([pscustomobject]@{task='busy';agent='codex';state='running';scope='src/*'},[pscustomobject]@{task='old';agent='claude';state='merged';scope=''}) }
        $avail=[pscustomobject]@{codex=@{available=$false};antigravity=@{available=$true}}
        $check=Get-DispatchCheck $repo $avail 'codex' 'new-task' ' src/lib/*, tests/* '
        Assert-True ($check.canDispatch -and $check.rerouted -and $check.effectiveAgent -eq 'antigravity' -and $check.scopeNormalized.Count -eq 2 -and $check.overlaps[0].task -eq 'busy') 'valid check/reroute/overlap failed'
        foreach ($name in @('../bad','UPPER',('x'*41),'busy','old')) { Assert-True (-not (Get-DispatchCheck $repo $avail 'claude' $name '').taskOk) "accepted task $name" }
        foreach ($scope in @('../src/*','/src/*','C:/src/*','src\*','src/*,',('a,'*20+'b'),"src/`n*","`nfoo")) { Assert-True (-not (Get-DispatchCheck $repo $avail 'claude' 'new-task' $scope).scopeOk) "accepted scope $scope" }
        $empty=Get-DispatchCheck $repo $avail 'claude' 'new-task' ''
        Assert-True ($empty.canDispatch -and $empty.scopeReason -eq 'no scope: overlap not checked' -and $empty.agentReason -match 'Park') 'empty scope/Claude park failed'
        Invoke-Git $f.Repo @('branch','agent/claude/branch-only') | Out-Null
        Assert-True (-not (Get-DispatchCheck $repo $avail 'claude' 'branch-only' '').taskOk) 'existing branch accepted'
        New-Item -ItemType Directory -Path (Join-Path $f.Worktrees 'codex-leftover') -Force | Out-Null
        Assert-True (-not (Get-DispatchCheck $repo $avail 'claude' 'leftover' '').taskOk) 'leftover worktree accepted'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $f.Repo '.codex-out'))) 'validation wrote to disk'
    }
}
Run-Case 'dashboard dispatch process uses a fake worker and a prompt file' {
    param($f)
    & {
        . (Join-Path $f.Repo 'scripts\dashboard.ps1') -LibraryOnly
        $script:Jobs=@{}
        $workerProcess=$null
        $prompt="-Force`r`n"+[char]0xE9+[char]0x20AC+"`n"
        $out=Join-Path $f.Repo '.codex-out'; [void][IO.Directory]::CreateDirectory($out)
        $file=Join-Path $out 'prompt-direct-api.md'; [IO.File]::WriteAllText($file,$prompt,[Text.UTF8Encoding]::new($false))
        try {
            Start-ActionProcess '123456abcdef' 'dispatch' 'direct-api' $f.Repo '' 'trinity dispatch codex direct-api -PromptFile <file>' 'codex' '' $file
            $deadline=(Get-Date).AddSeconds(15)
            do { Update-ActionJobs; if ($script:Jobs['123456abcdef'].state -ne 'running') { break }; Start-Sleep -Milliseconds 100 } while ((Get-Date) -lt $deadline)
            $job=$script:Jobs['123456abcdef']
            Assert-True ($job.state -eq 'done' -and $job.exitCode -eq 0) "dispatch child failed: $(Read-JobOutput $job)"
            $pidFile=Join-Path $out 'pid-direct-api.txt'
            if (Test-Path -LiteralPath $pidFile) { $workerProcess=Get-Process -Id ([int][IO.File]::ReadAllText($pidFile).Trim()) -ErrorAction SilentlyContinue }
            $wait=Invoke-Trinity $f @('wait','direct-api','-Timeout','15')
            Assert-True ($wait.ExitCode -eq 0) "fake worker did not finish: $($wait.Output)"
            Assert-True ((Invoke-Git $f.Repo @('show','agent/codex/direct-api:fake-output.txt')) -eq 'fake codex output') 'fake agent did not commit output'
            Assert-True ([Convert]::ToBase64String([IO.File]::ReadAllBytes($file)) -ceq [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($prompt))) 'prompt changed'
        }
        finally {
            foreach ($job in @($script:Jobs.Values)) { if ($job.process -and -not $job.process.HasExited) { Stop-Process -Id $job.process.Id -Force -ErrorAction SilentlyContinue } }
            if ($workerProcess) { if (-not $workerProcess.HasExited) { $workerProcess.Kill(); [void]$workerProcess.WaitForExit(2000) }; $workerProcess.Dispose() }
        }
    }
}
Run-Case 'dashboard action API validates requests and runs a review job' {
    param($f)
    $process = $null; $dispatchWorker=$null
    try {
        Start-CodexTask $f 'api-task'
        $wait = Invoke-Trinity $f @('wait', 'api-task', '-Timeout', '50')
        Assert-True ($wait.ExitCode -eq 0) "fixture task did not finish: $($wait.Output)"
        $track=Invoke-Trinity $f @('track','busy-api','test overlap','-Scope','tests/*')
        Assert-True ($track.ExitCode -eq 0) 'could not track overlap fixture'
        $env:TRINITY_DISABLE='antigravity'
        [IO.File]::WriteAllText((Join-Path $f.Repo 'scripts\dashboard.html'), '<meta name="trinity-token" content="__TRINITY_TOKEN__">', [Text.UTF8Encoding]::new($false))
        $tcp = New-Object System.Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0); $tcp.Start(); $port=$tcp.LocalEndpoint.Port; $tcp.Stop()
        $dashboard = Join-Path $f.Repo 'scripts\dashboard.ps1'
        $process = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -WindowStyle Hidden -PassThru -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"{0}"' -f $dashboard),'-Port',[string]$port,'-Repos',('"{0}"' -f $f.Repo))
        $deadline=(Get-Date).AddSeconds(15); $page=$null
        while (-not $page -and (Get-Date) -lt $deadline -and -not $process.HasExited) { try { $page=Invoke-WebRequest -Uri "http://localhost:$port/" -UseBasicParsing -TimeoutSec 2 } catch { Start-Sleep -Milliseconds 100 } }
        if (-not $page -and $process.HasExited) { Skip-Case 'HttpListener is unsupported or blocked in this environment' }
        Assert-True ([bool]$page) 'dashboard did not serve its page'
        $tokenMatch=[regex]::Match($page.Content,'name="trinity-token" content="([0-9a-f]{64})"')
        Assert-True $tokenMatch.Success 'dashboard page did not receive the server token'
        $token=$tokenMatch.Groups[1].Value
        $send = {
            param($Url,$Method,$Body,$Token,$Origin,$ContentType)
            $request=[Net.HttpWebRequest]::Create($Url); $request.Method=$Method; $request.Timeout=15000
            if ($Token) { $request.Headers.Add('X-Trinity-Token',$Token) }
            if ($Origin) { $request.Headers.Add('Origin',$Origin) }
            if ($null -ne $Body) { $bytes=[Text.Encoding]::UTF8.GetBytes($Body); $request.ContentType=$ContentType; $request.ContentLength=$bytes.Length; $stream=$request.GetRequestStream(); $stream.Write($bytes,0,$bytes.Length); $stream.Dispose() }
            try { $response=$request.GetResponse(); $reader=New-Object IO.StreamReader($response.GetResponseStream()); $result=[pscustomobject]@{ Status=[int]$response.StatusCode; Content=$reader.ReadToEnd() }; $reader.Dispose(); $response.Dispose(); return $result }
            catch [Net.WebException] { if (-not $_.Exception.Response) { throw }; $response=$_.Exception.Response; $reader=New-Object IO.StreamReader($response.GetResponseStream()); $result=[pscustomobject]@{ Status=[int]$response.StatusCode; Content=$reader.ReadToEnd() }; $reader.Dispose(); $response.Dispose(); return $result }
        }
        $base="http://localhost:$port"
        $origin="http://localhost:$port"
        $payload=@{ action='review-task'; repo=$f.Repo; task='api-task'; confirm=$false } | ConvertTo-Json -Compress
        Assert-True ((& $send "$base/api/action" 'POST' $payload '' $origin 'application/json').Status -eq 401) 'missing token was not refused'
        Assert-True ((& $send "$base/api/action" 'POST' $payload $token 'http://evil.invalid' 'application/json').Status -eq 403) 'wrong Origin was not refused'
        Assert-True ((& $send "$base/api/action" 'POST' '{"action":"bogus","repo":"x","task":"api-task","confirm":false}' $token $origin 'application/json').Status -eq 400) 'unknown action was not rejected'
        Assert-True ((& $send "$base/api/action" 'POST' '{"action":"review-task","repo":"x","task":"../bad","confirm":false}' $token $origin 'application/json').Status -eq 400) 'bad task name was not rejected'
        Assert-True ((& $send "$base/api/action" 'POST' '{"action":"review-task","repo":"not-a-repo","task":"api-task","confirm":false}' $token $origin 'application/json').Status -eq 404) 'unknown repo was not rejected'
        Assert-True ((& $send "$base/api/action" 'POST' (@{action='cancel';repo=$f.Repo;task='api-task';confirm=$false}|ConvertTo-Json -Compress) $token $origin 'application/json').Status -eq 412) 'cancel without confirm did not return 412'
        Assert-True ((& $send "$base/api/action" 'POST' (@{action='merge';repo=$f.Repo;task='api-task';confirm=$false}|ConvertTo-Json -Compress) $token $origin 'application/json').Status -eq 412) 'merge without confirm did not return 412'
        Assert-True ((& $send "$base/api/action" 'POST' $payload $token $origin 'text/plain').Status -eq 415) 'wrong content type was not rejected'
        Assert-True ((& $send "$base/api/action" 'POST' ('x' * 9000) $token $origin 'application/json').Status -eq 413) 'oversized body was not rejected'
        $badJob=& $send "$base/api/job?id=bad" 'GET' $null '' '' ''
        Assert-True ($badJob.Status -eq 400) 'invalid job id was not rejected'
        $stateReply=& $send "$base/api/state" 'GET' $null '' '' ''
        Assert-True (($stateReply.Content | ConvertFrom-Json).server.actionsEnabled -eq $true) 'state did not enable actions'
        $accepted=& $send "$base/api/action" 'POST' $payload $token $origin 'application/json'
        Assert-True ($accepted.Status -eq 202) "review action was not accepted: $($accepted.Content)"
        $jobId=($accepted.Content | ConvertFrom-Json).job
        $job=$null; $jobDeadline=(Get-Date).AddSeconds(20)
        while ((Get-Date) -lt $jobDeadline) { $jobReply=& $send "$base/api/job?id=$jobId" 'GET' $null '' '' ''; $job=$jobReply.Content | ConvertFrom-Json; if ($job.state -ne 'running') { break }; Start-Sleep -Milliseconds 150 }
        Assert-True ($job -and $job.state -eq 'done' -and $job.exitCode -eq 0) "review job did not finish successfully: $($job | ConvertTo-Json -Compress)"
        $query='repo='+[uri]::EscapeDataString($f.Repo)+'&agent=codex&task=dispatch-api&scope=tests/*'
        $checkReply=& $send "$base/api/dispatch/check?$query" 'GET' $null '' '' ''
        Assert-True ($checkReply.Status -eq 200 -and ($checkReply.Content | ConvertFrom-Json).canDispatch) 'HTTP dispatch check rejected a valid task'
        Assert-True (($checkReply.Content | ConvertFrom-Json).overlaps.task -contains 'busy-api') 'HTTP overlap warning absent'
        $reroute=& $send ("$base/api/dispatch/check?"+($query -replace 'agent=codex','agent=antigravity')) 'GET' $null '' '' ''
        $rerouteBody=$reroute.Content | ConvertFrom-Json
        Assert-True ($rerouteBody.canDispatch -and $rerouteBody.rerouted -and $rerouteBody.effectiveAgent -eq 'codex') 'HTTP availability reroute failed'
        foreach ($invalid in @('task=api-task&scope=','task=new&scope=../bad','task=new&scope=/absolute')) {
            $reply=& $send ("$base/api/dispatch/check?repo="+[uri]::EscapeDataString($f.Repo)+'&agent=codex&'+$invalid) 'GET' $null '' '' ''
            Assert-True ($reply.Status -eq 200 -and -not ($reply.Content | ConvertFrom-Json).canDispatch) 'HTTP duplicate task or invalid scope accepted'
        }
        foreach ($pair in @(@('repo=unknown&agent=codex&task=new',404),@(('repo='+[uri]::EscapeDataString($f.Repo)+'&agent=codex&task=../bad'),200))) {
            $reply=& $send "$base/api/dispatch/check?$($pair[0])" 'GET' $null '' '' ''
            Assert-True ($reply.Status -eq $pair[1]) 'dispatch check status incorrect'
            if ($reply.Status -eq 200) { Assert-True (-not ($reply.Content | ConvertFrom-Json).taskOk) 'HTTP bad name accepted' }
        }
        $prompt="-Force`r`n"+[char]0xE9+[char]0x20AC+"`n"+('dispatch prompt '*700)
        $dispatch=@{action='dispatch';repo=$f.Repo;task='dispatch-api';agent='codex';scope='tests/*';prompt=$prompt;confirm=$true}
        $dispatchJson=$dispatch | ConvertTo-Json -Compress
        Assert-True ((& $send "$base/api/action" 'POST' $dispatchJson '' $origin 'application/json').Status -eq 401) 'dispatch missing token accepted'
        Assert-True ((& $send "$base/api/action" 'POST' $dispatchJson $token 'http://evil.invalid' 'application/json').Status -eq 403) 'dispatch bad Origin accepted'
        $dispatch.confirm=$false
        Assert-True ((& $send "$base/api/action" 'POST' ($dispatch|ConvertTo-Json -Compress) $token $origin 'application/json').Status -eq 400) 'dispatch missing confirmation accepted'
        $dispatch.confirm=$true; $dispatch.task='../bad'
        Assert-True ((& $send "$base/api/action" 'POST' ($dispatch|ConvertTo-Json -Compress) $token $origin 'application/json').Status -eq 400) 'dispatch invalid task accepted'
        $accepted=& $send "$base/api/action" 'POST' $dispatchJson $token $origin 'application/json'
        Assert-True ($accepted.Status -eq 202) "dispatch not accepted: $($accepted.Content)"
        $dispatchJob=($accepted.Content | ConvertFrom-Json).job
        $actual=[IO.File]::ReadAllBytes((Join-Path $f.Repo '.codex-out\prompt-dispatch-api.md'))
        Assert-True ([Convert]::ToBase64String($actual) -ceq [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($prompt))) 'prompt bytes changed or BOM added'
        $deadline=(Get-Date).AddSeconds(15); $job=$null
        while ((Get-Date) -lt $deadline) {
            $reply=& $send "$base/api/job?id=$dispatchJob" 'GET' $null '' '' ''; $job=$reply.Content | ConvertFrom-Json
            if ($job.state -ne 'running') { break }; Start-Sleep -Milliseconds 100
        }
        Assert-True ($job.state -eq 'done' -and $job.exitCode -eq 0) "dispatch job failed: $($job.output)"
        $pidFile=Join-Path $f.Repo '.codex-out\pid-dispatch-api.txt'
        if (Test-Path -LiteralPath $pidFile) { $dispatchWorker=Get-Process -Id ([int][IO.File]::ReadAllText($pidFile).Trim()) -ErrorAction SilentlyContinue }
        $wait=Invoke-Trinity $f @('wait','dispatch-api','-Timeout','15')
        Assert-True ($wait.ExitCode -eq 0) "fake dispatch worker failed: $($wait.Output)"
        Assert-True (-not $job.command.Contains($prompt)) 'prompt appeared in command'
        $again=& $send "$base/api/action" 'POST' $dispatchJson $token $origin 'application/json'
        Assert-True ($again.Status -eq 400) 'existing prompt/task was overwritten'
        $actionLog=Join-Path $env:TRINITY_HOME 'actions.log'
        Assert-True (Test-Path -LiteralPath $actionLog) 'actions.log was not created'
        $logText=[IO.File]::ReadAllText($actionLog)
        Assert-True ($logText -match [regex]::Escape($jobId) -and $logText -match 'exitCode=0') 'actions.log omitted job or exit code'
        Assert-True (-not $logText.Contains($token)) 'actions.log contains the server token'
        Assert-True (-not $logText.Contains('dispatch prompt') -and $logText -match 'action=dispatch.*agent=codex') 'dispatch log leaked prompt or omitted agent'
    }
    finally {
        if ($dispatchWorker) { if (-not $dispatchWorker.HasExited) { $dispatchWorker.Kill(); [void]$dispatchWorker.WaitForExit(2000) }; $dispatchWorker.Dispose() }
        if ($process) { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue }
    }
}

Write-Output "$passed passed, $failed failed, $skipped skipped"
if (-not $Keep) {
    foreach ($root in @($fixtures)) {
        Remove-Fixture ([pscustomobject]@{ Root = $root; Repo = (Join-Path $root 'repo with spaces') })
    }
}
if ($failed -gt 0) { exit 1 }
exit 0
