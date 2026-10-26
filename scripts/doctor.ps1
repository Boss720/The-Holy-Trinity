param([switch]$Json)

$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'lib\board.ps1')

$checks = New-Object System.Collections.Generic.List[object]
function Add-Check([string]$Name, [string]$Status, [string]$Detail, [string[]]$Fix = @()) {
    $checks.Add([pscustomobject]@{ name = $Name; status = $Status; detail = $Detail; fix = @($Fix) })
}
function Get-GitVersion {
    $command = Get-Command git -ErrorAction SilentlyContinue
    if (-not $command) { return $null }
    $text = (& git --version 2>$null | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $text -notmatch 'git version ([0-9]+)\.([0-9]+)(?:\.([0-9]+))?') { return $null }
    [pscustomobject]@{ Text = $Matches[1] + '.' + $Matches[2] + '.' + $(if ($Matches[3]) { $Matches[3] } else { '0' }); Major = [int]$Matches[1]; Minor = [int]$Matches[2] }
}
function Test-GitMinimum($Version) {
    return ($Version -and (($Version.Major -gt 2) -or ($Version.Major -eq 2 -and $Version.Minor -ge 31)))
}
function Get-AgentState([string]$Agent, $Availability, [bool]$SkipLogin) {
    $exe = switch ($Agent) { 'claude' { Find-ClaudeExe } 'codex' { Find-CodexExe } 'antigravity' { Find-AgyExe } }
    if (-not $exe) { return [pscustomobject]@{ Available = $false; Detail = 'not installed'; Exe = $null } }
    $disabled = @("$env:TRINITY_DISABLE" -split '[,; ]+' | Where-Object { $_ } | ForEach-Object { $_.Trim().ToLowerInvariant() })
    if ($disabled -contains $Agent) { return [pscustomobject]@{ Available = $false; Detail = 'disabled by TRINITY_DISABLE'; Exe = $exe } }
    if ($SkipLogin) { return [pscustomobject]@{ Available = $true; Detail = 'login not checked'; Exe = $exe } }
    $state = $Availability[$Agent]
    [pscustomobject]@{ Available = [bool]$state.available; Detail = [string]$state.detail; Exe = $exe }
}
function Get-AgentFix([string]$Agent, [bool]$Installed) {
    if ($Agent -eq 'claude') {
        if (-not $Installed) { return @('powershell -NoProfile -ExecutionPolicy Bypass -c "irm https://claude.ai/install.ps1 | iex"') }
        return @('claude auth login')
    }
    if ($Agent -eq 'codex') {
        if (-not $Installed) { return @('powershell -ExecutionPolicy ByPass -c "irm https://chatgpt.com/codex/install.ps1 | iex"') }
        return @('codex login')
    }
    if (-not $Installed) { return @('powershell -NoProfile -ExecutionPolicy Bypass -c "irm https://antigravity.google/cli/install.ps1 | iex"') }
    return @('agy')
}

$windowsOk = ([Environment]::OSVersion.Version.Major -ge 10)
Add-Check 'windows' $(if ($windowsOk) { 'ok' } else { 'fail' }) $(if ($windowsOk) { 'Windows 10 or 11' } else { 'Windows 10 or 11 is required' })
$psOk = (($PSVersionTable.PSVersion.Major -gt 5) -or ($PSVersionTable.PSVersion.Major -eq 5 -and $PSVersionTable.PSVersion.Minor -ge 1))
Add-Check 'powershell' $(if ($psOk) { 'ok' } else { 'fail' }) $(if ($psOk) { "PowerShell $($PSVersionTable.PSVersion)" } else { "PowerShell $($PSVersionTable.PSVersion); 5.1 or later is required" })

$git = Get-GitVersion
$gitOk = Test-GitMinimum $git
$gitFix = @()
if (-not $gitOk) { $gitFix = @('winget install --id Git.Git -e --source winget --silent --accept-package-agreements --accept-source-agreements', 'https://git-scm.com/download/win') }
Add-Check 'git' $(if ($gitOk) { 'ok' } else { 'fail' }) $(if ($gitOk) { "$($git.Text) (needs 2.31+)" } elseif ($git) { "$($git.Text) is too old (needs 2.31+)" } else { 'not installed or git --version failed' }) $gitFix

$userName = (& git config --get user.name 2>$null | Out-String).Trim()
$nameRc = $LASTEXITCODE
$userEmail = (& git config --get user.email 2>$null | Out-String).Trim()
$emailRc = $LASTEXITCODE
$identityOk = ($gitOk -and $nameRc -eq 0 -and $userName -and $emailRc -eq 0 -and $userEmail)
$identityFix = @()
if (-not $identityOk) { $identityFix = @('git config --global user.name "Your Name"', 'git config --global user.email "you@example.com"') }
Add-Check 'git-identity' $(if ($identityOk) { 'ok' } else { 'fail' }) $(if ($identityOk) { "$userName <$userEmail>" } else { 'user.name / user.email not set' }) $identityFix

$bashPath = $null
$gitCommand = Get-Command git -ErrorAction SilentlyContinue
if ($gitCommand) {
    $gitDir = Split-Path -Parent $gitCommand.Source
    $gitRoot = Split-Path -Parent $gitDir
    if ((Split-Path -Leaf $gitDir) -eq 'bin' -and (Split-Path -Leaf $gitRoot) -eq 'mingw64') { $gitRoot = Split-Path -Parent $gitRoot }
    foreach ($candidate in @((Join-Path $gitDir '..\bin\bash.exe'), (Join-Path $gitDir '..\usr\bin\bash.exe'), (Join-Path $gitRoot 'bin\bash.exe'), (Join-Path $gitRoot 'usr\bin\bash.exe'))) {
        if (Test-Path -LiteralPath $candidate) { $bashPath = (Resolve-Path -LiteralPath $candidate).Path; break }
    }
}
Add-Check 'git-bash' 'info' $(if ($bashPath) { $bashPath } else { 'not found; needed only for trinity.sh' })

$skipLogin = ($env:TRINITY_DOCTOR_SKIP_LOGIN -eq '1')
$availability = $null
if (-not $skipLogin) { $availability = Get-AgentAvailability @('claude', 'codex', 'antigravity') }
$agents = [ordered]@{}
foreach ($agent in @('claude', 'codex', 'antigravity')) {
    $state = Get-AgentState $agent $availability $skipLogin
    $agents[$agent] = $state
    $status = if ($state.Available) { 'ok' } else { 'warn' }
    $fix = @()
    if (-not $state.Available) { $fix = Get-AgentFix $agent ([bool]$state.Exe) }
    Add-Check $agent $status $state.Detail $fix
}
$workerAvailable = ($agents.codex.Available -or $agents.antigravity.Available)
$workerFix = @()
if (-not $workerAvailable) { $workerFix = @('Install and log in to Codex or run agy once interactively') }
Add-Check 'workers' $(if ($workerAvailable) { 'ok' } else { 'warn' }) $(if ($workerAvailable) { 'codex or antigravity is available' } else { 'no headless worker; trinity dispatch will not run' }) $workerFix

$pathCommand = Get-Command trinity.cmd -ErrorAction SilentlyContinue
$pathOk = $false
if ($pathCommand) {
    $resolvedCommand = [IO.Path]::GetFullPath($pathCommand.Source)
    $expectedCommand = [IO.Path]::GetFullPath((Join-Path $root 'trinity.cmd'))
    $pathOk = [string]::Equals($resolvedCommand.TrimEnd('\'), $expectedCommand.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)
}
$pathFix = @()
if ($pathOk) { Add-Check 'path' 'ok' 'trinity.cmd resolves to this toolkit folder' }
elseif (Test-Path -LiteralPath (Join-Path $root 'install.cmd')) {
    Add-Check 'path' 'warn' 'trinity.cmd does not resolve to this toolkit folder' @("`"$(Join-Path $root 'install.cmd')`" -AddToPath")
}
else { Add-Check 'path' 'info' 'this is a project copy; run it as .\trinity.cmd from the project folder' }

$repoRoot = (& git rev-parse --show-toplevel 2>$null | Out-String).Trim()
$repoRc = $LASTEXITCODE
if ($repoRc -eq 0 -and $repoRoot) {
    $hooks = (& git config --get core.hooksPath 2>$null | Out-String).Trim()
    $hasTrinity = Test-Path -LiteralPath (Join-Path $repoRoot 'scripts\trinity.ps1')
    $repoOk = ($hooks -eq '.githooks' -and $hasTrinity)
    $repoFix = @()
    if (-not $repoOk) { $repoFix = @('trinity setup', "trinity init `"$repoRoot`"") }
    Add-Check 'repo' $(if ($repoOk) { 'ok' } else { 'warn' }) $(if ($repoOk) { "hooks=$hooks; scripts\trinity.ps1 exists" } else { 'core.hooksPath is not .githooks or scripts\trinity.ps1 is missing' }) $repoFix
}

try {
    $driveRoot = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($root))
    $drive = New-Object IO.DriveInfo($driveRoot)
    $freeGB = [math]::Round($drive.AvailableFreeSpace / 1GB, 1)
    $diskStatus = if ($drive.AvailableFreeSpace -lt 5GB) { 'warn' } else { 'ok' }
    Add-Check 'disk' $diskStatus "$freeGB GB free on $driveRoot" $(if ($diskStatus -eq 'warn') { @('Free at least 5 GB on the toolkit drive') } else { @() })
}
catch { Add-Check 'disk' 'info' 'free space could not be read' }

$versionFile = Join-Path $root 'VERSION'
$version = if (Test-Path -LiteralPath $versionFile) { ([IO.File]::ReadAllText($versionFile)).Trim() } else { 'unknown' }
Add-Check 'version' 'info' "trinity $version at $root"

$okCount = @($checks | Where-Object { $_.status -eq 'ok' }).Count
$warnCount = @($checks | Where-Object { $_.status -eq 'warn' }).Count
$failCount = @($checks | Where-Object { $_.status -eq 'fail' }).Count
if ($Json) {
    [pscustomobject]@{ version = $version; root = $root; checks = $checks.ToArray(); ok = $okCount; warn = $warnCount; fail = $failCount } | ConvertTo-Json -Depth 6 -Compress
}
else {
    foreach ($check in $checks) {
        $label = switch ($check.status) { 'ok' { ' OK ' } default { $check.status.ToUpperInvariant() } }
        Write-Output (('[{0}] {1,-14} {2}' -f $label, $check.name, $check.detail))
        foreach ($line in $check.fix) { Write-Output "       fix: $line" }
    }
    Write-Output "doctor: $okCount ok, $warnCount warnings, $failCount failures"
}
if ($failCount -gt 0) { exit 1 }
exit 0
