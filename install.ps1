$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$versionFile = Join-Path $root 'VERSION'
$version = if (Test-Path -LiteralPath $versionFile) { ([IO.File]::ReadAllText($versionFile)).Trim() } else { 'unknown' }
. (Join-Path $root 'scripts\lib\board.ps1')

function Show-Usage {
    Write-Output 'trinity installer options:'
    Write-Output '  -Check          run doctor only; change nothing'
    Write-Output '  -InstallGit     install Git for Windows when missing or older than 2.31'
    Write-Output '  -InstallClaude  install Claude Code with its official PowerShell installer'
    Write-Output '  -AddToPath      add this toolkit folder to the User PATH'
    Write-Output '  -RemoveFromPath remove this toolkit folder from the User PATH'
    Write-Output '  -Init <path>    initialize a git repository after successful checks'
    Write-Output '  -Yes            skip confirmation prompts'
    Write-Output '  -Help           show this help'
}
function Confirm-Step([string]$Question, [bool]$AssumeYes) {
    if ($AssumeYes) { return $true }
    $answer = Read-Host "$Question [y/N]"
    return ($answer -match '^(y|yes)$')
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
function Get-DoctorResult {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'scripts\doctor.ps1') | ForEach-Object { Write-Host "$_" }
    return $LASTEXITCODE
}
# The User PATH is read and written raw in the registry. [Environment]::SetEnvironmentVariable would store the
# expanded text as REG_SZ and freeze every %VAR% entry. TRINITY_USER_ENV_KEY points these functions at a
# throwaway key (self-test only).
function Get-UserEnvKeyName {
    if ($env:TRINITY_USER_ENV_KEY) { return $env:TRINITY_USER_ENV_KEY }
    return 'Environment'
}
function Get-UserPathRaw {
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey((Get-UserEnvKeyName))
    if (-not $key) { return '' }
    try { return [string]$key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) }
    finally { $key.Close() }
}
function Set-UserPathRaw([string]$Value) {
    $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey((Get-UserEnvKeyName))
    try { $key.SetValue('Path', $Value, [Microsoft.Win32.RegistryValueKind]::ExpandString) }
    finally { $key.Close() }
    if (-not $env:TRINITY_USER_ENV_KEY) {
        # Setting and clearing a user variable makes Windows tell running programs that the environment changed.
        [Environment]::SetEnvironmentVariable('TRINITY_PATH_REFRESH', '1', 'User')
        [Environment]::SetEnvironmentVariable('TRINITY_PATH_REFRESH', $null, 'User')
    }
}
function Get-PathKey([string]$Entry) {
    $text = [Environment]::ExpandEnvironmentVariables($Entry.Trim())
    try { $text = [IO.Path]::GetFullPath($text) } catch { }
    return $text.TrimEnd('\')
}
function Test-PathEntry([string]$Entry, [string]$Target) {
    return [string]::Equals((Get-PathKey $Entry), $Target, [StringComparison]::OrdinalIgnoreCase)
}
# Messages use Write-Host: anything written to the output stream would become part of the function's return value.
function Update-UserPath([bool]$Add) {
    $raw = Get-UserPathRaw
    $parts = @($raw -split ';' | Where-Object { $_.Trim() })
    $target = [IO.Path]::GetFullPath($root).TrimEnd('\')
    $found = (@($parts | Where-Object { Test-PathEntry $_ $target }).Count -gt 0)
    if ($Add -and $found) { Write-Host 'User PATH already contains this toolkit folder; left it unchanged.'; return $true }
    if (-not $Add -and -not $found) { Write-Host 'User PATH does not contain this toolkit folder; left it unchanged.'; return $true }
    if ($Add) { $newParts = @($parts) + $target }
    else { $newParts = @($parts | Where-Object { -not (Test-PathEntry $_ $target) }) }
    try {
        $backup = Join-Path (Get-TrinityHome) 'user-path-backup.txt'
        New-Item -ItemType Directory -Path (Split-Path -Parent $backup) -Force | Out-Null
        [IO.File]::WriteAllText($backup, $raw, (New-Object Text.UTF8Encoding($false)))
        Set-UserPathRaw ($newParts -join ';')
        $current = @($env:Path -split ';' | Where-Object { $_ })
        if ($Add) {
            if (-not (@($current | Where-Object { Test-PathEntry $_ $target }).Count -gt 0)) { $current += $target }
        }
        else { $current = @($current | Where-Object { -not (Test-PathEntry $_ $target) }) }
        $env:Path = $current -join ';'
        Write-Host $(if ($Add) { "Added $target to User PATH." } else { "Removed $target from User PATH." })
        Write-Host "Previous User PATH saved to $backup."
        Write-Host 'Open a new terminal for the User PATH change to apply there.'
        return $true
    }
    catch { Write-Host "Could not update User PATH: $($_.Exception.Message)"; return $false }
}

$checkOnly = $false
$installGit = $false
$installClaude = $false
$addToPath = $false
$removeFromPath = $false
$assumeYes = $false
$showHelp = $false
$initPath = $null
$parseError = $null
for ($i = 0; $i -lt $args.Count; $i++) {
    switch -Regex ($args[$i]) {
        '^(?i)-Check$' { $checkOnly = $true; break }
        '^(?i)-InstallGit$' { $installGit = $true; break }
        '^(?i)-InstallClaude$' { $installClaude = $true; break }
        '^(?i)-AddToPath$' { $addToPath = $true; break }
        '^(?i)-RemoveFromPath$' { $removeFromPath = $true; break }
        '^(?i)-Yes$' { $assumeYes = $true; break }
        '^(?i)-Help$|^(?i)-h$|^(?i)/\?$' { $showHelp = $true; break }
        '^(?i)-Init$' {
            if ($i + 1 -ge $args.Count -or $args[$i + 1] -match '^-[A-Za-z]') { $parseError = '-Init requires a path'; break }
            $i++
            $initPath = $args[$i]
            break
        }
        default { $parseError = "unknown option: $($args[$i])"; break }
    }
    if ($parseError) { break }
}
if ($parseError) { Write-Output $parseError; Show-Usage; exit 2 }
if ($showHelp) { Show-Usage; exit 0 }
if ($addToPath -and $removeFromPath) { Write-Output 'Choose either -AddToPath or -RemoveFromPath.'; Show-Usage; exit 2 }
if ($checkOnly -and ($installGit -or $installClaude -or $addToPath -or $removeFromPath -or $initPath)) { Write-Output '-Check cannot be combined with changing options.'; Show-Usage; exit 2 }

if ($checkOnly) { $doctorCode = Get-DoctorResult; exit $doctorCode }
Write-Output "trinity $version installer"

if ($installGit) {
    $currentGit = Get-GitVersion
    if (Test-GitMinimum $currentGit) { Write-Output "Git $($currentGit.Text) is already installed; left it unchanged." }
    else {
        $winget = Get-Command winget -ErrorAction SilentlyContinue
        if (-not $winget) {
            Write-Output 'winget is not available. Download Git for Windows: https://git-scm.com/download/win'
            exit 1
        }
        if (-not (Confirm-Step 'Install Git for Windows using winget?' $assumeYes)) { Write-Output 'Git installation cancelled; left the system unchanged.'; exit 1 }
        Write-Output 'Running: winget install --id Git.Git -e --source winget --silent --accept-package-agreements --accept-source-agreements'
        & winget install --id Git.Git -e --source winget --silent --accept-package-agreements --accept-source-agreements
        if ($LASTEXITCODE -ne 0) { Write-Output "winget failed with exit code $LASTEXITCODE"; exit 1 }
        $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
        $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
        $env:Path = @($machinePath, $userPath | Where-Object { $_ }) -join ';'
        $currentGit = Get-GitVersion
        if (-not (Test-GitMinimum $currentGit)) { Write-Output 'Git is still missing or older than 2.31 after winget completed.'; exit 1 }
        Write-Output "Git $($currentGit.Text) is ready in this process."
    }
}

if ($installClaude) {
    $claudeExe = Find-ClaudeExe
    if ($claudeExe) { Write-Output "Claude Code is already installed at $claudeExe; left it unchanged." }
    else {
        if (-not (Confirm-Step 'Install Claude Code using the official Anthropic installer?' $assumeYes)) { Write-Output 'Claude Code installation cancelled; left it unchanged.'; exit 1 }
        $psCommand = 'irm https://claude.ai/install.ps1 | iex'
        Write-Output 'Running: powershell -NoProfile -ExecutionPolicy Bypass -c "irm https://claude.ai/install.ps1 | iex"'
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -Command $psCommand
        if ($LASTEXITCODE -ne 0) { Write-Output "Claude Code installer failed with exit code $LASTEXITCODE"; exit 1 }
        Write-Output 'Claude Code installer completed. Run claude auth login yourself to sign in.'
    }
}

if ($addToPath -and -not (Update-UserPath $true)) { exit 1 }
if ($removeFromPath -and -not (Update-UserPath $false)) { exit 1 }

Get-ChildItem -LiteralPath $root -File -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
    try { Unblock-File -LiteralPath $_.FullName -ErrorAction SilentlyContinue } catch { }
}
Write-Output 'Checked toolkit files for Mark-of-the-Web and cleared it where present; no other files or settings were changed.'
$doctorCode = Get-DoctorResult
if ($doctorCode -ne 0) { Write-Output "doctor reported failures (exit $doctorCode)." }
else { Write-Output 'doctor found no failures.' }

Write-Output 'Next steps:'
if ($doctorCode -ne 0) { Write-Output '  Follow the fix lines above, then run install.cmd again.' }
if (-not $installGit -and -not (Test-GitMinimum (Get-GitVersion))) { Write-Output '  install.cmd -InstallGit' }
if (-not (Get-Command trinity.cmd -ErrorAction SilentlyContinue)) { Write-Output '  install.cmd -AddToPath' }
if ($initPath) {
    if ($doctorCode -ne 0) { Write-Output '-Init refused because doctor reported a failure.'; exit 1 }
    $trinity = Join-Path $root 'scripts\trinity.ps1'
    Write-Output "Running: trinity init `"$initPath`""
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $trinity init $initPath
    if ($LASTEXITCODE -ne 0) { Write-Output "trinity init failed with exit code $LASTEXITCODE"; exit 1 }
}
Write-Output '  trinity init <your-project-folder>'
exit $doctorCode
