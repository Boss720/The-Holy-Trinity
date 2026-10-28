# Test cases for scripts/lib/seed.ps1 (Worktree seeding).
# Dot-sourced by tests/run-tests.ps1.

. (Join-Path $repoSource 'scripts\lib\seed.ps1')

Run-Case 'seed library: no config returns empty result' {
    param($f)
    $main = Join-Path $f.Root 'seed-main-noconfig'
    $wt = Join-Path $f.Root 'seed-wt-noconfig'
    New-Item -ItemType Directory -Path $main, $wt -Force | Out-Null

    $res = Invoke-WorktreeSeed -MainPath $main -WorktreePath $wt
    Assert-True ($null -ne $res) 'Result was null'
    Assert-True ($res.Copied.Count -eq 0) "Expected 0 copied, got $($res.Copied.Count)"
    Assert-True ($res.Skipped.Count -eq 0) "Expected 0 skipped, got $($res.Skipped.Count)"
    Assert-True ($null -eq $res.Command) 'Expected Command to be null'
    Assert-True ($null -eq $res.ExitCode) 'Expected ExitCode to be null'
    Assert-True ($res.LogPath -eq (Join-Path $wt '.trinity-seed.log')) "LogPath mismatch: $($res.LogPath)"
}

Run-Case 'seed library: copy file, wildcard, and nested folder' {
    param($f)
    $main = Join-Path $f.Root 'seed-main-copy'
    $wt = Join-Path $f.Root 'seed-wt-copy'
    $cfgDir = Join-Path $main 'config'
    $nestedDir = Join-Path $main 'nested\deep\folder'
    New-Item -ItemType Directory -Path $cfgDir, $nestedDir, $wt -Force | Out-Null

    [IO.File]::WriteAllText((Join-Path $main '.env'), "SECRET_KEY=12345`r`n")
    [IO.File]::WriteAllText((Join-Path $cfgDir 'app.json'), "{`"name`":`"app`"}`r`n")
    [IO.File]::WriteAllText((Join-Path $cfgDir 'db.json'), "{`"host`":`"localhost`"}`r`n")
    [IO.File]::WriteAllText((Join-Path $nestedDir 'file.txt'), "nested content`r`n")

    $seedConfig = @(
        '# Seeding config',
        '',
        'copy .env',
        'copy config\*.json',
        'copy nested\deep\folder\file.txt'
    ) -join "`r`n"
    [IO.File]::WriteAllText((Join-Path $main 'trinity-seed.txt'), $seedConfig + "`r`n")

    $res = Invoke-WorktreeSeed -MainPath $main -WorktreePath $wt
    Assert-True ($res.Copied.Count -eq 4) "Expected 4 copied, got $($res.Copied.Count)"
    Assert-True ($res.Skipped.Count -eq 0) "Expected 0 skipped, got $($res.Skipped.Count)"

    $wtEnv = Join-Path $wt '.env'
    $wtApp = Join-Path $wt 'config\app.json'
    $wtDb = Join-Path $wt 'config\db.json'
    $wtNested = Join-Path $wt 'nested\deep\folder\file.txt'

    Assert-True (Test-Path -LiteralPath $wtEnv) '.env was not copied to worktree'
    Assert-True (Test-Path -LiteralPath $wtApp) 'config\app.json was not copied'
    Assert-True (Test-Path -LiteralPath $wtDb) 'config\db.json was not copied'
    Assert-True (Test-Path -LiteralPath $wtNested) 'nested\deep\folder\file.txt was not copied'
    Assert-True ((Get-Content -Raw $wtEnv) -match 'SECRET_KEY=12345') '.env content mismatch'
    Assert-True ((Get-Content -Raw $wtNested) -match 'nested content') 'nested file content mismatch'
}

Run-Case 'seed library: no overwrite preserves existing files' {
    param($f)
    $main = Join-Path $f.Root 'seed-main-nooverwrite'
    $wt = Join-Path $f.Root 'seed-wt-nooverwrite'
    New-Item -ItemType Directory -Path $main, $wt -Force | Out-Null

    [IO.File]::WriteAllText((Join-Path $main '.env'), "MAIN_VAL`r`n")
    [IO.File]::WriteAllText((Join-Path $wt '.env'), "EXISTING_VAL`r`n")
    [IO.File]::WriteAllText((Join-Path $main 'trinity-seed.txt'), "copy .env`r`n")

    $res = Invoke-WorktreeSeed -MainPath $main -WorktreePath $wt
    Assert-True ($res.Copied.Count -eq 0) "Expected 0 copied, got $($res.Copied.Count)"
    Assert-True ($res.Skipped.Count -eq 1) "Expected 1 skipped, got $($res.Skipped.Count)"
    Assert-True ($res.Skipped[0] -match 'exists') "Skipped entry did not mention exists: $($res.Skipped[0])"
    Assert-True ($res.Skipped[0] -match '\.env') "Skipped entry did not mention .env: $($res.Skipped[0])"
    Assert-True ((Get-Content -Raw (Join-Path $wt '.env')).Trim() -eq 'EXISTING_VAL') 'Existing worktree file was overwritten'
}

Run-Case 'seed library: missing source records skipped missing' {
    param($f)
    $main = Join-Path $f.Root 'seed-main-missing'
    $wt = Join-Path $f.Root 'seed-wt-missing'
    New-Item -ItemType Directory -Path $main, $wt -Force | Out-Null

    $seedConfig = @(
        'copy nonexistent.env',
        'copy absent\*.json'
    ) -join "`r`n"
    [IO.File]::WriteAllText((Join-Path $main 'trinity-seed.txt'), $seedConfig + "`r`n")

    $res = Invoke-WorktreeSeed -MainPath $main -WorktreePath $wt
    Assert-True ($res.Copied.Count -eq 0) "Expected 0 copied, got $($res.Copied.Count)"
    Assert-True ($res.Skipped.Count -eq 2) "Expected 2 skipped, got $($res.Skipped.Count)"
    Assert-True ($res.Skipped[0] -match 'missing') "Expected missing in entry 0: $($res.Skipped[0])"
    Assert-True ($res.Skipped[1] -match 'missing') "Expected missing in entry 1: $($res.Skipped[1])"
}

Run-Case 'seed library: run command success, failure exit code, and logging' {
    param($f)
    $main = Join-Path $f.Root 'seed-main-run'
    $wt = Join-Path $f.Root 'seed-wt-run'
    New-Item -ItemType Directory -Path $main, $wt -Force | Out-Null

    # Test success with default LogPath
    [IO.File]::WriteAllText((Join-Path $main 'trinity-seed.txt'), "run echo success-run-marker`r`n")
    $res = Invoke-WorktreeSeed -MainPath $main -WorktreePath $wt
    Assert-True ($res.ExitCode -eq 0) "Expected ExitCode 0, got $($res.ExitCode)"
    Assert-True ($res.Command -eq 'echo success-run-marker') "Unexpected command: $($res.Command)"
    $logFile = Join-Path $wt '.trinity-seed.log'
    Assert-True (Test-Path -LiteralPath $logFile) "Default log file was not created: $logFile"
    Assert-True ((Get-Content -Raw $logFile) -match 'success-run-marker') 'Log output did not contain marker'

    # Test custom LogPath and appending
    $customLog = Join-Path $wt 'logs\custom-seed.log'
    [IO.File]::WriteAllText((Join-Path $main 'trinity-seed.txt'), "run echo appended-marker`r`n")
    $resCustom = Invoke-WorktreeSeed -MainPath $main -WorktreePath $wt -LogPath $customLog
    Assert-True ($resCustom.ExitCode -eq 0) "Custom log run failed: $($resCustom.ExitCode)"
    Assert-True (Test-Path -LiteralPath $customLog) "Custom log file was not created: $customLog"
    Assert-True ((Get-Content -Raw $customLog) -match 'appended-marker') 'Custom log output missing marker'

    # Run again to verify append
    [IO.File]::WriteAllText((Join-Path $main 'trinity-seed.txt'), "run echo second-marker`r`n")
    $resAppend = Invoke-WorktreeSeed -MainPath $main -WorktreePath $wt -LogPath $customLog
    $logContent = Get-Content -Raw $customLog
    Assert-True ($logContent -match 'appended-marker' -and $logContent -match 'second-marker') 'Custom log was not appended'

    # Test non-zero exit code is returned in ExitCode, not thrown
    [IO.File]::WriteAllText((Join-Path $main 'trinity-seed.txt'), "run exit 17`r`n")
    $resFail = Invoke-WorktreeSeed -MainPath $main -WorktreePath $wt
    Assert-True ($resFail.ExitCode -eq 17) "Expected ExitCode 17, got $($resFail.ExitCode)"
}

Run-Case 'seed library: reject invalid paths traversal and .git' {
    param($f)
    $main = Join-Path $f.Root 'seed-main-sec'
    $wt = Join-Path $f.Root 'seed-wt-sec'
    New-Item -ItemType Directory -Path $main, $wt -Force | Out-Null

    # Traversal with ..
    [IO.File]::WriteAllText((Join-Path $main 'trinity-seed.txt'), "copy ../secret.txt`r`n")
    $threwDotDot = $false
    try { Invoke-WorktreeSeed -MainPath $main -WorktreePath $wt | Out-Null }
    catch { $threwDotDot = $_.Exception.Message -match '\.\.' }
    Assert-True $threwDotDot 'Did not reject path containing ..'

    # Absolute path
    [IO.File]::WriteAllText((Join-Path $main 'trinity-seed.txt'), "copy C:\Windows\win.ini`r`n")
    $threwAbs = $false
    try { Invoke-WorktreeSeed -MainPath $main -WorktreePath $wt | Out-Null }
    catch { $threwAbs = $_.Exception.Message -match 'Absolute' }
    Assert-True $threwAbs 'Did not reject absolute path'

    # Slash-prefixed absolute path
    [IO.File]::WriteAllText((Join-Path $main 'trinity-seed.txt'), "copy /etc/passwd`r`n")
    $threwSlash = $false
    try { Invoke-WorktreeSeed -MainPath $main -WorktreePath $wt | Out-Null }
    catch { $threwSlash = $_.Exception.Message -match 'Absolute' }
    Assert-True $threwSlash 'Did not reject slash-rooted path'

    # .git path
    [IO.File]::WriteAllText((Join-Path $main 'trinity-seed.txt'), "copy .git\config`r`n")
    $threwGit = $false
    try { Invoke-WorktreeSeed -MainPath $main -WorktreePath $wt | Out-Null }
    catch { $threwGit = $_.Exception.Message -match '\.git' }
    Assert-True $threwGit 'Did not reject .git path'
}

Run-Case 'seed library: unknown directive and multiple run throw with line number' {
    param($f)
    $main = Join-Path $f.Root 'seed-main-unknown'
    $wt = Join-Path $f.Root 'seed-wt-unknown'
    New-Item -ItemType Directory -Path $main, $wt -Force | Out-Null

    $configLines = @(
        '# Line 1: comment',
        '# Line 2: comment',
        'badcommand arg1 arg2'
    ) -join "`r`n"
    [IO.File]::WriteAllText((Join-Path $main 'trinity-seed.txt'), $configLines + "`r`n")

    $threwUnknown = $false
    $errMsg = ''
    try { Invoke-WorktreeSeed -MainPath $main -WorktreePath $wt | Out-Null }
    catch {
        $threwUnknown = $true
        $errMsg = $_.Exception.Message
    }
    Assert-True ($threwUnknown -and $errMsg -match ':3:' -and $errMsg -match 'badcommand') "Unknown directive did not throw with line number 3: $errMsg"

    # Multiple run directives
    $multiRun = @(
        'run echo first',
        'run echo second'
    ) -join "`r`n"
    [IO.File]::WriteAllText((Join-Path $main 'trinity-seed.txt'), $multiRun + "`r`n")

    $threwMulti = $false
    $multiMsg = ''
    try { Invoke-WorktreeSeed -MainPath $main -WorktreePath $wt | Out-Null }
    catch {
        $threwMulti = $true
        $multiMsg = $_.Exception.Message
    }
    Assert-True ($threwMulti -and $multiMsg -match ':2:' -and $multiMsg -match 'run') "Multiple run did not throw with line number 2: $multiMsg"
}

Run-Case 'seed library: paths with spaces' {
    param($f)
    $main = Join-Path $f.Root 'main folder with spaces'
    $wt = Join-Path $f.Root 'worktree folder with spaces'
    $subDir = Join-Path $main 'data folder with spaces'
    New-Item -ItemType Directory -Path $subDir, $wt -Force | Out-Null

    [IO.File]::WriteAllText((Join-Path $subDir 'sample file.txt'), "spaced content`r`n")

    $seedConfig = @(
        'copy data folder with spaces\sample file.txt',
        'run echo spaced-cmd-ok'
    ) -join "`r`n"
    [IO.File]::WriteAllText((Join-Path $main 'trinity-seed.txt'), $seedConfig + "`r`n")

    $res = Invoke-WorktreeSeed -MainPath $main -WorktreePath $wt
    Assert-True ($res.Copied.Count -eq 1) "Expected 1 copied, got $($res.Copied.Count)"
    Assert-True ($res.ExitCode -eq 0) "Run command failed: $($res.ExitCode)"

    $wtFile = Join-Path $wt 'data folder with spaces\sample file.txt'
    Assert-True (Test-Path -LiteralPath $wtFile) 'File with spaces was not copied'
    Assert-True ((Get-Content -Raw $wtFile) -match 'spaced content') 'File content mismatch'

    $logFile = Join-Path $wt '.trinity-seed.log'
    Assert-True (Test-Path -LiteralPath $logFile) 'Log file was not created in worktree with spaces'
    Assert-True ((Get-Content -Raw $logFile) -match 'spaced-cmd-ok') 'Log content mismatch'
}
