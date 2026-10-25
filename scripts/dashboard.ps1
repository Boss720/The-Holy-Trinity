param(
    [int]$Port = 7777,
    [switch]$Once,
    [string[]]$Repos = @()
)

$ErrorActionPreference = 'Stop'

function Invoke-GitRead([string]$Directory, [string[]]$Arguments) {
    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $output = & git -C $Directory @Arguments 2>$null }
    finally { $ErrorActionPreference = $oldPreference }
    if ($LASTEXITCODE -ne 0) { return $null }
    return ($output -join "`n").Trim()
}

function Get-TextLines([string]$Path, [int]$Limit, [switch]$Tail) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
    $lines = @(Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue)
    if ($Tail -and $lines.Count -gt $Limit) { $lines = $lines[($lines.Count - $Limit)..($lines.Count - 1)] }
    elseif (-not $Tail -and $lines.Count -gt $Limit) { $lines = $lines[0..($Limit - 1)] }
    return ($lines -join "`n")
}

function Get-TaskState([string]$Status, [bool]$RunnerAlive) {
    if ($RunnerAlive -or $Status -match '^(started|running|working)(\s|:|$)') { return 'running' }
    if ($Status -match '^failed') { return 'failed' }
    if ($Status -match '^merged') { return 'merged' }
    if ($Status -match '^cancelled') { return 'cancelled' }
    if ($Status -match '^done') { return 'done' }
    if ($Status -match '^waiting') { return 'waiting' }
    return 'other'
}

function Get-RepoTasks([string]$Main, [string]$Common) {
    $boardPath = Join-Path $Common 'agent-board.md'
    if (-not (Test-Path -LiteralPath $boardPath -PathType Leaf)) { return @() }
    $sections = New-Object System.Collections.Generic.List[object]
    $entry = $null
    foreach ($line in [IO.File]::ReadAllLines($boardPath)) {
        if ($line -match '^##\s+(.+)$') {
            if ($entry) { $sections.Add($entry) }
            $entry = [ordered]@{ task = $Matches[1].Trim(); agent = ''; branch = ''; worktree = ''; scope = ''; status = '' }
        }
        elseif ($entry -and $line -match '^-\s+(agent|branch|worktree|scope|status):\s*(.*)$') {
            $entry[$Matches[1]] = $Matches[2].Trim()
        }
    }
    if ($entry) { $sections.Add($entry) }

    $outDir = Join-Path $Main '.codex-out'
    $branchNames = Invoke-GitRead $Main @('for-each-ref', '--format=%(refname:short)', 'refs/heads')
    $branchSet = @{}
    if ($branchNames) { foreach ($name in ($branchNames -split "`n")) { $branchSet[$name.Trim()] = $true } }
    $tasks = New-Object System.Collections.Generic.List[object]
    foreach ($item in $sections) {
        if ($item.agent -notin @('claude', 'codex', 'antigravity')) { continue }
        $pidPath = Join-Path $outDir ("pid-{0}.txt" -f $item.task)
        $runnerAlive = $false
        if (Test-Path -LiteralPath $pidPath -PathType Leaf) {
            $pidText = (Get-Content -LiteralPath $pidPath -Raw -ErrorAction SilentlyContinue).Trim()
            $runnerPid = 0
            if ([int]::TryParse($pidText, [ref]$runnerPid) -and $runnerPid -gt 0) {
                $runnerAlive = [bool](Get-Process -Id $runnerPid -ErrorAction SilentlyContinue)
            }
        }
        $status = [string]$item.status
        $state = Get-TaskState $status $runnerAlive
        $updated = ''
        if ($status -match '(\d{4}-\d{2}-\d{2} \d{2}:\d{2})\s*$') { $updated = $Matches[1] }
        $commits = 0
        if ($item.branch -and $item.branch -ne '-' -and $branchSet.ContainsKey($item.branch)) {
            $count = Invoke-GitRead $Main @('rev-list', '--count', "main..$($item.branch)")
            if ($count -match '^\d+$') { $commits = [int]$count }
        }
        $result = Get-TextLines (Join-Path $outDir ("result-{0}.md" -f $item.task)) 15
        $logTail = Get-TextLines (Join-Path $outDir ("log-{0}.txt" -f $item.task)) 15 -Tail
        $tasks.Add([pscustomobject]@{
            task = [string]$item.task
            agent = [string]$item.agent
            state = $state
            status = $status
            updated = $updated
            branch = [string]$item.branch
            scope = [string]$item.scope
            runnerAlive = $runnerAlive
            commits = $commits
            result = $result
            logTail = $logTail
        })
    }
    return @($tasks | Sort-Object @{ Expression = { if ($_.state -eq 'running') { 0 } else { 1 } } }, @{ Expression = { $_.updated }; Descending = $true })
}

function Get-RepoState([string]$Path) {
    $root = Invoke-GitRead $Path @('rev-parse', '--show-toplevel')
    if (-not $root) { return $null }
    $root = [IO.Path]::GetFullPath($root)
    $common = Invoke-GitRead $root @('rev-parse', '--path-format=absolute', '--git-common-dir')
    if (-not $common) { return $null }
    $common = [IO.Path]::GetFullPath($common)
    $branch = Invoke-GitRead $root @('branch', '--show-current')
    if (-not $branch) { $branch = '' }
    $status = Invoke-GitRead $root @('status', '--porcelain')
    $uncommitted = 0
    if ($status) { $uncommitted = @($status -split "`n" | Where-Object { $_ }).Count }
    $ahead = 0
    $upstream = Invoke-GitRead $root @('rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{upstream}')
    if ($upstream) {
        $aheadText = Invoke-GitRead $root @('rev-list', '--count', "$upstream..HEAD")
        if ($aheadText -match '^\d+$') { $ahead = [int]$aheadText }
    }
    $plan = [ordered]@{ done = 0; total = 0; open = @() }
    $planPath = Join-Path $root 'PLAN.md'
    if (Test-Path -LiteralPath $planPath -PathType Leaf) {
        foreach ($line in [IO.File]::ReadAllLines($planPath)) {
            if ($line -match '^\s*-\s+\[([ xX])\]\s*(.*)$') {
                $plan.total++
                if ($Matches[1] -match '[xX]') { $plan.done++ } else { $plan.open += $Matches[2] }
            }
        }
    }
    $handoff = @()
    $handoffPath = Join-Path $root 'HANDOFF.md'
    if (Test-Path -LiteralPath $handoffPath -PathType Leaf) {
        $inStatus = $false
        foreach ($line in [IO.File]::ReadAllLines($handoffPath)) {
            if ($line -match '^##\s+') { $inStatus = ($line -match '^##\s+Status\s*$'); continue }
            if ($inStatus -and $line -match '^\s*-\s+(.+?)\s*$') { $handoff += $Matches[1] }
        }
    }
    return [pscustomobject]@{
        name = (Split-Path $root -Leaf)
        path = $root
        branch = $branch
        uncommitted = $uncommitted
        ahead = $ahead
        plan = [pscustomobject]$plan
        handoff = @($handoff)
        tasks = @(Get-RepoTasks $root $common)
    }
}

function Get-DashboardState {
    $candidatePaths = New-Object System.Collections.Generic.List[string]
    $registry = Join-Path (Join-Path $env:USERPROFILE '.trinity') 'repos.txt'
    if (Test-Path -LiteralPath $registry -PathType Leaf) {
        foreach ($line in [IO.File]::ReadAllLines($registry)) {
            $value = $line.Trim()
            if ($value -and -not $value.StartsWith('#')) { $candidatePaths.Add($value) }
        }
    }
    $scriptRoot = Split-Path $PSScriptRoot -Parent
    $candidatePaths.Add($scriptRoot)
    foreach ($extra in $Repos) { if ($extra) { $candidatePaths.Add($extra) } }
    $seen = @{}
    $repoStates = New-Object System.Collections.Generic.List[object]
    foreach ($candidate in $candidatePaths) {
        if (-not (Test-Path -LiteralPath $candidate -PathType Container)) { continue }
        $state = Get-RepoState $candidate
        if (-not $state) { continue }
        $key = $state.path.ToLowerInvariant()
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        $repoStates.Add($state)
    }
    $allTasks = @($repoStates | ForEach-Object { $_.tasks })
    $agents = [ordered]@{}
    foreach ($agent in @('claude', 'codex', 'antigravity')) {
        $agentTasks = @($allTasks | Where-Object { $_.agent -eq $agent })
        $agents[$agent] = [pscustomobject]@{
            running = @($agentTasks | Where-Object { $_.state -eq 'running' }).Count
            done = @($agentTasks | Where-Object { $_.state -in @('done', 'merged') }).Count
            failed = @($agentTasks | Where-Object { $_.state -eq 'failed' }).Count
            total = $agentTasks.Count
        }
    }
    return [pscustomobject]@{
        generated = (Get-Date -Format "yyyy-MM-dd'T'HH:mm:ss")
        agents = [pscustomobject]$agents
        repos = @($repoStates | Sort-Object name)
    }
}

function Convert-StateToJson($State) {
    return ($State | ConvertTo-Json -Depth 6 -Compress)
}

if ($Once) {
    Convert-StateToJson (Get-DashboardState)
    exit 0
}

$listener = $null
try {
    $listener = New-Object System.Net.HttpListener
    $listener.Prefixes.Add("http://localhost:$Port/")
    $listener.Start()
}
catch {
    [Console]::Error.WriteLine("Dashboard could not listen on port ${Port}: $($_.Exception.Message)")
    exit 2
}
try {
    while ($listener.IsListening) {
        $context = $null
        try { $context = $listener.GetContext() }
        catch [System.Net.HttpListenerException] { break }
        catch [System.ObjectDisposedException] { break }
        if (-not $context) { continue }
        $response = $context.Response
        try {
            if ($context.Request.HttpMethod -ne 'GET') {
                $response.StatusCode = 404
            }
            elseif ($context.Request.Url.AbsolutePath -eq '/api/state') {
                $bytes = [Text.Encoding]::UTF8.GetBytes((Convert-StateToJson (Get-DashboardState)))
                $response.StatusCode = 200
                $response.ContentType = 'application/json; charset=utf-8'
                $response.Headers['Cache-Control'] = 'no-store'
                $response.ContentLength64 = $bytes.Length
                $response.OutputStream.Write($bytes, 0, $bytes.Length)
            }
            elseif ($context.Request.Url.AbsolutePath -eq '/') {
                $htmlPath = Join-Path $PSScriptRoot 'dashboard.html'
                if (Test-Path -LiteralPath $htmlPath -PathType Leaf) {
                    $bytes = [IO.File]::ReadAllBytes($htmlPath)
                    $response.StatusCode = 200
                    $response.ContentType = 'text/html; charset=utf-8'
                    $response.ContentLength64 = $bytes.Length
                    $response.OutputStream.Write($bytes, 0, $bytes.Length)
                }
                else { $response.StatusCode = 404 }
            }
            else { $response.StatusCode = 404 }
        }
        catch {
            $response.StatusCode = 500
        }
        finally {
            try { $response.Close() } catch { }
        }
    }
}
finally { $listener.Close() }
