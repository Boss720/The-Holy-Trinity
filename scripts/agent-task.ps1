<#
.SYNOPSIS
  Create an isolated worktree + branch agent/<agent>/<task> and register it on the shared agent board.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File scripts\agent-task.ps1 -Agent codex -Task login-form -Scope "src/auth/*"
  powershell -ExecutionPolicy Bypass -File scripts\agent-task.ps1 -Agent antigravity -Task ui-pass -Scope "src/ui/*" -Open
  powershell -ExecutionPolicy Bypass -File scripts\agent-task.ps1 -List
#>
param(
    [ValidateSet('claude', 'codex', 'antigravity')]
    [string]$Agent,
    [string]$Task,
    [string]$Scope = 'unspecified',
    [string]$Base = 'main',
    [switch]$Open,
    [switch]$List
)

function Fail([string]$msg) {
    Write-Host "agent-task: $msg" -ForegroundColor Red
    exit 1
}

$root = (git -C $PSScriptRoot rev-parse --show-toplevel)
if ($LASTEXITCODE -ne 0 -or -not $root) { Fail 'not inside a git repo' }
$root = $root -replace '/', '\'
$common = (git -C $root rev-parse --path-format=absolute --git-common-dir) -replace '/', '\'
$board = Join-Path $common 'agent-board.md'
$utf8 = New-Object Text.UTF8Encoding($false)

# Every board write goes through a repo-wide exclusive lock so concurrent agents cannot clobber each other.
function Invoke-BoardLocked([scriptblock]$Body) {
    $lockPath = Join-Path $common 'agent-board.lock'
    $lock = $null
    for ($i = 0; $i -lt 50 -and -not $lock; $i++) {
        try { $lock = [IO.File]::Open($lockPath, 'OpenOrCreate', 'ReadWrite', 'None') }
        catch { Start-Sleep -Milliseconds 200 }
    }
    if (-not $lock) { Fail "board lock busy for 10s: $lockPath" }
    try { & $Body } finally { $lock.Dispose() }
}

Invoke-BoardLocked {
    if (-not (Test-Path $board)) {
        $header = "# Agent board`r`n`r`nShared by every worktree of this repo. One section per task. Not committed.`r`n"
        [IO.File]::WriteAllText($board, $header, $utf8)
    }
}

if ($List) {
    git -C $root worktree list
    Write-Host ''
    Write-Host "Board: $board"
    Get-Content $board
    exit 0
}

if (-not $Agent) { Fail '-Agent is required (claude, codex, antigravity)' }
if ($Task -notmatch '^[a-z0-9][a-z0-9-]*$') { Fail '-Task must be lowercase letters, digits, dashes' }

$branch = "agent/$Agent/$Task"
$mainRoot = Split-Path $common -Parent
$wtDir = Join-Path (Split-Path $mainRoot -Parent) ((Split-Path $mainRoot -Leaf) + '.worktrees')
$wtPath = Join-Path $wtDir "$Agent-$Task"

git -C $root rev-parse --verify --quiet "refs/heads/$branch" | Out-Null
if ($LASTEXITCODE -eq 0) { Fail "branch $branch already exists" }
if (Test-Path $wtPath) { Fail "path already exists: $wtPath" }

if (-not (Test-Path $wtDir)) { New-Item -ItemType Directory -Path $wtDir | Out-Null }
git -C $root worktree add -b $branch $wtPath $Base
if ($LASTEXITCODE -ne 0) { Fail 'git worktree add failed' }

$stamp = Get-Date -Format 'yyyy-MM-dd HH:mm'
$entry = "`r`n## $Task`r`n- agent: $Agent`r`n- branch: $branch`r`n- worktree: $wtPath`r`n- scope: $Scope`r`n- status: started $stamp`r`n"
try {
    Invoke-BoardLocked { [IO.File]::AppendAllText($board, $entry, $utf8) }
}
catch {
    Fail "worktree created at $wtPath but board registration failed: $($_.Exception.Message)"
}

Write-Host ''
Write-Host "Worktree: $wtPath"
Write-Host "Branch:   $branch"
Write-Host "Board:    $board"
Write-Host ''
switch ($Agent) {
    'codex'       { Write-Host "Start Codex there:   `"$wtPath\scripts\codex.cmd`"   (or open the folder in the Codex app)" }
    'antigravity' { Write-Host "Open in Antigravity: antigravity-ide `"$wtPath`"" }
    'claude'      { Write-Host "Open a new Claude Code session on: $wtPath" }
}
Write-Host "Merge later from main checkout: git merge --no-ff $branch"
Write-Host "Remove when merged:             git worktree remove `"$wtPath`""

if ($Open -and $Agent -eq 'antigravity') {
    Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', 'start', '""', 'antigravity-ide', "`"$wtPath`""
}
