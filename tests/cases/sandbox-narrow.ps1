Run-Case 'sandbox-narrow: Codex receives only its worktree git directory' {
    param($f)
    Start-CodexTask $f 'sandbox-narrow'
    $wait = Invoke-Trinity $f @('wait', 'sandbox-narrow', '-Timeout', '60')
    Assert-True ($wait.ExitCode -eq 0) "worker failed: $($wait.Output)"
    $wt = Join-Path $f.Worktrees 'codex-sandbox-narrow'
    $gitDir = Invoke-Git $wt @('rev-parse', '--absolute-git-dir')
    $common = Invoke-Git $wt @('rev-parse', '--path-format=absolute', '--git-common-dir')
    $cmd = Get-Content -Raw (Join-Path $f.Repo '.codex-out\run-sandbox-narrow.cmd')
    Assert-True ($cmd.Contains('--add-dir "' + $gitDir + '"')) "worktree git directory missing: $cmd"
    Assert-True (-not $cmd.Contains('--add-dir "' + $common + '"')) "common git directory granted: $cmd"
}
