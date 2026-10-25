# Trinity: one entry point for the Claude + Codex + Antigravity shared workspace.
# Run "trinity help" for the command list.
param(
    [Parameter(Position = 0)][string]$Command = 'status',
    [string]$Scope = 'unspecified',
    [string]$Base = 'main',
    [switch]$Yes,
    [switch]$Force,
    [switch]$Brief,
    [string]$PromptFile,
    [int]$Timeout = 1800,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest
)

. (Join-Path $PSScriptRoot 'lib\board.ps1')
$paths = Get-RepoPaths $PSScriptRoot
if (-not (Test-Path $paths.Out)) { New-Item -ItemType Directory -Path $paths.Out | Out-Null }

function Show-Usage {
    Write-Host 'trinity <command> [options]'
    Write-Host ''
    Write-Host '  status [-Brief]                       branch, worktrees, board, HANDOFF status'
    Write-Host '  review [codex review args]            Codex reviews uncommitted changes (read-only)'
    Write-Host '                                          trinity review --base main'
    Write-Host '  ask <prompt...>                       one-shot read-only question to Codex'
    Write-Host '                                          trinity ask "why does the login test fail?"'
    Write-Host '  dispatch <agent> <task> <prompt...>   worktree + task file + start the agent'
    Write-Host '                                          trinity dispatch codex login-form -Scope "src/auth/*" Build the login form'
    Write-Host '                                          (agent: codex | antigravity | claude)'
    Write-Host '  run <agent> <task> <prompt...>        dispatch, then wait and print result + commits'
    Write-Host '                                          trinity run codex login-form -Timeout 900 Build the login form'
    Write-Host '  wait <task> [-Timeout 1800]           block until done; exit 0 done, 1 failed, 2 timeout, 3 other'
    Write-Host '                                          trinity wait login-form -Timeout 600'
    Write-Host '  done <task> [summary...]              agent marks its own task done on the board'
    Write-Host '                                          trinity done login-form added the login form'
    Write-Host '  (dispatch/run) -PromptFile <file>     read the prompt from a file instead of <prompt...>'
    Write-Host '                                          trinity dispatch codex login-form -PromptFile prompt.txt'
    Write-Host '  merge <task> [-Yes] [-Force]          review, merge --no-ff, run tests, clean up'
    Write-Host '                                          trinity merge login-form'
    Write-Host '  ui                                    open the main checkout in Antigravity'
    Write-Host '  setup                                 enable .githooks and create .codex-out'
    Write-Host '  help                                  this text'
}

# Native stderr noise must not throw, so every git call here ignores stderr via cmd-free capture.
function Get-Git([string[]]$GitArgs) {
    $out = & git @GitArgs 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    $out
}

function Show-Status {
    $branch = Get-Git @('-C', $paths.Main, 'branch', '--show-current')
    $dirty = @(Get-Git @('-C', $paths.Main, 'status', '--porcelain') | Where-Object { $_ }).Count
    Write-Host "main checkout: branch=$branch uncommitted=$dirty"
    Write-Host ''
    Write-Host 'Worktrees:'
    Get-Git @('-C', $paths.Main, 'worktree', 'list') | ForEach-Object { Write-Host "  $_" }

    Write-Host ''
    Write-Host 'Board:'
    if (Test-Path $paths.Board) {
        $lines = [IO.File]::ReadAllLines($paths.Board)
        if ($Brief) {
            # Brief view skips merged tasks so session-start context stays small.
            $section = $null
            foreach ($l in $lines) {
                if ($l -match '^## ') { $section = $l }
                elseif ($l -match '^- status:' -and $l -notmatch '^- status: merged') { Write-Host "  $section  ($($l.Substring(2)))" }
            }
        }
        else {
            $lines | Where-Object { $_ -notmatch '^# ' -and $_.Trim() } | ForEach-Object { Write-Host "  $_" }
        }
    }
    else { Write-Host '  (no board yet)' }

    # HANDOFF.md "## Status" section, up to the next "## ".
    $handoff = Join-Path $paths.Main 'HANDOFF.md'
    if (Test-Path $handoff) {
        Write-Host ''
        Write-Host 'HANDOFF status:'
        $in = $false
        foreach ($l in [IO.File]::ReadAllLines($handoff)) {
            if ($l -match '^## ') { $in = ($l -match '^## Status'); continue }
            if ($in -and $l.Trim()) { Write-Host "  $l" }
        }
    }
}

# Poll the board until the task leaves started/running/waiting, then print status, result and commits.
# Returns 0 done, 1 failed, 2 timeout (still pending), 3 anything else (e.g. merged).
function Wait-Task([string]$task, [int]$timeoutSec) {
    $entry = Get-BoardEntry $paths $task
    if (-not $entry) { Fail "no board entry for $task" }
    $start = Get-Date
    $lastNote = $start
    while ($true) {
        $entry = Get-BoardEntry $paths $task
        $status = $entry.status
        # Codex tasks finish only when the runner writes its own status (after committing), never on a bare "done".
        $runnerDone = ($entry.agent -ne 'codex') -or ($status -match '^(done \(|done, no commits|failed|merged)')
        if ($runnerDone -and $status -notmatch '^(started|running|waiting)') { break }
        if (((Get-Date) - $start).TotalSeconds -ge $timeoutSec) { break }
        if (((Get-Date) - $lastNote).TotalSeconds -ge 60) {
            Write-Host "waiting on $($task): $status"
            $lastNote = Get-Date
        }
        Start-Sleep -Seconds 5
    }
    $pending = -not $runnerDone -or ($status -match '^(started|running|waiting)')
    if ($pending) { Write-Host "timeout after $($timeoutSec)s, still: $status" }
    Write-Host "status: $status"
    $result = Join-Path $paths.Out "result-$task.md"
    if (Test-Path $result) {
        Write-Host '--- result ---'
        Write-Host ([IO.File]::ReadAllText($result))
    }
    $branch = $entry.branch
    if ($branch -and (Get-Git @('-C', $paths.Main, 'rev-parse', '--verify', '--quiet', "refs/heads/$branch"))) {
        Write-Host '--- commits ---'
        Get-Git @('-C', $paths.Main, 'log', '--oneline', "main..$branch") | ForEach-Object { Write-Host $_ }
        Write-Host '--- diffstat ---'
        Get-Git @('-C', $paths.Main, 'diff', '--stat', "main...$branch") | ForEach-Object { Write-Host $_ }
    }
    if ($pending) { return 2 }
    if ($status -match '^done') { return 0 }
    if ($status -match '^failed') { return 1 }
    3
}

# Create worktree + task file for one agent and start it (codex/antigravity) or park it (claude).
function Start-Dispatch([string]$agent, [string]$task, [string]$prompt) {
    $wt = New-AgentWorktree $paths $agent $task $Scope $Base

    $taskFile = Join-Path $paths.Out "task-$task.md"
    $resultPath = Join-Path $paths.Out "result-$task.md"
    $body = @(
        "# Task: $task",
        '',
        "- agent: $agent",
        "- task: $task",
        "- branch: $($wt.Branch)",
        "- worktree: $($wt.Path)",
        "- scope: $Scope",
        '',
        '## Request',
        '',
        $prompt,
        '',
        '## Rules',
        '',
        '- Read AGENTS.md first.',
        '- Edit only files within the scope.',
        $(if ($agent -eq 'codex') { '- Do not run git commit; your sandbox cannot write .git. The runner commits your changes when you finish, using your final summary as the message.' }
          else { '- Commit your work on this branch with clear messages (no Co-Authored-By trailers).',
             "- When finished: write your summary to $resultPath, then run in your worktree: trinity done $task <one-line summary>" }),
        '- Do not push.',
        '- Do not edit HANDOFF.md or PLAN.md.',
        '- Finish with a short summary of what you did and anything left.'
    ) -join "`r`n"
    [IO.File]::WriteAllText($taskFile, $body + "`r`n", $script:Utf8)

    Write-Host "Worktree: $($wt.Path)"
    Write-Host "Branch:   $($wt.Branch)"
    Write-Host "Task:     $taskFile"
    switch ($agent) {
        'codex' {
            Set-BoardStatus $paths $task 'running'
            Start-Process powershell.exe -WindowStyle Hidden -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", '_run-codex', $task
            Write-Host "Codex started in background."
            Write-Host "Log:    $(Join-Path $paths.Out "log-$task.txt")"
            Write-Host "Result: $(Join-Path $paths.Out "result-$task.md")"
            Write-Host 'Check progress with: trinity status'
        }
        'antigravity' {
            Set-BoardStatus $paths $task 'running (antigravity)'
            Start-Process -FilePath 'cmd.exe' -WorkingDirectory $wt.Path -ArgumentList '/c', 'antigravity-ide', 'chat', '-m', 'agent', '-a', "`"$taskFile`"", '"Read the attached task file and do it."' -WindowStyle Hidden
            Write-Host 'Antigravity started. Check progress with: trinity status'
        }
        'claude' {
            Set-BoardStatus $paths $task 'waiting for claude session'
            Write-Host "Open a new Claude Code session on $($wt.Path) and say: do the task in $taskFile"
        }
    }
}

switch ($Command) {
    'status' { Show-Status }

    'review' {
        $exe = Resolve-CodexExe
        $reviewArgs = @($Rest | Where-Object { $_ })
        if ($reviewArgs.Count -eq 0) { $reviewArgs = @('--uncommitted') }
        Push-Location $paths.Root
        $null | & $exe review -c sandbox_mode=read-only @reviewArgs
        $rc = $LASTEXITCODE
        Pop-Location
        exit $rc
    }

    'ask' {
        if (-not $Rest) { Fail 'usage: trinity ask <prompt...>' }
        $exe = Resolve-CodexExe
        $prompt = $Rest -join ' '
        $null | & $exe exec --sandbox read-only --ephemeral --skip-git-repo-check -C $paths.Root -o (Join-Path $paths.Out 'codex-last.md') $prompt
        exit $LASTEXITCODE
    }

    'dispatch' {
        if ($PromptFile) {
            if (@($Rest).Count -lt 2) { Fail 'usage: trinity dispatch <codex|antigravity|claude> <task> -PromptFile <file>' }
            if (-not (Test-Path $PromptFile)) { Fail "prompt file not found: $PromptFile" }
            $prompt = [IO.File]::ReadAllText($PromptFile)
        }
        else {
            if (@($Rest).Count -lt 3) { Fail 'usage: trinity dispatch <codex|antigravity|claude> <task> <prompt...> (or -PromptFile <file>)' }
            $prompt = ($Rest[2..($Rest.Count - 1)]) -join ' '
        }
        Start-Dispatch $Rest[0] $Rest[1] $prompt
    }

    'run' {
        if ($PromptFile) {
            if (@($Rest).Count -lt 2) { Fail 'usage: trinity run <codex|antigravity|claude> <task> -PromptFile <file>' }
            if (-not (Test-Path $PromptFile)) { Fail "prompt file not found: $PromptFile" }
            $prompt = [IO.File]::ReadAllText($PromptFile)
        }
        else {
            if (@($Rest).Count -lt 3) { Fail 'usage: trinity run <codex|antigravity|claude> <task> <prompt...> (or -PromptFile <file>)' }
            $prompt = ($Rest[2..($Rest.Count - 1)]) -join ' '
        }
        Start-Dispatch $Rest[0] $Rest[1] $prompt
        if ($Rest[0] -eq 'claude') {
            Write-Host 'claude tasks need a Claude Code session; not waiting.'
            exit 0
        }
        exit (Wait-Task $Rest[1] $Timeout)
    }

    'wait' {
        $task = $Rest[0]
        if (-not $task) { Fail 'usage: trinity wait <task> [-Timeout 1800]' }
        exit (Wait-Task $task $Timeout)
    }

    'done' {
        $task = $Rest[0]
        if (-not $task) { Fail 'usage: trinity done <task> [summary...]' }
        if (-not (Get-BoardEntry $paths $task)) { Fail "no board entry for $task" }
        $summary = ''
        if (@($Rest).Count -gt 1) { $summary = (($Rest[1..($Rest.Count - 1)]) -join ' ') -replace '[\r\n]+', ' ' }
        $status = if ($summary.Trim()) { "done: $($summary.Trim())" } else { 'done' }
        Set-BoardStatus $paths $task $status
        Write-Host "status: $status"
    }

    '_run-codex' {
        $task = $Rest[0]
        $entry = Get-BoardEntry $paths $task
        if (-not $entry) { Fail "no board entry for $task" }
        $exe = Resolve-CodexExe
        $taskFile = Join-Path $paths.Out "task-$task.md"
        $log = Join-Path $paths.Out "log-$task.txt"
        $result = Join-Path $paths.Out "result-$task.md"

        # Run through a generated .cmd file: PS 5.1 mangles embedded quotes passed to cmd /c,
        # and cmd gives stdin/stdout redirection that works with spaces in paths.
        $runFile = Join-Path $paths.Out "run-$task.cmd"
        $cmdLine = '"' + $exe + '" exec --sandbox workspace-write --add-dir "' + $paths.Common + '" --skip-git-repo-check -C "' + $entry.worktree + '" -o "' + $result + '" - < "' + $taskFile + '" > "' + $log + '" 2>&1'
        [IO.File]::WriteAllText($runFile, "@echo off`r`n$cmdLine`r`nexit /b %ERRORLEVEL%`r`n", $script:Utf8)
        & $runFile
        $rc = $LASTEXITCODE

        # Codex's sandbox keeps .git read-only, so commit its changes here; its final summary is the message.
        if ($rc -eq 0 -and (Get-Git @('-C', $entry.worktree, 'status', '--porcelain'))) {
            $summary = @(Get-Content $result -ErrorAction SilentlyContinue | Where-Object { $_.Trim() })
            $subject = "$($task): " + $(if ($summary) { ($summary[0] -replace '\[([^\]]*)\]\([^)]*\)', '$1' -replace '[\[\]`*]', '') } else { 'Codex changes' })
            if ($subject.Length -gt 72) { $subject = $subject.Substring(0, 69) + '...' }
            $msgFile = Join-Path $paths.Out "commitmsg-$task.txt"
            [IO.File]::WriteAllText($msgFile, $subject + "`r`n`r`n" + ($summary -join "`r`n") + "`r`n", $script:Utf8)
            git -C $entry.worktree add -A
            git -C $entry.worktree commit -q -F $msgFile
            if ($LASTEXITCODE -ne 0) { $rc = 2 }
        }

        $n = [int](Get-Git @('-C', $paths.Main, 'rev-list', '--count', "main..$($entry.branch)"))
        if ($rc -eq 0 -and $n -gt 0) { $status = "done ($n commits)" }
        elseif ($rc -eq 0) { $status = 'done, no commits' }
        else { $status = "failed (exit $rc)" }
        Set-BoardStatus $paths $task $status

        try {
            Add-Type -AssemblyName System.Windows.Forms
            Add-Type -AssemblyName System.Drawing
            $ni = New-Object System.Windows.Forms.NotifyIcon
            $ni.Icon = [System.Drawing.SystemIcons]::Information
            $ni.Visible = $true
            $ni.BalloonTipTitle = "Trinity: $task"
            $ni.BalloonTipText = $status
            $ni.ShowBalloonTip(8000)
            Start-Sleep 9
            $ni.Dispose()
        }
        catch { }
    }

    'merge' {
        $task = $Rest[0]
        if (-not $task) { Fail 'usage: trinity merge <task>' }
        $entry = Get-BoardEntry $paths $task
        if (-not $entry) { Fail "no board entry for $task" }
        $branch = $entry.branch
        $exe = Resolve-CodexExe

        $cur = Get-Git @('-C', $paths.Main, 'branch', '--show-current')
        if ($cur -ne 'main') { Fail "main checkout is on '$cur', switch it to main first" }
        $dirty = @(Get-Git @('-C', $paths.Main, 'status', '--porcelain') | Where-Object { $_ })
        if ($dirty.Count -gt 0) { Fail 'main checkout has uncommitted changes; commit or stash them first' }
        $n = [int](Get-Git @('-C', $paths.Main, 'rev-list', '--count', "main..$branch"))
        if ($n -eq 0) { Fail "nothing to merge: $branch has no commits ahead of main" }

        Write-Host "Reviewing $branch ($n commits) with Codex..."
        Push-Location $entry.worktree
        $review = $null | & $exe review -c sandbox_mode=read-only --base main 2>&1 | ForEach-Object { "$_" }
        $reviewRc = $LASTEXITCODE
        Pop-Location
        # A failed review has no findings to parse, so it must not count as a clean one.
        if ($reviewRc -ne 0 -and -not $Force) { Fail "Codex review failed (exit $reviewRc); see output above, or rerun with -Force" }
        [IO.File]::WriteAllText((Join-Path $paths.Out "review-$task.txt"), (($review -join "`r`n") + "`r`n"), $script:Utf8)
        $review | ForEach-Object { Write-Host $_ }

        $high = $review | Select-String '\[P[01]\]'
        $any = $review | Select-String '\[P[0-3]\]'
        if ($high -and -not $Force) { Fail 'P0/P1 findings; fix on the branch or rerun with -Force' }
        if ($any -and -not $Yes) {
            $ans = Read-Host 'Merge anyway? [y/N]'
            if ($ans -ne 'y') { Fail 'merge cancelled' }
        }

        git -C $paths.Main merge --no-ff --no-commit $branch | Out-Host
        if ($LASTEXITCODE -ne 0) {
            git -C $paths.Main merge --abort
            Fail 'merge conflicts; aborted. Rebase the branch on main and retry.'
        }

        # Test command comes from the "- Test: `...`" line in AGENTS.md.
        $testCmd = $null
        $agentsMd = Join-Path $paths.Main 'AGENTS.md'
        if (Test-Path $agentsMd) {
            foreach ($l in [IO.File]::ReadAllLines($agentsMd)) {
                if ($l -match '^- Test: `(.+)`$') { $testCmd = $Matches[1]; break }
            }
        }
        if ($testCmd -and $testCmd -ne 'TBD') {
            Write-Host "Running tests: $testCmd"
            Push-Location $paths.Main
            cmd.exe /d /c $testCmd
            $rc = $LASTEXITCODE
            Pop-Location
            if ($rc -ne 0) {
                git -C $paths.Main merge --abort
                Fail "tests failed (exit $rc); merge aborted"
            }
        }

        git -C $paths.Main commit -m "Merge $branch" | Out-Host
        if ($LASTEXITCODE -ne 0) { Fail 'merge commit failed' }
        Set-BoardStatus $paths $task 'merged'
        git -C $paths.Main worktree remove $entry.worktree
        if ($LASTEXITCODE -ne 0) {
            Write-Host "Merged $branch into main, but the worktree has leftover files. Inspect, then: git worktree remove --force `"$($entry.worktree)`" and git branch -d $branch" -ForegroundColor Yellow
            exit 1
        }
        git -C $paths.Main branch -d $branch
        Write-Host ''
        Write-Host "Merged $branch into main ($n commits). Worktree and branch removed."
    }

    'ui' {
        Start-Process cmd.exe -ArgumentList '/c', 'start', '""', 'antigravity-ide', "`"$($paths.Main)`"" -WindowStyle Hidden
    }

    'setup' {
        git -C $paths.Main config core.hooksPath .githooks
        if (-not (Test-Path $paths.Out)) { New-Item -ItemType Directory -Path $paths.Out | Out-Null }
        Write-Host 'Setup done: core.hooksPath=.githooks, .codex-out ready.'
    }

    default { Show-Usage }
}
