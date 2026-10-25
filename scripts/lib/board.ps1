# Shared helpers for agent-task.ps1 and trinity.ps1. Dot-source this file.

function Fail([string]$msg) {
    Write-Host "trinity: $msg" -ForegroundColor Red
    exit 1
}

$script:Utf8 = New-Object Text.UTF8Encoding($false)

# Repo paths seen from any checkout (main or worktree).
function Get-RepoPaths([string]$From) {
    $root = (git -C $From rev-parse --show-toplevel)
    if ($LASTEXITCODE -ne 0 -or -not $root) { Fail 'not inside a git repo' }
    $root = $root -replace '/', '\'
    $common = (git -C $root rev-parse --path-format=absolute --git-common-dir) -replace '/', '\'
    $main = Split-Path $common -Parent
    [pscustomobject]@{
        Root     = $root
        Common   = $common
        Main     = $main
        Board    = Join-Path $common 'agent-board.md'
        Worktrees = Join-Path (Split-Path $main -Parent) ((Split-Path $main -Leaf) + '.worktrees')
        Out      = Join-Path $main '.codex-out'
    }
}

# Every board write goes through a repo-wide exclusive lock so concurrent agents cannot clobber each other.
function Invoke-BoardLocked($Paths, [scriptblock]$Body) {
    $lockPath = Join-Path $Paths.Common 'agent-board.lock'
    $lock = $null
    for ($i = 0; $i -lt 50 -and -not $lock; $i++) {
        try { $lock = [IO.File]::Open($lockPath, 'OpenOrCreate', 'ReadWrite', 'None') }
        catch { Start-Sleep -Milliseconds 200 }
    }
    if (-not $lock) { Fail "board lock busy for 10s: $lockPath" }
    try {
        if (-not (Test-Path $Paths.Board)) {
            $header = "# Agent board`r`n`r`nShared by every worktree of this repo. One section per task. Not committed.`r`n"
            [IO.File]::WriteAllText($Paths.Board, $header, $script:Utf8)
        }
        & $Body
    }
    finally { $lock.Dispose() }
}

function Add-BoardEntry($Paths, [string]$Task, [string]$Agent, [string]$Branch, [string]$WtPath, [string]$Scope) {
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm'
    $entry = "`r`n## $Task`r`n- agent: $Agent`r`n- branch: $Branch`r`n- worktree: $WtPath`r`n- scope: $Scope`r`n- status: started $stamp`r`n"
    Invoke-BoardLocked $Paths { [IO.File]::AppendAllText($Paths.Board, $entry, $script:Utf8) }
}

# Replace the status line of one task section.
function Set-BoardStatus($Paths, [string]$Task, [string]$Status) {
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm'
    Invoke-BoardLocked $Paths {
        $lines = [IO.File]::ReadAllLines($Paths.Board)
        $inTask = $false
        for ($i = 0; $i -lt $lines.Length; $i++) {
            if ($lines[$i] -match '^## ') { $inTask = ($lines[$i] -eq "## $Task") }
            elseif ($inTask -and $lines[$i] -match '^- status:') { $lines[$i] = "- status: $Status $stamp" }
        }
        [IO.File]::WriteAllText($Paths.Board, (($lines -join "`r`n") + "`r`n"), $script:Utf8)
    }
}

# Board section for one task as a hashtable (agent, branch, worktree, scope, status).
function Get-BoardEntry($Paths, [string]$Task) {
    if (-not (Test-Path $Paths.Board)) { return $null }
    $entry = $null
    foreach ($line in [IO.File]::ReadAllLines($Paths.Board)) {
        if ($line -match '^## (.+)$') {
            if ($entry) { break }
            if ($Matches[1] -eq $Task) { $entry = @{ task = $Task } }
        }
        elseif ($entry -and $line -match '^- (\w+): (.*)$') { $entry[$Matches[1]] = $Matches[2] }
    }
    $entry
}

# Create worktree + branch agent/<agent>/<task> from $Base and register it on the board.
function New-AgentWorktree($Paths, [string]$Agent, [string]$Task, [string]$Scope, [string]$Base) {
    if ($Agent -notin @('claude', 'codex', 'antigravity')) { Fail '-Agent must be claude, codex, or antigravity' }
    if ($Task -notmatch '^[a-z0-9][a-z0-9-]*$') { Fail 'task name must be lowercase letters, digits, dashes' }
    $branch = "agent/$Agent/$Task"
    $wtPath = Join-Path $Paths.Worktrees "$Agent-$Task"
    git -C $Paths.Main rev-parse --verify --quiet "refs/heads/$branch" | Out-Null
    if ($LASTEXITCODE -eq 0) { Fail "branch $branch already exists" }
    if (Test-Path $wtPath) { Fail "path already exists: $wtPath" }
    if (-not (Test-Path $Paths.Worktrees)) { New-Item -ItemType Directory -Path $Paths.Worktrees | Out-Null }
    git -C $Paths.Main worktree add -b $branch $wtPath $Base | Out-Host
    if ($LASTEXITCODE -ne 0) { Fail 'git worktree add failed' }
    try { Add-BoardEntry $Paths $Task $Agent $branch $wtPath $Scope }
    catch { Fail "worktree created at $wtPath but board registration failed: $($_.Exception.Message)" }
    [pscustomobject]@{ Branch = $branch; Path = $wtPath }
}

# Newest codex.exe shipped with the Codex desktop app, else codex.exe on PATH.
function Resolve-AgyExe {
    if ($env:AGY_EXE -and (Test-Path $env:AGY_EXE)) { return $env:AGY_EXE }
    $exe = Join-Path $env:LOCALAPPDATA 'agy\bin\agy.exe'
    if (Test-Path $exe) { return $exe }
    $cmd = Get-Command agy.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    Fail 'agy.exe (Antigravity CLI) not found. Install it or set AGY_EXE.'
}

function Resolve-CodexExe {
    if ($env:CODEX_EXE -and (Test-Path $env:CODEX_EXE)) { return $env:CODEX_EXE }
    $bin = Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\bin'
    $exe = Get-ChildItem $bin -Directory -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending |
        ForEach-Object { Join-Path $_.FullName 'codex.exe' } | Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($exe) { return $exe }
    $cmd = Get-Command codex.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    Fail 'codex.exe not found. Install the Codex desktop app or set CODEX_EXE.'
}
