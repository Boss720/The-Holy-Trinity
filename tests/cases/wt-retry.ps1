Run-Case 'wt-retry: lock failures retry and other failures stop' {
    param($f)
    $tokens = $null; $errors = $null
    $tree = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $f.Repo 'scripts\trinity.ps1'), [ref]$tokens, [ref]$errors)
    Assert-True ($errors.Count -eq 0) 'trinity.ps1 did not parse'
    $fn = $tree.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Remove-WorktreeWithRetry' }, $true)
    Assert-True ($null -ne $fn) 'retry helper missing'
    . ([scriptblock]::Create($fn.Extent.Text))
    $oldDelays = $env:TRINITY_WT_RETRY_DELAYS
    try {
        $env:TRINITY_WT_RETRY_DELAYS = '0'
        $script:wtCalls = 0
        $runner = {
            param($mainPath, $worktreePath, $forceRemove)
            $script:wtCalls++
            Assert-True ($mainPath -eq 'main' -and $worktreePath -eq 'worktree' -and $forceRemove) 'runner arguments incorrect'
            if ($script:wtCalls -le 2) { return [pscustomobject]@{ ExitCode = 1; Output = 'Permission denied' } }
            [pscustomobject]@{ ExitCode = 0; Output = '' }
        }
        $code = Remove-WorktreeWithRetry -Main 'main' -Worktree 'worktree' -Force -Runner $runner
        Assert-True ($code -eq 0 -and $script:wtCalls -eq 3) 'lock retry did not succeed after two retries'
        $script:wtCalls = 0
        $runner = { $script:wtCalls++; [pscustomobject]@{ ExitCode = 2; Output = 'other failure' } }
        $code = Remove-WorktreeWithRetry -Main 'main' -Worktree 'worktree' -Runner $runner
        Assert-True ($code -eq 2 -and $script:wtCalls -eq 1) 'non-lock failure retried'
        $script:wtCalls = 0
        $runner = { $script:wtCalls++; [pscustomobject]@{ ExitCode = 1; Output = 'Device or resource busy' } }
        $code = Remove-WorktreeWithRetry -Main 'main' -Worktree 'worktree' -Runner $runner
        Assert-True ($code -eq 1 -and $script:wtCalls -eq 7) 'lock failure did not stop after six retries'
    }
    finally { $env:TRINITY_WT_RETRY_DELAYS = $oldDelays }
}
