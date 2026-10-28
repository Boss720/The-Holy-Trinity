# Worktree seeding library for Holy Trinity.
# Dot-source this file to use Invoke-WorktreeSeed.

function Assert-ValidSeedPath([string]$Path, [string]$MainPath, [string]$WorktreePath) {
    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "Path cannot be empty"
    }
    if ($Path.Contains('..')) {
        throw "Path contains '..' traversal: '$Path'"
    }
    if ([System.IO.Path]::IsPathRooted($Path) -or $Path -match '^[a-zA-Z]:' -or $Path.StartsWith('\') -or $Path.StartsWith('/')) {
        throw "Absolute path is not allowed: '$Path'"
    }
    $segments = ($Path -replace '\\', '/') -split '/'
    if ($segments -contains '.git' -or $Path -match '(?i)(^|[\\/])\.git([\\/]|\*|$)') {
        throw "Cannot copy into or out of .git: '$Path'"
    }

    $normalized = $Path -replace '/', '\'
    $dummy = $normalized -replace '[\*\?]', 'x'
    $resolvedSource = [System.IO.Path]::GetFullPath((Join-Path $MainPath $dummy))
    $resolvedDest = [System.IO.Path]::GetFullPath((Join-Path $WorktreePath $dummy))
    $mainPrefix = $MainPath.TrimEnd('\') + '\'
    $wtPrefix = $WorktreePath.TrimEnd('\') + '\'

    if (-not ($resolvedSource.StartsWith($mainPrefix, [System.StringComparison]::OrdinalIgnoreCase) -or $resolvedSource -eq $MainPath.TrimEnd('\'))) {
        throw "Path resolves outside MainPath: '$Path'"
    }
    if (-not ($resolvedDest.StartsWith($wtPrefix, [System.StringComparison]::OrdinalIgnoreCase) -or $resolvedDest -eq $WorktreePath.TrimEnd('\'))) {
        throw "Path resolves outside WorktreePath: '$Path'"
    }
}

function Get-SeedRelativePath([string]$BasePath, [string]$FullPath) {
    $base = [System.IO.Path]::GetFullPath($BasePath).TrimEnd('\', '/') + '\'
    $full = [System.IO.Path]::GetFullPath($FullPath)
    if ($full.StartsWith($base, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $full.Substring($base.Length)
    }
    return $full
}

function Copy-SingleSeedFile {
    param(
        [string]$SourceFile,
        [string]$RelativePath,
        [string]$WorktreeRoot,
        [System.Collections.Generic.List[string]]$CopiedList,
        [System.Collections.Generic.List[string]]$SkippedList
    )
    $segs = ($RelativePath -replace '\\', '/') -split '/'
    if ($segs -contains '.git') {
        return
    }

    $destPath = Join-Path $WorktreeRoot $RelativePath
    if (Test-Path -LiteralPath $destPath) {
        $SkippedList.Add("$RelativePath`: exists")
        Write-Verbose "Skipped (exists): $RelativePath"
        return
    }

    $destDir = Split-Path $destPath -Parent
    if ($destDir -and -not (Test-Path -LiteralPath $destDir)) {
        [void][System.IO.Directory]::CreateDirectory($destDir)
    }

    Copy-Item -LiteralPath $SourceFile -Destination $destPath
    $CopiedList.Add($RelativePath)
    Write-Verbose "Copied: $RelativePath"
}

function Invoke-WorktreeSeed {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$MainPath,

        [Parameter(Mandatory = $true)]
        [string]$WorktreePath,

        [Parameter(Mandatory = $false)]
        [string]$LogPath
    )

    $mainResolved = [System.IO.Path]::GetFullPath($MainPath).TrimEnd('\', '/')
    $worktreeResolved = [System.IO.Path]::GetFullPath($WorktreePath).TrimEnd('\', '/')

    if (-not (Test-Path -LiteralPath $mainResolved)) {
        throw "MainPath does not exist: '$MainPath'"
    }
    if (-not (Test-Path -LiteralPath $worktreeResolved)) {
        [void][System.IO.Directory]::CreateDirectory($worktreeResolved)
    }

    $resolvedLogPath = if ($LogPath) {
        if ([System.IO.Path]::IsPathRooted($LogPath)) {
            [System.IO.Path]::GetFullPath($LogPath)
        } else {
            [System.IO.Path]::GetFullPath((Join-Path $worktreeResolved $LogPath))
        }
    } else {
        Join-Path $worktreeResolved '.trinity-seed.log'
    }

    $configFile = Join-Path $mainResolved 'trinity-seed.txt'
    if (-not (Test-Path -LiteralPath $configFile)) {
        Write-Verbose "No trinity-seed.txt found in $mainResolved; no-op"
        return [pscustomobject]@{
            Copied   = [string[]]@()
            Skipped  = [string[]]@()
            Command  = $null
            ExitCode = $null
            LogPath  = $resolvedLogPath
        }
    }

    $lines = [System.IO.File]::ReadAllLines($configFile, [System.Text.Encoding]::UTF8)
    $copyDirectives = New-Object System.Collections.Generic.List[object]
    $runDirective = $null

    for ($i = 0; $i -lt $lines.Length; $i++) {
        $lineNum = $i + 1
        $raw = $lines[$i]
        $trimmed = $raw.Trim()

        if ($trimmed -eq '' -or $trimmed.StartsWith('#')) {
            continue
        }

        if ($trimmed -match '^(?i)copy(\s+(.*))?$') {
            $pathArg = if ($Matches.Count -gt 2 -and $Matches[2]) { $Matches[2].Trim() } else { '' }
            if ($pathArg -eq '') {
                throw "trinity-seed.txt:$lineNum`: 'copy' requires a path"
            }
            if (($pathArg.StartsWith('"') -and $pathArg.EndsWith('"')) -or ($pathArg.StartsWith("'") -and $pathArg.EndsWith("'"))) {
                $pathArg = $pathArg.Substring(1, $pathArg.Length - 2).Trim()
            }
            try {
                Assert-ValidSeedPath $pathArg $mainResolved $worktreeResolved
            } catch {
                throw "trinity-seed.txt:$lineNum`: $($_.Exception.Message)"
            }
            $copyDirectives.Add([pscustomobject]@{ Path = $pathArg; Line = $lineNum })
        } elseif ($trimmed -match '^(?i)run(\s+(.*))?$') {
            $cmdArg = if ($Matches.Count -gt 2 -and $Matches[2]) { $Matches[2].Trim() } else { '' }
            if ($cmdArg -eq '') {
                throw "trinity-seed.txt:$lineNum`: 'run' requires a command"
            }
            if ($null -ne $runDirective) {
                throw "trinity-seed.txt:$lineNum`: at most one 'run' directive is allowed (first was at line $($runDirective.Line))"
            }
            $runDirective = [pscustomobject]@{ Command = $cmdArg; Line = $lineNum }
        } else {
            $directiveName = ($trimmed -split '\s+')[0]
            throw "trinity-seed.txt:$lineNum`: unknown directive '$directiveName'"
        }
    }

    $copied = New-Object System.Collections.Generic.List[string]
    $skipped = New-Object System.Collections.Generic.List[string]

    foreach ($cd in $copyDirectives) {
        $path = $cd.Path
        $hasWildcard = $path.Contains('*') -or $path.Contains('?')
        if ($hasWildcard) {
            $sourcePattern = Join-Path $mainResolved $path
            $matched = @(Get-ChildItem -Path $sourcePattern -Force -ErrorAction SilentlyContinue)
            if ($matched.Count -eq 0) {
                $skipped.Add("$path`: missing")
                Write-Verbose "Skipped (missing): $path"
            } else {
                foreach ($item in $matched) {
                    if ($item.Name -eq '.git' -or ($item.FullName -replace '\\', '/' -split '/' -contains '.git')) {
                        continue
                    }
                    if ($item.PSIsContainer) {
                        $subFiles = @(Get-ChildItem -LiteralPath $item.FullName -Recurse -File -Force -ErrorAction SilentlyContinue)
                        foreach ($subFile in $subFiles) {
                            $rel = Get-SeedRelativePath $mainResolved $subFile.FullName
                            Copy-SingleSeedFile -SourceFile $subFile.FullName -RelativePath $rel -WorktreeRoot $worktreeResolved -CopiedList $copied -SkippedList $skipped
                        }
                    } else {
                        $rel = Get-SeedRelativePath $mainResolved $item.FullName
                        Copy-SingleSeedFile -SourceFile $item.FullName -RelativePath $rel -WorktreeRoot $worktreeResolved -CopiedList $copied -SkippedList $skipped
                    }
                }
            }
        } else {
            $sourceFullPath = Join-Path $mainResolved $path
            if (-not (Test-Path -LiteralPath $sourceFullPath)) {
                $skipped.Add("$path`: missing")
                Write-Verbose "Skipped (missing): $path"
            } elseif (Test-Path -LiteralPath $sourceFullPath -PathType Container) {
                $subFiles = @(Get-ChildItem -LiteralPath $sourceFullPath -Recurse -File -Force -ErrorAction SilentlyContinue)
                if ($subFiles.Count -eq 0) {
                    Write-Verbose "Empty directory: $path"
                } else {
                    foreach ($subFile in $subFiles) {
                        $rel = Get-SeedRelativePath $mainResolved $subFile.FullName
                        Copy-SingleSeedFile -SourceFile $subFile.FullName -RelativePath $rel -WorktreeRoot $worktreeResolved -CopiedList $copied -SkippedList $skipped
                    }
                }
            } else {
                $rel = Get-SeedRelativePath $mainResolved $sourceFullPath
                Copy-SingleSeedFile -SourceFile $sourceFullPath -RelativePath $rel -WorktreeRoot $worktreeResolved -CopiedList $copied -SkippedList $skipped
            }
        }
    }

    $commandResult = $null
    $exitCodeResult = $null

    if ($null -ne $runDirective) {
        $commandResult = $runDirective.Command
        Write-Verbose "Running seed command: $commandResult"

        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = 'cmd.exe'
        $psi.Arguments = "/d /c $commandResult"
        $psi.WorkingDirectory = $worktreeResolved
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true

        $proc = [System.Diagnostics.Process]::Start($psi)
        $outTask = $proc.StandardOutput.ReadToEndAsync()
        $errTask = $proc.StandardError.ReadToEndAsync()
        $proc.WaitForExit()
        [System.Threading.Tasks.Task]::WaitAll($outTask, $errTask)
        $exitCodeResult = [int]$proc.ExitCode
        $proc.Dispose()

        $logDir = Split-Path $resolvedLogPath -Parent
        if ($logDir -and -not (Test-Path -LiteralPath $logDir)) {
            [void][System.IO.Directory]::CreateDirectory($logDir)
        }

        $logOutput = $outTask.Result + $errTask.Result
        [System.IO.File]::AppendAllText($resolvedLogPath, $logOutput, [System.Text.Encoding]::UTF8)
    }

    return [pscustomobject]@{
        Copied   = [string[]]$copied.ToArray()
        Skipped  = [string[]]$skipped.ToArray()
        Command  = $commandResult
        ExitCode = $exitCodeResult
        LogPath  = $resolvedLogPath
    }
}
