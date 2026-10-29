param(
    [string]$OutDir = (Join-Path (Split-Path -Parent $PSScriptRoot) 'dist'),
    [switch]$Verify,
    [string]$Version
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if (-not $Version) { $Version = [IO.File]::ReadAllText((Join-Path $root 'VERSION')).Trim() }
if ($Version -notmatch '^\d+\.\d+\.\d+$') { throw "invalid version: $Version" }
$tag = "trinity-v$Version"
$zipPath = Join-Path $OutDir "$tag.zip"
$hashPath = "$zipPath.sha256"
$notesPath = Join-Path $OutDir 'RELEASE_NOTES.md'
$fixed = @(
    'VERSION', 'README.md', 'INSTALL.md', 'CHANGELOG.md', 'AGENTS.md', 'CLAUDE.md', 'GEMINI.md',
    'trinity.cmd', 'trinity.sh', 'install.cmd', 'install.ps1', '.agent/rules/holy-trinity.md',
    '.claude/settings.json', '.claude/skills/army/SKILL.md', '.agents/skills/trinity/SKILL.md', '.githooks/pre-commit',
    'scripts/agent-task.ps1', 'scripts/codex.cmd', 'scripts/codex-ask.cmd', 'scripts/codex-review.cmd',
    'scripts/dashboard.ps1', 'scripts/dashboard.html', 'scripts/dashboard-sample.json', 'scripts/doctor.ps1', 'scripts/trinity.ps1',
    'scripts/scheduler.ps1', 'scripts/lib/config.ps1', 'scripts/lib/scheduler.ps1',
    'scripts/dashboard-ui/board.css', 'scripts/dashboard-ui/board.js', 'scripts/dashboard-ui/history.js',
    'scripts/lib/board.ps1', 'scripts/lib/seed.ps1', 'docs/dashboard.md', 'docs/claude-install-prompt.md'
)
$paths = New-Object 'System.Collections.Generic.List[string]'
foreach ($rel in $fixed) {
    $native = $rel.Replace('/', [IO.Path]::DirectorySeparatorChar)
    $full = Join-Path $root $native
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { throw "missing allowlisted path: $rel" }
    $paths.Add($rel)
}
$agentsDir = Join-Path $root '.claude/agents'
if (-not (Test-Path -LiteralPath $agentsDir -PathType Container)) { throw 'missing allowlisted path: .claude/agents/*.md' }
$agentFiles = @(Get-ChildItem -LiteralPath $agentsDir -Filter '*.md' -File | Sort-Object Name)
if ($agentFiles.Count -eq 0) { throw 'missing allowlisted path: .claude/agents/*.md' }
foreach ($file in $agentFiles) { $paths.Add('.claude/agents/' + $file.Name) }
$testsDir = Join-Path $root 'tests'
if (-not (Test-Path -LiteralPath $testsDir -PathType Container)) { throw 'missing allowlisted path: tests/*' }
foreach ($file in @(Get-ChildItem -LiteralPath $testsDir -File -Recurse | Sort-Object FullName)) {
    $paths.Add($file.FullName.Substring($root.Length + 1).Replace('\', '/'))
}

if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
$OutDir = (Resolve-Path -LiteralPath $OutDir).Path
$stage = Join-Path $OutDir ('.stage-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stage -Force | Out-Null
try {
    foreach ($rel in $paths) {
        $source = Join-Path $root $rel.Replace('/', [IO.Path]::DirectorySeparatorChar)
        $dest = Join-Path $stage $rel.Replace('/', [IO.Path]::DirectorySeparatorChar)
        $parent = Split-Path -Parent $dest
        if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        Copy-Item -LiteralPath $source -Destination $dest
    }

    foreach ($rel in $paths) {
        $file = Join-Path $stage $rel.Replace('/', [IO.Path]::DirectorySeparatorChar)
        $bytes = [IO.File]::ReadAllBytes($file)
        if ($bytes.Length -ge 1048576) { throw "lint: $rel is 1 MB or larger" }
        $ascii = [Text.Encoding]::ASCII.GetString($bytes)
        if ($ascii.Contains('C:\Users\') -or $ascii.Contains('D:\AI')) { throw "lint: path leak in $rel" }
        if ($rel -match '\.ps1$') {
            if ($bytes.Length -lt 3 -or $bytes[0] -ne 239 -or $bytes[1] -ne 187 -or $bytes[2] -ne 191) { throw "lint: $rel missing UTF-8 BOM" }
            for ($i = 3; $i -lt $bytes.Length; $i++) { if ($bytes[$i] -gt 127) { throw "lint: $rel has non-ASCII characters after BOM" } }
            $text = [Text.Encoding]::ASCII.GetString($bytes, 3, $bytes.Length - 3)
            if ($text -match '(?<!\r)\n|\r(?!\n)') { throw "lint: $rel must use CRLF" }
            $parseErrors = $null
            [System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$null, [ref]$parseErrors) | Out-Null
            if ($parseErrors.Count -gt 0) { throw "lint: $rel has PowerShell parse errors: $($parseErrors[0].Message)" }
        }
        if ($rel -match '\.cmd$') {
            $text = [Text.Encoding]::ASCII.GetString($bytes)
            if ($text -match '(?<!\r)\n|\r(?!\n)') { throw "lint: $rel must use CRLF" }
        }
        if ($rel -eq '.githooks/pre-commit' -or $rel -eq 'trinity.sh') {
            $text = [Text.Encoding]::ASCII.GetString($bytes)
            if ($text.Contains("`r`n")) { throw "lint: $rel must use LF" }
        }
    }

    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
    $stream = [IO.File]::Open($zipPath, [IO.FileMode]::CreateNew)
    try {
        $archive = New-Object IO.Compression.ZipArchive($stream, [IO.Compression.ZipArchiveMode]::Create, $false)
        try {
            foreach ($rel in $paths) {
                $entryName = "$tag/" + $rel
                $entry = $archive.CreateEntry($entryName, [IO.Compression.CompressionLevel]::Optimal)
                $entryStream = $entry.Open()
                try {
                    $source = [IO.File]::OpenRead((Join-Path $stage $rel.Replace('/', [IO.Path]::DirectorySeparatorChar)))
                    try { $source.CopyTo($entryStream) } finally { $source.Dispose() }
                } finally { $entryStream.Dispose() }
            }
        } finally { $archive.Dispose() }
    } finally { $stream.Dispose() }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $hash = [BitConverter]::ToString($sha.ComputeHash([IO.File]::ReadAllBytes($zipPath))).Replace('-', '').ToLowerInvariant() } finally { $sha.Dispose() }
    [IO.File]::WriteAllText($hashPath, "$hash  $tag.zip`n", (New-Object Text.UTF8Encoding($false)))

    $change = [IO.File]::ReadAllText((Join-Path $root 'CHANGELOG.md'))
    $section = [regex]::Match($change, '(?ms)^## v' + [regex]::Escape($Version) + '(?:[ \t]+-[^\r\n]*)?\s*\r?\n(.*?)(?=^## |\z)')
    if (-not $section.Success) { $section = [regex]::Match($change, '(?ms)^## Unreleased\s*\r?\n(.*?)(?=^## |\z)') }
    if (-not $section.Success) { throw "CHANGELOG.md has no '## v$Version' or '## Unreleased' section" }
    $body = $section.Groups[1].Value.Trim()
    $notes = $body + "`r`n`r`nDownload $tag.zip, extract it, run install.cmd. See INSTALL.md.`r`n"
    [IO.File]::WriteAllText($notesPath, $notes, (New-Object Text.UTF8Encoding($false)))

    if ($Verify) {
        $verifyRoot = Join-Path $env:TEMP ('trinity-release-verify-' + [guid]::NewGuid().ToString('N'))
        $folder = Join-Path $verifyRoot 'folder with spaces'
        $oldTrinityHome = $env:TRINITY_HOME
        $env:TRINITY_HOME = Join-Path $verifyRoot 'registry'
        try {
            New-Item -ItemType Directory -Path $folder -Force | Out-Null
            [IO.Compression.ZipFile]::ExtractToDirectory($zipPath, $folder)
            $copy = Join-Path $folder $tag
            foreach ($rel in $paths) { if (-not (Test-Path -LiteralPath (Join-Path $copy $rel.Replace('/', '\')) -PathType Leaf)) { throw "verify: missing $rel" } }
            $repo = Join-Path $verifyRoot 'throwaway repo'
            New-Item -ItemType Directory -Path $repo | Out-Null
            & git init -b main $repo | Out-Null; if ($LASTEXITCODE -ne 0) { throw 'verify: git init' }
            & git -C $repo config user.name 'trinity verify'; & git -C $repo config user.email 'verify@example.invalid'
            [IO.File]::WriteAllText((Join-Path $repo 'README.md'), "verify`n")
            & git -C $repo add README.md; & git -C $repo commit -m verify | Out-Null; if ($LASTEXITCODE -ne 0) { throw 'verify: git commit' }
            $cmd = Join-Path $copy 'trinity.cmd'
            & $cmd version; if ($LASTEXITCODE -ne 0) { throw 'verify: version' }
            & $cmd help *> $null; if ($LASTEXITCODE -ne 0) { throw 'verify: help' }
            & (Join-Path $copy 'install.cmd') -Check *> $null; if ($LASTEXITCODE -gt 1) { throw 'verify: install-check' }
            & $cmd init $repo; if ($LASTEXITCODE -ne 0) { throw 'verify: init' }
            foreach ($rel in @('scripts/scheduler.ps1', 'scripts/lib/config.ps1', 'scripts/lib/scheduler.ps1', 'scripts/dashboard-sample.json', 'scripts/dashboard-ui/board.js', 'scripts/dashboard-ui/board.css', 'scripts/dashboard-ui/history.js')) {
                if (-not (Test-Path -LiteralPath (Join-Path $repo $rel) -PathType Leaf)) { throw "verify: init missing $rel" }
            }
            Push-Location -LiteralPath $repo
            try {
                & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts/trinity.ps1') config get *> $null
                if ($LASTEXITCODE -ne 0) { throw 'verify: config' }
                & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts/trinity.ps1') queue list *> $null
                if ($LASTEXITCODE -ne 0) { throw 'verify: queue' }
                & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts/trinity.ps1') status *> $null
                if ($LASTEXITCODE -ne 0) { throw 'verify: status' }
            } finally { Pop-Location }
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts/trinity.ps1') version
            if ($LASTEXITCODE -ne 0) { throw 'verify: installed-version' }
            Write-Host 'verify: PASS'
        } catch {
            Write-Host ('verify: FAIL ' + $_.Exception.Message)
            throw
        } finally { $env:TRINITY_HOME = $oldTrinityHome; Remove-Item -LiteralPath $verifyRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }
    Write-Host "zip: $zipPath"
    Write-Host "sha256: $hashPath"
    Write-Host "release notes: $notesPath"
    Write-Host $hash
} finally { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue }
