# Test cases for wave 2 CLI fixes (base-aware cancel, help text).
# Dot-sourced by tests/run-tests.ps1.

Run-Case 'cli-wave2-fixes: cancel counts commits against the resolved base, not main' {
    param($f)
    try {
        Invoke-Git $f.Repo @('branch', '-m', 'main', 'develop') | Out-Null
        $env:TRINITY_BASE = 'develop'
        Start-CodexTask $f 'w2-a'
        $wait = Invoke-Trinity $f @('wait', 'w2-a', '-Timeout', '50')
        Assert-True ($wait.ExitCode -eq 0) "wait exit $($wait.ExitCode): $($wait.Output)"
        $cancel = Invoke-Trinity $f @('cancel', 'w2-a')
        Assert-True ($cancel.ExitCode -ne 0 -and $cancel.Output -match 'has 1 commits; rerun with -Force') "cancel without -Force should refuse: $($cancel.Output)"
        $force = Invoke-Trinity $f @('cancel', 'w2-a', '-Force')
        Assert-True ($force.ExitCode -eq 0) "cancel -Force failed: $($force.Output)"
    }
    finally { $env:TRINITY_BASE = $null }
}

Run-Case 'cli-wave2-fixes: help documents resume and -Base' {
    param($f)
    $help = Invoke-Trinity $f @('help')
    Assert-True ($help.ExitCode -eq 0) "help failed: $($help.Output)"
    Assert-True ($help.Output -match 'resume <task>') "help should mention resume <task>: $($help.Output)"
    Assert-True ($help.Output -match '-Base <branch>') "help should mention -Base <branch>: $($help.Output)"
}
