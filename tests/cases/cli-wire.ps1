# Test cases for the GUI wiring in the CLI: merge -DryRun, the scope guard, the running-task guard,
# TRINITY_CODEX_MODEL/EFFORT, and settings from .trinity\trinity.json (docs/dashboard-gui.md).
# Dot-sourced by tests/run-tests.ps1.

Run-Case 'cli-wire: merge -DryRun runs the gate and merges nothing' {
    param($f)
    Start-CodexTask $f 'dry-task'
    $wait = Invoke-Trinity $f @('wait', 'dry-task', '-Timeout', '30')
    Assert-True ($wait.ExitCode -eq 0) "fixture task did not finish: $($wait.Output)"
    $dry = Invoke-Trinity $f @('merge', 'dry-task', '-DryRun')
    Assert-True ($dry.ExitCode -eq 0 -and $dry.Output -match 'dry run clean: review clean, tests passed') "dry run not clean: $($dry.Output)"
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $f.Repo 'fake-output.txt'))) 'dry run merged the branch into main'
    $show = Invoke-Trinity $f @('show', 'dry-task')
    Assert-True ($show.Output -match 'done') "dry run changed the board status: $($show.Output)"
    $merge = Invoke-Trinity $f @('merge', 'dry-task', '-Yes')
    Assert-True ($merge.ExitCode -eq 0 -and (Test-Path -LiteralPath (Join-Path $f.Repo 'fake-output.txt'))) "real merge after a dry run failed: $($merge.Output)"
}

Run-Case 'cli-wire: scope guard blocks files outside -Scope, warn and -Force let them through' {
    param($f)
    Start-CodexTask $f 'scope-task'
    $wait = Invoke-Trinity $f @('wait', 'scope-task', '-Timeout', '30')
    Assert-True ($wait.ExitCode -eq 0) "fixture task did not finish: $($wait.Output)"
    $env:TRINITY_SCOPE_GUARD = 'block'
    $blocked = Invoke-Trinity $f @('merge', 'scope-task', '-Yes')
    Assert-True ($blocked.ExitCode -ne 0 -and $blocked.Output -match 'outside the task scope' -and $blocked.Output -match 'fake-output\.txt') "scope guard did not block: $($blocked.Output)"
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $f.Repo 'fake-output.txt'))) 'blocked merge still changed main'
    $dry = Invoke-Trinity $f @('merge', 'scope-task', '-DryRun')
    Assert-True ($dry.ExitCode -ne 0) "dry run passed an out-of-scope branch: $($dry.Output)"
    $env:TRINITY_SCOPE_GUARD = 'warn'
    $warn = Invoke-Trinity $f @('merge', 'scope-task', '-DryRun')
    Assert-True ($warn.ExitCode -eq 0 -and $warn.Output -match '1 out of scope \(warn only\)') "warn mode should pass and say so: $($warn.Output)"
    $env:TRINITY_SCOPE_GUARD = 'block'
    $forced = Invoke-Trinity $f @('merge', 'scope-task', '-Yes', '-Force')
    Assert-True ($forced.ExitCode -eq 0 -and (Test-Path -LiteralPath (Join-Path $f.Repo 'fake-output.txt'))) "-Force should merge: $($forced.Output)"
}

Run-Case 'cli-wire: merge refuses a task that is still running' {
    param($f)
    Set-CliTask $f 'busy-task' 'running'
    $merge = Invoke-Trinity $f @('merge', 'busy-task', '-Yes')
    Assert-True ($merge.ExitCode -ne 0 -and $merge.Output -match 'still running') "merge of a running task was not refused: $($merge.Output)"
}

Run-Case 'cli-wire: TRINITY_CODEX_MODEL and TRINITY_CODEX_EFFORT reach the Codex command line' {
    param($f)
    $env:TRINITY_CODEX_MODEL = 'gpt-test-model'
    $env:TRINITY_CODEX_EFFORT = 'high'
    Start-CodexTask $f 'model-task'
    $wait = Invoke-Trinity $f @('wait', 'model-task', '-Timeout', '30')
    Assert-True ($wait.ExitCode -eq 0) "fixture task did not finish: $($wait.Output)"
    $run = [IO.File]::ReadAllText((Join-Path $f.Repo '.codex-out\run-model-task.cmd'))
    Assert-True ($run -match '-c model=gpt-test-model -c model_reasoning_effort=high') "model args missing from the runner: $run"
    $env:TRINITY_CODEX_EFFORT = 'turbo'
    $bad = Invoke-Trinity $f @('ask', 'hello')
    Assert-True ($bad.ExitCode -ne 0 -and $bad.Output -match 'invalid TRINITY_CODEX_EFFORT') "bad effort accepted: $($bad.Output)"
}

Run-Case 'cli-wire: trinity config set/get and base branch from trinity.json' {
    param($f)
    if (-not (Test-Path -LiteralPath (Join-Path $f.Repo 'scripts\lib\config.ps1'))) { Skip-Case 'scripts\lib\config.ps1 not installed' }
    $set = Invoke-Trinity $f @('config', 'set', 'base', 'develop')
    Assert-True ($set.ExitCode -eq 0) "config set failed: $($set.Output)"
    $get = Invoke-Trinity $f @('config', 'get', 'base')
    Assert-True ($get.Output.Trim() -eq 'develop') "config get base wrong: $($get.Output)"
    $status = Invoke-Trinity $f @('status', '-Brief')
    Assert-True ($status.Output -match '(?m)^base: develop \(trinity\.json\)') "base from trinity.json not used: $($status.Output)"
    $bad = Invoke-Trinity $f @('config', 'set', 'slots.codex', '99')
    Assert-True ($bad.ExitCode -ne 0 -and $bad.Output -match 'config not saved') "out-of-range slot accepted: $($bad.Output)"
    $env:TRINITY_BASE = 'release'
    try {
        $status = Invoke-Trinity $f @('status', '-Brief')
        Assert-True ($status.Output -match '(?m)^base: release \(TRINITY_BASE\)') "env should beat trinity.json: $($status.Output)"
    }
    finally { $env:TRINITY_BASE = $null }
}
