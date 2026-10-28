Run-Case 'dispatch seeds the worktree from trinity-seed.txt and never commits seeded files' {
    param($f)
    $utf8 = New-Object Text.UTF8Encoding($false)
    [IO.File]::WriteAllText((Join-Path $f.Repo '.gitignore'), ".codex-out/`r`n.env`r`n", $utf8)
    [IO.File]::WriteAllText((Join-Path $f.Repo 'trinity-seed.txt'), "# seed`r`ncopy .env`r`nrun echo seeded-ok`r`n", $utf8)
    Invoke-Git $f.Repo @('add', '-A') | Out-Null
    Invoke-Git $f.Repo @('commit', '-m', 'seed config') | Out-Null
    [IO.File]::WriteAllText((Join-Path $f.Repo '.env'), "KEY=fixture`r`n", $utf8)

    Start-CodexTask $f 'seeded'
    $wt = Join-Path $f.Worktrees 'codex-seeded'
    Assert-True ((Get-Content -Raw (Join-Path $wt '.env')) -match 'KEY=fixture') '.env was not copied into the worktree'
    $log = Join-Path $f.Repo '.codex-out\seed-seeded.log'
    Assert-True ((Test-Path -LiteralPath $log) -and ((Get-Content -Raw $log) -match 'seeded-ok')) 'seed log missing or lacks the run output'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $wt '.trinity-seed.log'))) 'seed log was written inside the worktree'

    $wait = Invoke-Trinity $f @('wait', 'seeded', '-Timeout', '50')
    Assert-True ($wait.ExitCode -eq 0) "wait exit $($wait.ExitCode): $($wait.Output)"
    $files = Invoke-Git $f.Repo @('diff', '--name-only', 'main...agent/codex/seeded')
    Assert-True ($files -notmatch '\.env|seed') "seeded files reached the task commit: $files"
}

Run-Case 'dispatch without trinity-seed.txt is unchanged' {
    param($f)
    Start-CodexTask $f 'noseed'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $f.Repo '.codex-out\seed-noseed.log'))) 'seed log written without a config'
    $wait = Invoke-Trinity $f @('wait', 'noseed', '-Timeout', '50')
    Assert-True ($wait.ExitCode -eq 0) "wait exit $($wait.ExitCode): $($wait.Output)"
}
