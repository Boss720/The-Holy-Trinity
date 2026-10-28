# Test cases for the merge gate: unparsed review output blocks, a base that moves during review is reviewed again.
# Dot-sourced by tests/run-tests.ps1.

# Reviewer stand-in for the merge step. It hands everything except "review" to the stock fake Codex, so a worker can
# still be dispatched through it. "review" behaves as GATE_REVIEW_MODE says and counts its runs in GATE_COUNT_FILE.
function Install-GateReviewer($f) {
    $ps1 = @'
$ErrorActionPreference = 'Stop'
$arguments = $env:GATE_ARGUMENTS
if ($arguments -notmatch '^\s*review(?:\s|$)') {
    $env:FAKE_CODEX_ARGUMENTS = $arguments
    & (Join-Path $env:GATE_FAKE_DIR 'fake-codex.ps1')
    exit $LASTEXITCODE
}
$count = 0
if (Test-Path -LiteralPath $env:GATE_COUNT_FILE) { $count = [int][IO.File]::ReadAllText($env:GATE_COUNT_FILE) }
$count++
[IO.File]::WriteAllText($env:GATE_COUNT_FILE, "$count")
$usage = "ERROR: You've hit your usage limit. Try again later."
switch ($env:GATE_REVIEW_MODE) {
    'empty' { exit 0 }
    'usage' { [Console]::WriteLine($usage); exit 0 }
    'usage-exit' { [Console]::WriteLine($usage); exit 1 }
    'crash' {
        [Console]::WriteLine('System.NullReferenceException: Object reference not set to an instance of an object.')
        [Console]::WriteLine('   at <ScriptBlock>, <No file>: line 1')
        exit 0
    }
    'transcript-usage' {
        # The quoted prompt and diff mention "no findings"; the run itself died on the limit.
        foreach ($l in @('OpenAI Codex v0.0-test', '--------', 'user', 'Reply "No findings." when the diff is clean.', 'codex', 'Reading the diff.', $usage)) { [Console]::WriteLine($l) }
        exit 0
    }
    'transcript-clean' {
        $answer = 'No actionable defects were identified in the changes. Tests were not run because the sandbox is read-only.'
        foreach ($l in @('OpenAI Codex v0.0-test', '--------', 'user', 'current changes', 'codex', 'Reading the diff.', 'codex', $answer, $answer)) { [Console]::WriteLine($l) }
        exit 0
    }
    'move-base' {
        # The base branch gets a new commit while the first review is running.
        if ($count -eq 1) {
            [IO.File]::WriteAllText((Join-Path $env:GATE_MAIN 'base-moved.txt'), "moved`r`n")
            & git -C $env:GATE_MAIN add base-moved.txt 2>$null
            & git -C $env:GATE_MAIN commit -q -m 'base moved during review' 2>$null
        }
        [Console]::WriteLine('No findings.')
        exit 0
    }
    'move-base-then-p1' {
        if ($count -eq 1) {
            [IO.File]::WriteAllText((Join-Path $env:GATE_MAIN 'base-moved.txt'), "moved`r`n")
            & git -C $env:GATE_MAIN add base-moved.txt 2>$null
            & git -C $env:GATE_MAIN commit -q -m 'base moved during review' 2>$null
            [Console]::WriteLine('No findings.')
        }
        else { [Console]::WriteLine('- [P1] breaks against the moved base - a.txt:1') }
        exit 0
    }
    'move-always' {
        [IO.File]::WriteAllText((Join-Path $env:GATE_MAIN "base-moved-$count.txt"), "moved`r`n")
        & git -C $env:GATE_MAIN add -A 2>$null
        & git -C $env:GATE_MAIN commit -q -m "base moved again $count" 2>$null
        [Console]::WriteLine('No findings.')
        exit 0
    }
    default { [Console]::WriteLine('No findings.'); exit 0 }
}
'@
    $cmd = Join-Path $f.Root 'gate-codex.cmd'
    $utf8 = New-Object Text.UTF8Encoding($false)
    [IO.File]::WriteAllText((Join-Path $f.Root 'gate-codex.ps1'), $ps1 + "`r`n", $utf8)
    [IO.File]::WriteAllText($cmd, "@echo off`r`nset ""GATE_ARGUMENTS=%*""`r`npowershell -NoProfile -ExecutionPolicy Bypass -File ""%~dp0gate-codex.ps1""`r`nexit /b %ERRORLEVEL%`r`n", $utf8)
    $env:GATE_FAKE_DIR = Join-Path $f.Repo 'tests'
    $env:GATE_COUNT_FILE = Join-Path $f.Root 'gate-count.txt'
    $env:GATE_MAIN = $f.Repo
    $env:GATE_REVIEW_MODE = 'default'
    $env:CODEX_EXE = $cmd
    # The author is Codex, so without this the merge would pick Claude as the reviewer.
    $env:TRINITY_REVIEWER = 'codex'
}

function Clear-GateReviewer {
    foreach ($name in 'GATE_FAKE_DIR', 'GATE_COUNT_FILE', 'GATE_MAIN', 'GATE_REVIEW_MODE', 'GATE_ARGUMENTS') { [Environment]::SetEnvironmentVariable($name, $null) }
}

function Get-GateReviewCount($f) {
    $file = Join-Path $f.Root 'gate-count.txt'
    if (Test-Path -LiteralPath $file) { [int][IO.File]::ReadAllText($file) } else { 0 }
}

Run-Case 'cli-merge-gate: review output that is not findings or a clean answer blocks the merge, -Force overrides' {
    param($f)
    try {
        Start-CodexTask $f 'gate-u'
        $wait = Invoke-Trinity $f @('wait', 'gate-u', '-Timeout', '50')
        Assert-True ($wait.ExitCode -eq 0) "wait exit $($wait.ExitCode): $($wait.Output)"
        Install-GateReviewer $f
        $mainBefore = Invoke-Git $f.Repo @('rev-parse', 'main')
        foreach ($mode in @('empty', 'usage', 'crash', 'transcript-usage', 'usage-exit')) {
            $env:GATE_REVIEW_MODE = $mode
            $blocked = Invoke-Trinity $f @('merge', 'gate-u', '-Yes')
            Assert-True ($blocked.ExitCode -ne 0 -and $blocked.Output -match 'review output unparsed') "$mode review should block with 'review output unparsed': $($blocked.Output)"
            Assert-True ($blocked.Output -notmatch 'Running tests') "$mode review reached the test step: $($blocked.Output)"
            Assert-True ((Invoke-Git $f.Repo @('rev-parse', 'main')) -eq $mainBefore) "main changed after a blocked $mode review"
        }
        $reviewFile = Join-Path $f.Repo '.codex-out\review-gate-u.md'
        Assert-True (Test-Path -LiteralPath $reviewFile) 'review text was not saved to review-gate-u.md'
        $env:GATE_REVIEW_MODE = 'usage'
        $forced = Invoke-Trinity $f @('merge', 'gate-u', '-Yes', '-Force')
        Assert-True ($forced.ExitCode -eq 0 -and $forced.Output -match 'merging anyway') "-Force should override an unparsed review: $($forced.Output)"
        Assert-True ((Invoke-Git $f.Repo @('show', 'main:fake-output.txt')) -eq 'fake codex output') 'forced merge did not update main'
        Assert-True ((Get-Content -Raw $reviewFile) -match 'usage limit') 'review-gate-u.md does not hold the last review text'
    }
    finally { Clear-GateReviewer }
}

Run-Case 'cli-merge-gate: a clean Codex transcript merges after one review and is saved' {
    param($f)
    try {
        Start-CodexTask $f 'gate-c'
        $wait = Invoke-Trinity $f @('wait', 'gate-c', '-Timeout', '50')
        Assert-True ($wait.ExitCode -eq 0) "wait exit $($wait.ExitCode): $($wait.Output)"
        Install-GateReviewer $f
        $env:GATE_REVIEW_MODE = 'transcript-clean'
        $merge = Invoke-Trinity $f @('merge', 'gate-c', '-Yes')
        Assert-True ($merge.ExitCode -eq 0) "a clean transcript should merge: $($merge.Output)"
        Assert-True ((Get-GateReviewCount $f) -eq 1) "base did not move, so exactly one review was expected, got $(Get-GateReviewCount $f)"
        Assert-True ($merge.Output -notmatch 'moved while the review ran') 'unexpected re-review message'
        $saved = Get-Content -Raw (Join-Path $f.Repo '.codex-out\review-gate-c.md')
        Assert-True ($saved -match 'No actionable defects were identified') "review-gate-c.md lacks the review text: $saved"
    }
    finally { Clear-GateReviewer }
}

Run-Case 'cli-merge-gate: base moved during the review triggers a second review before merging' {
    param($f)
    try {
        Start-CodexTask $f 'gate-m'
        $wait = Invoke-Trinity $f @('wait', 'gate-m', '-Timeout', '50')
        Assert-True ($wait.ExitCode -eq 0) "wait exit $($wait.ExitCode): $($wait.Output)"
        Install-GateReviewer $f
        $env:GATE_REVIEW_MODE = 'move-base'
        $merge = Invoke-Trinity $f @('merge', 'gate-m', '-Yes')
        Assert-True ($merge.ExitCode -eq 0) "merge after a moved base failed: $($merge.Output)"
        Assert-True ($merge.Output -match 'main moved while the review ran') "no stale-review message: $($merge.Output)"
        Assert-True ((Get-GateReviewCount $f) -eq 2) "expected 2 reviews, got $(Get-GateReviewCount $f)"
        Assert-True (([regex]::Matches($merge.Output, '(?m)^reviewer: codex')).Count -eq 2) "same reviewer should run twice: $($merge.Output)"
        Assert-True ($merge.Output -match 'Reviewing again') "second review was not announced: $($merge.Output)"
        Assert-True ((Invoke-Git $f.Repo @('show', 'main:base-moved.txt')) -eq 'moved') 'the commit that moved the base is gone'
        Assert-True ((Invoke-Git $f.Repo @('show', 'main:fake-output.txt')) -eq 'fake codex output') 'the branch was not merged'
    }
    finally { Clear-GateReviewer }
}

Run-Case 'cli-merge-gate: the second review after a moved base still gates the merge' {
    param($f)
    try {
        Start-CodexTask $f 'gate-s'
        $wait = Invoke-Trinity $f @('wait', 'gate-s', '-Timeout', '50')
        Assert-True ($wait.ExitCode -eq 0) "wait exit $($wait.ExitCode): $($wait.Output)"
        Install-GateReviewer $f
        $env:GATE_REVIEW_MODE = 'move-base-then-p1'
        $blocked = Invoke-Trinity $f @('merge', 'gate-s', '-Yes')
        Assert-True ($blocked.ExitCode -ne 0 -and $blocked.Output -match 'P0/P1 findings') "P1 from the second review should block: $($blocked.Output)"
        Assert-True ((Get-GateReviewCount $f) -eq 2) "expected 2 reviews, got $(Get-GateReviewCount $f)"
        $files = @(Invoke-Git $f.Repo @('ls-tree', '--name-only', 'main'))
        Assert-True (($files -join ' ') -notmatch 'fake-output.txt') 'the branch was merged despite the P1'
        $mergeHead = & git -C $f.Repo rev-parse -q --verify MERGE_HEAD 2>$null
        Assert-True ($LASTEXITCODE -ne 0) "merge is still in progress: $mergeHead"
    }
    finally { Clear-GateReviewer }
}

Run-Case 'cli-merge-gate: a base that keeps moving stops the merge after three reviews' {
    param($f)
    try {
        Start-CodexTask $f 'gate-k'
        $wait = Invoke-Trinity $f @('wait', 'gate-k', '-Timeout', '50')
        Assert-True ($wait.ExitCode -eq 0) "wait exit $($wait.ExitCode): $($wait.Output)"
        Install-GateReviewer $f
        $env:GATE_REVIEW_MODE = 'move-always'
        $stopped = Invoke-Trinity $f @('merge', 'gate-k', '-Yes')
        Assert-True ($stopped.ExitCode -ne 0 -and $stopped.Output -match 'moved again') "endless moving should stop the merge: $($stopped.Output)"
        Assert-True ((Get-GateReviewCount $f) -eq 3) "expected 3 reviews, got $(Get-GateReviewCount $f)"
        $files = @(Invoke-Git $f.Repo @('ls-tree', '--name-only', 'main'))
        Assert-True (($files -join ' ') -notmatch 'fake-output.txt') 'the branch was merged anyway'
    }
    finally { Clear-GateReviewer }
}

Run-Case 'cli-merge-gate: TRINITY_REVIEWER=none keeps tests alone as the gate and saves the note' {
    param($f)
    Start-CodexTask $f 'gate-n'
    $wait = Invoke-Trinity $f @('wait', 'gate-n', '-Timeout', '50')
    Assert-True ($wait.ExitCode -eq 0) "wait exit $($wait.ExitCode): $($wait.Output)"
    $env:TRINITY_REVIEWER = 'none'
    $merge = Invoke-Trinity $f @('merge', 'gate-n', '-Yes')
    Assert-True ($merge.ExitCode -eq 0 -and $merge.Output -match 'Tests alone gate' -and $merge.Output -notmatch 'unparsed') "unreviewed merge should pass on tests: $($merge.Output)"
    Assert-True ((Get-Content -Raw (Join-Path $f.Repo '.codex-out\review-gate-n.md')) -match 'No review') 'the no-review note was not saved'
}

Run-Case 'cli-merge-gate: Test-ReviewClean accepts real reviewer answers and rejects errors' {
    param($f)
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.Trinity, [ref]$null, [ref]$null)
    $fn = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Test-ReviewClean' }, $true) | Select-Object -First 1
    Assert-True ($null -ne $fn) 'Test-ReviewClean is missing from trinity.ps1'
    Invoke-Expression $fn.Extent.Text
    $limit = "ERROR: You've hit your usage limit."
    $banner = @('OpenAI Codex v0.0-test', '--------', 'user', 'current changes')
    $accepted = [ordered]@{
        'plain no findings'    = @('No findings.')
        'bold no findings'     = @('**No findings.**')
        'codex no defects'     = @('No actionable defects were found in the staged, unstaged, or untracked changes. The test suite was not run.')
        'codex no regressions' = @('No actionable regressions were identified in the diff. Tests were not run because the environment is read-only.')
        'codex definite'       = @('I found no definite regression in the changed code.')
        'codex to report'      = @('The staged and unstaged changes are consistent on inspection. I found no actionable regressions to report.')
        'did not find'         = @('I did not find any actionable defects in the diff.')
        'transcript answer'    = @($banner + @('The diff quotes an ERROR message.', 'codex', 'checking', 'codex', 'No actionable defects were found.', 'No actionable defects were found.'))
    }
    foreach ($name in $accepted.Keys) { Assert-True ([bool](Test-ReviewClean ([string[]]$accepted[$name]))) "clean answer rejected: $name" }
    $rejected = [ordered]@{
        'no lines'            = @()
        'blank output'        = @('', '  ')
        'usage limit'         = @($limit)
        'bare usage limit'    = @("You've hit your usage limit.")
        'stack trace'         = @('System.NullReferenceException: Object reference not set to an instance of an object.', '   at <ScriptBlock>, <No file>: line 1')
        'transcript no answer' = @($banner + @('The prompt says no findings means clean.', $limit))
        'transcript limit'    = @($banner + @('Quoted: no issues so far.', 'codex', $limit))
        'transcript empty'    = @($banner)
        'untagged finding'    = @('[P1] something broke - a.txt:1')
        'finding in prose'    = @('The patch breaks the build because the loop never ends.')
    }
    foreach ($name in $rejected.Keys) { Assert-True (-not [bool](Test-ReviewClean ([string[]]$rejected[$name]))) "unclear output accepted as clean: $name" }
}
