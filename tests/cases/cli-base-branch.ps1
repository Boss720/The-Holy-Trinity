# Test cases for the resolved base branch (-Base, TRINITY_BASE, origin/HEAD, main).
# Dot-sourced by tests/run-tests.ps1.

# A repo whose default branch is develop: rename the fixture's main and mark develop as the remote default.
function Set-FixtureDevelopBranch($f, [bool]$OriginHead) {
    Invoke-Git $f.Repo @('branch', '-m', 'main', 'develop') | Out-Null
    if ($OriginHead) { Invoke-Git $f.Repo @('symbolic-ref', 'refs/remotes/origin/HEAD', 'refs/remotes/origin/develop') | Out-Null }
}

Run-Case 'cli-base-branch: status shows the base and where it came from, in order -Base, TRINITY_BASE, origin/HEAD, main' {
    param($f)
    try {
        $env:TRINITY_BASE = $null
        $status = Invoke-Trinity $f @('status', '-Brief')
        Assert-True ($status.ExitCode -eq 0 -and $status.Output -match '(?m)^base: main \(default\)') "default base wrong: $($status.Output)"
        Assert-True ($status.Output -match '(?m)^main checkout: branch=main') "main checkout line changed: $($status.Output)"
        Invoke-Git $f.Repo @('symbolic-ref', 'refs/remotes/origin/HEAD', 'refs/remotes/origin/develop') | Out-Null
        $status = Invoke-Trinity $f @('status', '-Brief')
        Assert-True ($status.Output -match '(?m)^base: develop \(origin/HEAD\)') "origin/HEAD base wrong: $($status.Output)"
        Invoke-Git $f.Repo @('symbolic-ref', 'refs/remotes/origin/HEAD', 'refs/remotes/origin/feature/x') | Out-Null
        $status = Invoke-Trinity $f @('status', '-Brief')
        Assert-True ($status.Output -match '(?m)^base: feature/x \(origin/HEAD\)') "only the origin/ prefix should be stripped: $($status.Output)"
        $env:TRINITY_BASE = 'release'
        $status = Invoke-Trinity $f @('status', '-Brief')
        Assert-True ($status.Output -match '(?m)^base: release \(TRINITY_BASE\)') "TRINITY_BASE should beat origin/HEAD: $($status.Output)"
        $status = Invoke-Trinity $f @('status', '-Brief', '-Base', 'hotfix')
        Assert-True ($status.Output -match '(?m)^base: hotfix \(-Base\)') "-Base should beat TRINITY_BASE: $($status.Output)"
        $env:TRINITY_BASE = '   '
        $status = Invoke-Trinity $f @('status', '-Brief')
        Assert-True ($status.Output -match '(?m)^base: feature/x \(origin/HEAD\)') "a blank TRINITY_BASE should be ignored: $($status.Output)"
        $order = Invoke-Trinity $f @('status', '-Brief')
        Assert-True ($order.Output -match '(?m)^agents:.*\r?\norchestrator:') 'the base line must not sit between agents and orchestrator'
    }
    finally { $env:TRINITY_BASE = $null }
}

Run-Case 'cli-base-branch: a develop repo dispatches and merges with TRINITY_BASE' {
    param($f)
    try {
        Set-FixtureDevelopBranch $f $false
        $env:TRINITY_BASE = $null
        # Without any setting trinity still branches from main, which this repo does not have.
        $noBase = Invoke-Trinity $f @('dispatch', 'codex', 'dev-none', '-Scope', 'tests/*', '-PromptFile', $f.Prompt)
        Assert-True ($noBase.ExitCode -ne 0 -and $noBase.Output -match "branch 'main' does not exist") "dispatch without a base should name the problem: $($noBase.Output)"
        $env:TRINITY_BASE = 'develop'
        Start-CodexTask $f 'dev-a'
        $wait = Invoke-Trinity $f @('wait', 'dev-a', '-Timeout', '50')
        Assert-True ($wait.ExitCode -eq 0) "wait exit $($wait.ExitCode): $($wait.Output)"
        Assert-True ($wait.Output -match '--- commits ---\s+\S+ dev-a:') "wait should list the commits against develop: $($wait.Output)"
        Assert-True ($wait.Output -match 'fake-output.txt') "wait should show the diffstat against develop: $($wait.Output)"
        $show = Invoke-Trinity $f @('show', 'dev-a')
        Assert-True ($show.ExitCode -eq 0 -and $show.Output -match '(?m)^commitsAhead: 1\b') "show should count commits against develop: $($show.Output)"
        # The main checkout must be on the base branch.
        Invoke-Git $f.Repo @('checkout', '-q', '-b', 'elsewhere') | Out-Null
        $wrong = Invoke-Trinity $f @('merge', 'dev-a', '-Yes')
        Assert-True ($wrong.ExitCode -ne 0 -and $wrong.Output -match "main checkout is on 'elsewhere', switch it to develop first") "merge from the wrong branch: $($wrong.Output)"
        Invoke-Git $f.Repo @('checkout', '-q', 'develop') | Out-Null
        $merge = Invoke-Trinity $f @('merge', 'dev-a', '-Yes')
        Assert-True ($merge.ExitCode -eq 0 -and $merge.Output -match 'into develop') "merge into develop failed: $($merge.Output)"
        Assert-True ((Invoke-Git $f.Repo @('show', 'develop:fake-output.txt')) -eq 'fake codex output') 'develop was not updated'
        Assert-True ((Invoke-Git $f.Repo @('branch', '--list', 'agent/codex/dev-a')) -eq '') 'task branch was not removed'
    }
    finally { $env:TRINITY_BASE = $null }
}

Run-Case 'cli-base-branch: origin/HEAD alone selects develop for dispatch, review and merge' {
    param($f)
    try {
        $env:TRINITY_BASE = $null
        Set-FixtureDevelopBranch $f $true
        $status = Invoke-Trinity $f @('status', '-Brief')
        Assert-True ($status.Output -match '(?m)^base: develop \(origin/HEAD\)') "origin/HEAD base wrong: $($status.Output)"
        Start-CodexTask $f 'dev-b'
        $wait = Invoke-Trinity $f @('wait', 'dev-b', '-Timeout', '50')
        Assert-True ($wait.ExitCode -eq 0) "wait exit $($wait.ExitCode): $($wait.Output)"
        $review = Invoke-Trinity $f @('review', '--base', 'develop')
        Assert-True ($review.ExitCode -eq 0 -and $review.Output -match 'reviewer: codex') "review --base develop failed: $($review.Output)"
        $merge = Invoke-Trinity $f @('merge', 'dev-b', '-Yes')
        Assert-True ($merge.ExitCode -eq 0 -and $merge.Output -match 'into develop') "merge into develop failed: $($merge.Output)"
        Assert-True ((Invoke-Git $f.Repo @('show', 'develop:fake-output.txt')) -eq 'fake codex output') 'develop was not updated'
        # The merge gate reviews against the resolved base, not main.
        Assert-True (Test-Path -LiteralPath (Join-Path $f.Repo '.codex-out\review-dev-b.md')) 'review text was not saved'
    }
    finally { $env:TRINITY_BASE = $null }
}
