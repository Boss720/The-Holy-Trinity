param(
    [int]$Port = 7777,
    [int]$RefreshSeconds = 3,
    [switch]$Once,
    [switch]$LibraryOnly,
    [string]$Chat = '',
    [string[]]$Repos = @()
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Web.Extensions
$script:JsonSerializer = New-Object System.Web.Script.Serialization.JavaScriptSerializer
$script:JsonSerializer.MaxJsonLength = [int]::MaxValue
$script:TranscriptCache = @{}
$script:TranscriptSummaryCache = @{}
$script:CodexRolloutCache = @{}
$script:CodexSubChatCache = @{}
$script:AgyTaskCache = @{}
$script:AgyModelCache = @{}
$script:ClaudeModelCache = @{}
$script:ClaudeSummaryCache = @{}
$script:AvailabilityCache = $null
$script:AvailabilityCachedAt = [datetime]::MinValue
$script:CollectDurations = New-Object System.Collections.Generic.List[int]
# Get-FileHash comes from a module that Windows PowerShell cannot autoload when PSModulePath is inherited from pwsh 7
# (CI runners, pwsh users), so hash with .NET instead.
function Get-ShortFileHash([string]$Path) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $bytes = $sha.ComputeHash([IO.File]::ReadAllBytes($Path)) } finally { $sha.Dispose() }
    return ([BitConverter]::ToString($bytes).Replace('-', '').Substring(0, 12).ToLowerInvariant())
}
$script:ServerFacts = [pscustomobject]@{
    startedAt = (Get-Date).ToString("yyyy-MM-dd'T'HH:mm:ssK")
    scriptHash = Get-ShortFileHash $PSCommandPath
}
$script:BlockedRemoteCount = 0
$script:JsonLinesDroppedLong = $false
$script:CodexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }
$script:AgyHome = if ($env:TRINITY_AGY_HOME) { $env:TRINITY_AGY_HOME } else { Join-Path (Join-Path $env:USERPROFILE '.gemini') 'antigravity-cli' }
$script:ClaudeHome = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $env:USERPROFILE '.claude' }

function Get-JsonValue($Object, [string]$Name, $Default = $null) {
    if ($null -eq $Object) { return $Default }
    if ($Object -is [System.Collections.IDictionary]) { if ($Object.Keys -contains $Name) { return $Object[$Name] }; return $Default }
    $property = $Object.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    return $Default
}

function Convert-ToIso($Value) {
    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return '' }
    try { $stamp = [datetime]::Parse([string]$Value); if ($stamp.Kind -ne [DateTimeKind]::Unspecified) { $stamp = $stamp.ToLocalTime() }; return $stamp.ToString("yyyy-MM-dd'T'HH:mm:ss") } catch { return '' }
}

function Convert-UnixToIso($Value) {
    try { return ([datetime]::new(1970, 1, 1).AddSeconds([double]$Value)).ToLocalTime().ToString("yyyy-MM-dd'T'HH:mm:ss") } catch { return '' }
}

function Read-JsonLinesIncremental([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @() }
    try {
        $stream = New-Object IO.FileStream($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        try {
            $key = [IO.Path]::GetFullPath($Path).ToLowerInvariant()
            $cache = $script:TranscriptCache[$key]
            if (-not $cache -or $stream.Length -lt $cache.offset) { $cache = @{ offset = 0L; pending = '' } }
            [void]$stream.Seek([long]$cache.offset, [IO.SeekOrigin]::Begin)
            $remaining = [int][Math]::Min([int]::MaxValue, $stream.Length - $cache.offset)
            $buffer = New-Object byte[] $remaining
            $read = 0
            while ($read -lt $remaining) { $n = $stream.Read($buffer, $read, $remaining - $read); if ($n -le 0) { break }; $read += $n }
            $cache.offset = $stream.Position
            $text = $cache.pending + [Text.Encoding]::UTF8.GetString($buffer, 0, $read)
            $lines = $text -split "`n"
            $cache.pending = ''
            if (-not $text.EndsWith("`n")) { $cache.pending = $lines[$lines.Count - 1]; if ($lines.Count -gt 1) { $lines = $lines[0..($lines.Count - 2)] } else { $lines = @() } }
            $records = New-Object System.Collections.Generic.List[object]
            foreach ($line in $lines) {
                $line = $line.TrimEnd("`r").TrimStart([char]0xFEFF)
                if (-not $line -or $line.Length -gt 1048576) { continue }
                try { $records.Add($script:JsonSerializer.DeserializeObject($line)) } catch { }
            }
            $script:TranscriptCache[$key] = $cache
            return @($records.ToArray())
        }
        finally { $stream.Dispose() }
    } catch { return @() }
}

function Read-JsonLinesBounded([string]$Path, [int]$MaxBytes = 4194304, [switch]$HeadAndTail) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @() }
    try {
        $stream = New-Object IO.FileStream($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        try {
            if ($HeadAndTail -and $stream.Length -gt 131072) {
                $half = 65536; $buffers = @()
                foreach ($offset in @(0L, [long]($stream.Length - $half))) { [void]$stream.Seek($offset, [IO.SeekOrigin]::Begin); $buffer = New-Object byte[] $half; $read = $stream.Read($buffer, 0, $half); $buffers += [Text.Encoding]::UTF8.GetString($buffer, 0, $read) }
                $text = $buffers -join "`n"
            } else {
                $count = [int][Math]::Min($stream.Length, $MaxBytes)
                if ($stream.Length -gt $count) { [void]$stream.Seek(-$count, [IO.SeekOrigin]::End) }
                $buffer = New-Object byte[] $count; $read = 0
                while ($read -lt $count) { $n = $stream.Read($buffer, $read, $count - $read); if ($n -le 0) { break }; $read += $n }
                $text = [Text.Encoding]::UTF8.GetString($buffer, 0, $read)
            }
            $records = New-Object System.Collections.Generic.List[object]
            foreach ($line in ($text.TrimStart([char]0xFEFF) -split "`r?`n")) { if ($line.Length -gt 1048576) { $script:JsonLinesDroppedLong = $true; continue }; if ($line.Trim()) { try { $records.Add($script:JsonSerializer.DeserializeObject($line)) } catch { } } }
            return @($records.ToArray())
        } finally { $stream.Dispose() }
    } catch { return @() }
}

function Get-HeadText([string]$Path, [int]$MaxBytes = 8192) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
    try {
        $stream = New-Object IO.FileStream($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        try { $count=[int][Math]::Min($stream.Length,$MaxBytes); $buffer=New-Object byte[] $count; $read=0; while($read -lt $count){$n=$stream.Read($buffer,$read,$count-$read);if($n -le 0){break};$read+=$n}; return [Text.Encoding]::UTF8.GetString($buffer,0,$read) }
        finally { $stream.Dispose() }
    } catch { return '' }
}

function Get-Redacted([string]$Text) {
    if ($null -eq $Text) { return '' }
    foreach ($pattern in @('sk-[A-Za-z0-9_-]{16,}', 'gh[pousr]_[A-Za-z0-9]{20,}', 'xox[abprs]-[A-Za-z0-9-]{10,}', 'AKIA[0-9A-Z]{16}', 'AIza[0-9A-Za-z_-]{35}', '(?i)bearer\s+[A-Za-z0-9._~+/=-]{20,}')) { $Text = [regex]::Replace($Text, $pattern, '[redacted]') }
    return $Text
}

function Get-ChatKeyKind([string]$Key) {
    if ($Key -match '^codex:[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') { return 'codex' }
    if ($Key -match '^agy:[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') { return 'agy' }
    if ($Key -match '^claude:[A-Za-z0-9-]{1,200}:[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}(:[A-Za-z0-9_-]{1,64})?$') { return 'claude' }
    return ''
}

function Get-CodexRollout([string]$SessionId, [string]$Started) {
    if (-not $SessionId) { return '' }
    if ($script:CodexRolloutCache.ContainsKey($SessionId) -and $script:CodexRolloutCache[$SessionId]) { return $script:CodexRolloutCache[$SessionId] }
    $sessions = Join-Path $script:CodexHome 'sessions'
    $folders = New-Object System.Collections.Generic.List[string]
    try { $date = [datetime]::Parse($Started); for ($i = -1; $i -le 1; $i++) { $folders.Add((Join-Path $sessions $date.AddDays($i).ToString('yyyy\\MM\\dd'))) } } catch { }
    foreach ($folder in $folders) {
        if (Test-Path -LiteralPath $folder -PathType Container) {
            $file = Get-ChildItem -LiteralPath $folder -Filter "rollout-*-$SessionId.jsonl" -File -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($file) { $script:CodexRolloutCache[$SessionId] = $file.FullName; return $file.FullName }
        }
    }
    $searched = 0; $file = $null
    if (Test-Path -LiteralPath $sessions -PathType Container) {
        foreach ($year in (Get-ChildItem -LiteralPath $sessions -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending)) {
            foreach ($month in (Get-ChildItem -LiteralPath $year.FullName -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending)) {
                foreach ($day in (Get-ChildItem -LiteralPath $month.FullName -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending)) {
                    $searched++; $file = Get-ChildItem -LiteralPath $day.FullName -Filter "rollout-*-$SessionId.jsonl" -File -ErrorAction SilentlyContinue | Select-Object -First 1
                    if ($file -or $searched -ge 365) { break }
                }
                if ($file -or $searched -ge 365) { break }
            }
            if ($file -or $searched -ge 365) { break }
        }
    }
    $path = if ($file) { $file.FullName } else { '' }; $script:CodexRolloutCache[$SessionId] = $path; return $path
}

function Get-RelativeTouchedPath([string]$Path, [string]$Worktree) {
    if (-not $Path) { return '' }
    $pathText = $Path.Replace('\', '/')
    # A patch quoted inside another file's content leaves fragments such as "tests/"; a file path never ends in a slash.
    if ($pathText.EndsWith('/')) { return '' }
    if ($Worktree -and $Worktree -ne '-') {
        try {
            $root = [IO.Path]::GetFullPath($Worktree).TrimEnd('\', '/').Replace('\', '/')
            if ($pathText.StartsWith($root + '/', [StringComparison]::OrdinalIgnoreCase)) { return $pathText.Substring($root.Length + 1) }
        } catch { }
    }
    return $pathText
}

function Get-AgyTaskSession([string]$OutDir, [string]$Task) {
    $taskPath = [IO.Path]::GetFullPath((Join-Path $OutDir ("task-{0}.md" -f $Task))).Replace('\', '/').ToLowerInvariant()
    $cached = $script:AgyTaskCache[$taskPath]
    if ($cached -and $cached.until -gt (Get-Date)) { return $cached }
    $found = @{ session=''; model=''; until=(Get-Date).AddSeconds(60) }
    $brain = Join-Path $script:AgyHome 'brain'
    if (Test-Path -LiteralPath $brain -PathType Container) {
        foreach ($folder in (Get-ChildItem -LiteralPath $brain -Directory -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 200)) {
            if ($folder.Name -notmatch '^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$') { continue }
            $file = Join-Path $folder.FullName '.system_generated\logs\transcript.jsonl'
            $head = Get-HeadText $file 16384
            foreach ($line in ($head -split "`n")) {
                if ($line -notmatch '"type"\s*:\s*"USER_INPUT"') { continue }
                try { $record = $script:JsonSerializer.DeserializeObject($line.TrimEnd("`r").TrimStart([char]0xFEFF)); $content = [string](Get-JsonValue $record 'content' '') } catch { continue }
                try { $content = [Uri]::UnescapeDataString($content) } catch { break }
                if ($content -notmatch '(?i)Read the task file\s+[`"'']?(?:file:///)?(.+?task-[^\s`"'']+\.md)') { break }
                $mentioned = $Matches[1].Replace('\', '/').ToLowerInvariant()
                if ($mentioned -eq $taskPath) {
                    $found.session = $folder.Name
                    if ($content -match '(?i)setting `Model Selection` from .+? to (.+?)\.(?:\s|$)') { $found.model = $Matches[1].Trim() }
                }
                break
            }
            if ($found.session) { break }
        }
    }
    # A found conversation never changes; only misses expire, so a task started later is still picked up.
    if ($found.session) { $found.until = [datetime]::MaxValue }
    $script:AgyTaskCache[$taskPath] = $found
    return $found
}

function Get-AgyModelBySession([string]$Session) {
    if ($script:AgyModelCache.ContainsKey($Session)) { return $script:AgyModelCache[$Session] }
    $model = ''; $logDir = Join-Path $script:AgyHome 'log'
    if (Test-Path -LiteralPath $logDir -PathType Container) {
        foreach ($file in (Get-ChildItem -LiteralPath $logDir -Filter 'cli-*.log' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 50)) {
            $head = Get-HeadText $file.FullName 262144
            if ($head -match [regex]::Escape($Session) -and $head -match 'label="([^"]+)"') { $model = $Matches[1]; break }
        }
    }
    $script:AgyModelCache[$Session] = $model
    return $model
}

function Get-CodexData([string]$OutDir, [string]$Task, $Meta, [bool]$Running, [string]$Worktree) {
    $logPath = Join-Path $OutDir ("log-{0}.txt" -f $Task)
    $head = Get-HeadText $logPath 8192
    $model = ''; $effort = ''; $sessionId = ''
    if ($head -match '(?im)^model:\s*(.+)$') { $model = $Matches[1].Trim() }
    if ($head -match '(?im)^reasoning effort:\s*(.*)$') { $effort = $Matches[1].Trim() }
    if ($head -match '(?im)^session id:\s*([0-9a-f-]{36})\s*$') { $sessionId = $Matches[1] }
    if (-not $sessionId) { $sessionId = [string](Get-JsonValue $Meta 'sessionId' '') }
    $started = [string](Get-JsonValue $Meta 'started' '')
    $rollout = Get-CodexRollout $sessionId $started
    $cacheKey = if ($rollout) { [IO.Path]::GetFullPath($rollout).ToLowerInvariant() } else { '' }
    $records = if ($rollout) { Read-JsonLinesIncremental $rollout } else { @() }
    $summary = if ($cacheKey -and $script:TranscriptSummaryCache.ContainsKey($cacheKey)) { $script:TranscriptSummaryCache[$cacheKey] } else { @{ tokens=$null; context=$null; limits=@(); toolCalls=0; lastActivity=''; contextUsed=0L; steps=0; thinkingSteps=0; toolCounts=@{}; lastTool=''; filesTouched=@() } }
    $tokens = $summary.tokens; $context = $summary.context; $limits = @($summary.limits); $toolCalls = [int]$summary.toolCalls; $lastActivity = [string]$summary.lastActivity
    $contextUsed = [long]$summary.contextUsed; $steps = [int]$summary.steps; $thinkingSteps = [int]$summary.thinkingSteps; $toolCounts = $summary.toolCounts; $lastTool = [string]$summary.lastTool; $filesTouched = New-Object System.Collections.Generic.List[string]; foreach ($path in $summary.filesTouched) { $filesTouched.Add($path) }
    foreach ($record in $records) {
        $stamp = Convert-ToIso (Get-JsonValue $record 'timestamp' '')
        if ($stamp) { $lastActivity = $stamp }
        $type = [string](Get-JsonValue $record 'type' '')
        $payload = Get-JsonValue $record 'payload'
        $payloadType = [string](Get-JsonValue $payload 'type' '')
        if ($type -eq 'response_item' -and $payloadType -eq 'reasoning') { $thinkingSteps++ }
        if ($type -eq 'response_item' -and $payloadType -in @('custom_tool_call', 'function_call')) {
            $toolCalls++; $name = [string](Get-JsonValue $payload 'name' ''); $lastTool = $name
            if ($name) { if (-not $toolCounts.ContainsKey($name)) { $toolCounts[$name] = 0 }; $toolCounts[$name]++ }
            # apply_patch runs directly or inside an exec script, where the patch is a JS string literal (newlines as \n, backslashes doubled).
            $inputText = [string](Get-JsonValue $payload 'input' (Get-JsonValue $payload 'arguments' ''))
            # Headers start a line; quoted headers in added lines start with "+". A direct patch has real newlines and plain paths,
            # an exec-embedded one is a JS string: escaped newlines (not doubly escaped ones) and doubled backslashes, or a template literal with real newlines.
            $embedded = $name -ne 'apply_patch'
            if ($inputText.Contains('*** Begin Patch') -and (-not $embedded -or $inputText.Contains('apply_patch('))) {
                $headerPattern = if ($embedded) { '(?:(?<!\\)\\n|\n)\*\*\* (?:Add|Update|Delete) File: (.+?)\s*(?=(?<!\\)\\[nr]|["`]|\r?\n|$)' } else { '(?m)^\*\*\* (?:Add|Update|Delete) File: (.+?)\s*$' }
                foreach ($match in [regex]::Matches($inputText, $headerPattern)) {
                    $path = $match.Groups[1].Value.Trim(); if ($embedded) { $path = $path.Replace('\\', '\') }
                    $path = Get-RelativeTouchedPath $path $Worktree
                    if ($path -and $filesTouched.Count -lt 20 -and -not $filesTouched.Contains($path)) { $filesTouched.Add($path) }
                }
            }
        }
        if ($type -eq 'event_msg' -and $payloadType -eq 'token_count') {
            $info = Get-JsonValue $payload 'info'; $usage = Get-JsonValue $info 'total_token_usage'
            if ($info) { $steps++; $contextUsed = [long](Get-JsonValue (Get-JsonValue $info 'last_token_usage') 'input_tokens' 0) }
            if ($usage) { $tokens = [ordered]@{ input = [long](Get-JsonValue $usage 'input_tokens' 0); cached = [long](Get-JsonValue $usage 'cached_input_tokens' 0); output = [long](Get-JsonValue $usage 'output_tokens' 0); reasoning = [long](Get-JsonValue $usage 'reasoning_output_tokens' 0); total = [long](Get-JsonValue $usage 'total_tokens' 0) } }
            $context = Get-JsonValue $info 'model_context_window' $context
            $rate = Get-JsonValue $payload 'rate_limits'
            $limits = @()
            foreach ($name in @('primary', 'secondary')) { $lim = Get-JsonValue $rate $name; if ($lim) { $limits += [pscustomobject]@{ name = $name; usedPercent = Get-JsonValue $lim 'used_percent' 0; windowMinutes = Get-JsonValue $lim 'window_minutes' 0; resetsAt = Convert-UnixToIso (Get-JsonValue $lim 'resets_at' 0) } } }
        }
    }
    if ($cacheKey) { $script:TranscriptSummaryCache[$cacheKey] = @{ tokens=$tokens; context=$context; limits=@($limits); toolCalls=$toolCalls; lastActivity=$lastActivity; contextUsed=$contextUsed; steps=$steps; thinkingSteps=$thinkingSteps; toolCounts=$toolCounts; lastTool=$lastTool; filesTouched=@($filesTouched.ToArray()) } }
    if ($Meta) { $model = [string](Get-JsonValue $Meta 'model' $model); $effort = [string](Get-JsonValue $Meta 'effort' $effort); $sessionId = [string](Get-JsonValue $Meta 'sessionId' $sessionId) }
    if (-not $Running -and (Get-JsonValue $Meta 'tokens')) { $tokens = Get-JsonValue $Meta 'tokens' }
    if (-not $lastActivity -and $rollout) { try { $lastActivity = (Get-Item -LiteralPath $rollout).LastWriteTime.ToString("yyyy-MM-dd'T'HH:mm:ss") } catch { } }
    $chat = if ($rollout) { "codex:$sessionId" } else { '' }
    $subs = New-Object System.Collections.Generic.List[object]
    # A running task can still spawn subagents, so only a finished task's list is served from the cache.
    if ($sessionId -and $rollout -and -not $Running -and $script:CodexSubChatCache.ContainsKey($sessionId)) { foreach ($sub in $script:CodexSubChatCache[$sessionId]) { $subs.Add($sub) } }
    elseif ($sessionId -and $rollout) {
        # Children land in the parent's day folder or a later one (a run can cross midnight).
        $folder = Split-Path $rollout -Parent; $folders = @($folder)
        try { $day = [datetime]::ParseExact(($folder.Substring($folder.Length - 10) -replace '[\\/]', '-'), 'yyyy-MM-dd', $null); $root = Split-Path (Split-Path (Split-Path $folder -Parent) -Parent) -Parent; $folders += @(1, 2 | ForEach-Object { Join-Path $root $day.AddDays($_).ToString('yyyy\\MM\\dd') }) } catch { }
        $pattern = '"parent_thread_id"\s*:\s*"' + [regex]::Escape($sessionId) + '"'
        foreach ($dir in $folders) {
            if (-not (Test-Path -LiteralPath $dir -PathType Container)) { continue }
            foreach ($file in (Get-ChildItem -LiteralPath $dir -Filter "rollout-*.jsonl" -File -ErrorAction SilentlyContinue)) {
                if ($file.FullName -eq $rollout -or $file.BaseName -notmatch '([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$') { continue }
                $childId = $Matches[1]
                # session_meta is the first line; in a child rollout payload.session_id is the PARENT's id, the file name holds the child's own.
                $head = Get-TextLines $file.FullName 8
                if ($head -notmatch $pattern) { continue }
                $title = 'subagent'; if ($head -match '"subagent"\s*:\s*(?:\{\s*"[^"]+"\s*:\s*)?"([^"]+)"') { $title = $Matches[1] }
                $subModel = ''; if ($head -match '"model"\s*:\s*"([^"]+)"') { $subModel = $Matches[1] }
                $subs.Add([pscustomobject]@{ chat = "codex:$childId"; title = $title; model = $subModel })
            }
        }
        $script:CodexSubChatCache[$sessionId] = @($subs.ToArray())
    }
    $breakdown = @($toolCounts.GetEnumerator() | Sort-Object @{ Expression = { $_.Value }; Descending = $true }, @{ Expression = { $_.Key } } | Select-Object -First 8 | ForEach-Object { [pscustomobject]@{ name=$_.Key; count=$_.Value } })
    return @{ model = $model; effort = $effort; sessionId = $sessionId; tokens = $tokens; contextWindow = $context; toolCalls = $toolCalls; rateLimits = @($limits); lastActivity = $lastActivity; chat = $chat; subChats = @($subs.ToArray()); rollout = $rollout; records = $records; contextUsed=$contextUsed; steps=$steps; thinkingSteps=$thinkingSteps; toolBreakdown=$breakdown; lastTool=$lastTool; filesTouched=@($filesTouched.ToArray()); backgroundTasks=$subs.Count }
}

function Get-AgyData([string]$OutDir, [string]$Task, $Meta, [bool]$Running, [string]$Worktree) {
    $log = Join-Path $OutDir ("agy-{0}.log" -f $Task); $text = Get-TextLines $log 100
    $model = ''; $session = ''
    if ($text -match 'label="([^"]+)"') { $model = $Matches[1] }
    if ($text -match 'cascade_id:\s*([0-9a-f-]{36})') { $session = $Matches[1] }
    # The runner records the session in meta too; it covers a missing or rotated log.
    if (-not $session) { $metaSession = [string](Get-JsonValue $Meta 'sessionId' ''); if ($metaSession -match '^[0-9a-f-]{36}$') { $session = $metaSession } }
    if (-not $session) { $found = Get-AgyTaskSession $OutDir $Task; $session = $found.session; if (-not $model) { $model = $found.model } }
    if ($session -and -not $model) { $model = Get-AgyModelBySession $session }
    $transcript = if ($session) { Join-Path $script:AgyHome ("brain\{0}\.system_generated\logs\transcript.jsonl" -f $session) } else { '' }
    $cacheKey = if ($transcript) { [IO.Path]::GetFullPath($transcript).ToLowerInvariant() } else { '' }
    $records = if ($transcript) { Read-JsonLinesIncremental $transcript } else { @() }
    $summary = if ($cacheKey -and $script:TranscriptSummaryCache.ContainsKey($cacheKey)) { $script:TranscriptSummaryCache[$cacheKey] } else { @{ tokens=[ordered]@{ input=0L; cached=0L; output=0L; reasoning=0L; total=0L }; toolCalls=0; last=''; first=''; contextUsed=0L; steps=0; thinkingSteps=0; toolCounts=@{}; lastTool=''; filesTouched=@(); backgroundTasks=0; backgroundIds=@{} } }
    $tokens = $summary.tokens; $toolCalls = [int]$summary.toolCalls; $last = [string]$summary.last
    $first = [string]$summary.first; $contextUsed = [long]$summary.contextUsed; $steps = [int]$summary.steps; $thinkingSteps = [int]$summary.thinkingSteps; $toolCounts = $summary.toolCounts; $lastTool = [string]$summary.lastTool; $backgroundIds = $summary.backgroundIds; if ($null -eq $backgroundIds) { $backgroundIds = @{} }; $filesTouched = New-Object System.Collections.Generic.List[string]; foreach ($path in $summary.filesTouched) { $filesTouched.Add($path) }
    foreach ($r in $records) {
        $stamp = Convert-ToIso (Get-JsonValue $r 'created_at' ''); if ($stamp) { if (-not $first) { $first = $stamp }; $last = $stamp }
        if ((Get-JsonValue $r 'type') -eq 'PLANNER_RESPONSE') {
            $steps++; $contextUsed = [long](Get-JsonValue $r 'input_tokens' 0) + [long](Get-JsonValue $r 'cache_read_tokens' 0)
            if ([string](Get-JsonValue $r 'thinking' '')) { $thinkingSteps++ }
            $tokens.input += [long](Get-JsonValue $r 'input_tokens' 0); $tokens.cached += [long](Get-JsonValue $r 'cache_read_tokens' 0); $tokens.output += [long](Get-JsonValue $r 'output_tokens' 0)
            foreach ($call in @(Get-JsonValue $r 'tool_calls' @())) {
                $toolCalls++; $name = [string](Get-JsonValue $call 'name' ''); $lastTool = $name
                if ($name) { if (-not $toolCounts.ContainsKey($name)) { $toolCounts[$name] = 0 }; $toolCounts[$name]++ }
                # manage_task is also called to poll or kill a task, so count distinct task ids.
                if ($name -eq 'manage_task') { $taskArgs = Get-JsonValue $call 'args'; if ($taskArgs -is [string]) { try { $taskArgs = $script:JsonSerializer.DeserializeObject($taskArgs) } catch { $taskArgs = $null } }; $taskId = [string](Get-JsonValue $taskArgs 'TaskId' ''); if ($taskId.StartsWith('"')) { try { $taskId = [string]$script:JsonSerializer.DeserializeObject($taskId) } catch { } }; if (-not $taskId) { $taskId = 'call-' + $toolCalls }; $backgroundIds[$taskId] = $true }
                if ($name -in @('write_file', 'write_to_file', 'edit_file', 'replace_file_content', 'multi_replace_file_content')) {
                    $callArgs = Get-JsonValue $call 'args'; if ($callArgs -is [string]) { try { $callArgs = $script:JsonSerializer.DeserializeObject($callArgs) } catch { $callArgs = $null } }
                    $path = [string](Get-JsonValue $callArgs 'Path' (Get-JsonValue $callArgs 'TargetFile' ''))
                    # agy stores each argument value JSON-encoded, quotes included.
                    if ($path.StartsWith('"')) { try { $path = [string]$script:JsonSerializer.DeserializeObject($path) } catch { } }
                    $path = Get-RelativeTouchedPath $path $Worktree
                    if ($path -and $filesTouched.Count -lt 20 -and -not $filesTouched.Contains($path)) { $filesTouched.Add($path) }
                }
            }
        }
    }
    $tokens.total = $tokens.input + $tokens.output
    if ($cacheKey) { $script:TranscriptSummaryCache[$cacheKey] = @{ tokens=$tokens; toolCalls=$toolCalls; last=$last; first=$first; contextUsed=$contextUsed; steps=$steps; thinkingSteps=$thinkingSteps; toolCounts=$toolCounts; lastTool=$lastTool; filesTouched=@($filesTouched.ToArray()); backgroundIds=$backgroundIds } }
    if (-not $last -and $transcript -and (Test-Path -LiteralPath $transcript)) { try { $last = (Get-Item -LiteralPath $transcript).LastWriteTime.ToString("yyyy-MM-dd'T'HH:mm:ss") } catch { } }
    if ($Meta) { $model = [string](Get-JsonValue $Meta 'model' $model); if (-not $Running -and (Get-JsonValue $Meta 'tokens')) { $tokens = Get-JsonValue $Meta 'tokens' } }
    $agyHasTokens = ($transcript -and (Test-Path -LiteralPath $transcript)) -or (Get-JsonValue $Meta 'tokens')
    $breakdown = @($toolCounts.GetEnumerator() | Sort-Object @{ Expression = { $_.Value }; Descending = $true }, @{ Expression = { $_.Key } } | Select-Object -First 8 | ForEach-Object { [pscustomobject]@{ name=$_.Key; count=$_.Value } })
    return @{ model = $model; effort = [string](Get-JsonValue $Meta 'effort' ''); sessionId = [string](Get-JsonValue $Meta 'sessionId' $session); tokens = $(if ($agyHasTokens) { $tokens } else { $null }); contextWindow = $null; toolCalls = $toolCalls; rateLimits = @(); lastActivity = $last; chat = $(if ($transcript -and (Test-Path -LiteralPath $transcript)) { 'agy:' + $session } else { '' }); subChats = @(); rollout = $transcript; records = $records; started=$first; finished=$(if ($Running) { '' } else { $last }); contextUsed=$contextUsed; steps=$steps; thinkingSteps=$thinkingSteps; toolBreakdown=$breakdown; lastTool=$lastTool; filesTouched=@($filesTouched.ToArray()); backgroundTasks=$backgroundIds.Count }
}

function Get-ClaudeProjectSlug([string]$Path) { return [regex]::Replace([IO.Path]::GetFullPath($Path), '[^A-Za-z0-9]', '-') }

function Get-ClaudeSummary([string]$Path, [string]$Slug, [string]$SessionId, [string]$TaskName = '', [switch]$NoSubagents) {
    # Optional test instrumentation counts summary calls without timing the collector.
    if ($env:TRINITY_DASHBOARD_TEST_CLAUDE_SUMMARY_LOG) { [IO.File]::AppendAllText($env:TRINITY_DASHBOARD_TEST_CLAUDE_SUMMARY_LOG, [IO.Path]::GetFullPath($Path) + "`r`n") }
    $item = Get-Item -LiteralPath $Path
    $cacheKey = [IO.Path]::GetFullPath($Path).ToLowerInvariant()
    $cache = $script:ClaudeSummaryCache[$cacheKey]
    if ($cache -and $cache.length -eq $item.Length -and $cache.lastWriteTimeUtc -eq $item.LastWriteTimeUtc) {
        $cached = $cache.summary; $title = $cached.title; $model = $cached.model; $effort = $cached.effort; $branch = $cached.branch; $cwd = $cached.cwd; $started = $cached.started; $last = $cached.lastActivity; $context = $cached.contextTokens
    }
    else {
        $records = Read-JsonLinesBounded $Path 131072 -HeadAndTail
        $title = ''; $model = ''; $effort = ''; $branch = ''; $cwd = ''; $started = ''; $last = ''; $context = 0L; $seenMessage = @{}
        foreach ($r in $records) {
            $type = [string](Get-JsonValue $r 'type' '')
            $stamp = Convert-ToIso (Get-JsonValue $r 'timestamp' '')
            if ($stamp) { if (-not $started) { $started = $stamp }; $last = $stamp }
            $branch = [string](Get-JsonValue $r 'gitBranch' $branch); $cwd = [string](Get-JsonValue $r 'cwd' $cwd)
            if ($type -eq 'custom-title') { $title = [string](Get-JsonValue $r 'customTitle' $title) }
            elseif ($type -eq 'user' -and -not (Get-JsonValue $r 'isMeta' $false) -and -not $title) {
                $content = Get-JsonValue (Get-JsonValue $r 'message') 'content'
                if ($content -is [string]) { $title = [regex]::Replace($content, '<system-reminder>.*?</system-reminder>', '', 'Singleline') }
                elseif ($content) { $title = (@($content | ForEach-Object { if ((Get-JsonValue $_ 'type') -eq 'text') { Get-JsonValue $_ 'text' } }) -join ' ') }
            }
            elseif ($type -eq 'assistant') {
                $message = Get-JsonValue $r 'message'; $msgModel = [string](Get-JsonValue $message 'model' '')
                if ($msgModel -and $msgModel -ne '<synthetic>') { $model = $msgModel }
                $effort = [string](Get-JsonValue $r 'effort' $effort)
                $msgId = [string](Get-JsonValue $message 'id' '')
                if ($msgId -and -not $seenMessage.ContainsKey($msgId)) { $seenMessage[$msgId] = $true; $usage = Get-JsonValue $message 'usage'; $context = [long](Get-JsonValue $usage 'input_tokens' 0) + [long](Get-JsonValue $usage 'cache_creation_input_tokens' 0) + [long](Get-JsonValue $usage 'cache_read_input_tokens' 0) }
            }
        }
        # One big tool result can fill the whole tail window; keep the last model and context seen instead of blanking them.
        $modelKey = $Path.ToLowerInvariant()
        if ($model) { $script:ClaudeModelCache[$modelKey] = @{ model = $model; effort = $effort; context = $context } }
        elseif ($script:ClaudeModelCache.ContainsKey($modelKey)) { $known = $script:ClaudeModelCache[$modelKey]; $model = $known.model; if (-not $effort) { $effort = $known.effort }; if (-not $context) { $context = $known.context } }
        $title = (($title -split "`r?`n", 2)[0]).Trim()
        if ($title.Length -gt 100) { $title = $title.Substring(0, 100) }
        if (-not $last) { $last = $item.LastWriteTime.ToString("yyyy-MM-dd'T'HH:mm:ss") }
        $script:ClaudeSummaryCache[$cacheKey] = @{ length=$item.Length; lastWriteTimeUtc=$item.LastWriteTimeUtc; summary=@{ title=$title; model=$model; effort=$effort; branch=$branch; cwd=$cwd; started=$started; lastActivity=$last; contextTokens=$context } }
    }
    $subagents = New-Object System.Collections.Generic.List[object]
    $subDir = Join-Path (Join-Path (Join-Path $script:ClaudeHome 'projects') $Slug) (Join-Path $SessionId 'subagents')
    if (-not $NoSubagents -and (Test-Path -LiteralPath $subDir -PathType Container)) {
        foreach ($file in (Get-ChildItem -LiteralPath $subDir -Filter 'agent-*.jsonl' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 20)) {
            $id = [IO.Path]::GetFileNameWithoutExtension($file.Name) -replace '^agent-', ''
            $metaPath = Join-Path $subDir ("agent-{0}.meta.json" -f $id); $meta = $null
            if (Test-Path -LiteralPath $metaPath) { try { $metaItem = Get-Item -LiteralPath $metaPath; $metaKey = 'meta:' + [IO.Path]::GetFullPath($metaPath).ToLowerInvariant(); $metaCache = $script:ClaudeSummaryCache[$metaKey]; if ($metaCache -and $metaCache.lastWriteTimeUtc -eq $metaItem.LastWriteTimeUtc) { $meta = $metaCache.value } else { $meta = $script:JsonSerializer.DeserializeObject([IO.File]::ReadAllText($metaPath)); $script:ClaudeSummaryCache[$metaKey] = @{ lastWriteTimeUtc=$metaItem.LastWriteTimeUtc; value=$meta } } } catch { } }
            $sub = Get-ClaudeSummary $file.FullName $Slug $SessionId '' -NoSubagents
            $finished = [bool](Get-JsonValue $meta 'finished' $false)
            $subagents.Add([pscustomobject]@{ id = $id; description = [string](Get-JsonValue $meta 'description' ''); type = [string](Get-JsonValue $meta 'agentType' ''); model = [string](Get-JsonValue $meta 'model' $sub.model); finished = $finished; active = (-not $finished -and $file.LastWriteTime -gt (Get-Date).AddSeconds(-120)); lastActivity = $sub.lastActivity; chat = "claude:${Slug}:${SessionId}:$id" })
        }
    }
    return @{ id = $SessionId; title = $title; model = $model; effort = $effort; branch = $branch; cwd = $cwd; started = $started; lastActivity = $last; active = ((Get-Item -LiteralPath $Path).LastWriteTime -gt (Get-Date).AddSeconds(-120)); contextTokens = $context; task = $TaskName; chat = "claude:${Slug}:${SessionId}"; subagents = @($subagents.ToArray()) }
}

function Get-ClaudeSessions([string]$Main, $Tasks) {
    $sessions = New-Object System.Collections.Generic.List[object]
    $files = New-Object System.Collections.Generic.List[object]
    $slugs = New-Object System.Collections.Generic.List[string]
    $slugs.Add((Get-ClaudeProjectSlug $Main))
    foreach ($task in $Tasks) { if ($task.agent -eq 'claude' -and $task.worktree -and $task.worktree -ne '-') { $slugs.Add((Get-ClaudeProjectSlug $task.worktree)) } }
    foreach ($slug in ($slugs | Select-Object -Unique)) {
        $folder = Join-Path (Join-Path $script:ClaudeHome 'projects') $slug
        if (-not (Test-Path -LiteralPath $folder -PathType Container)) { continue }
        foreach ($file in (Get-ChildItem -LiteralPath $folder -Filter '*.jsonl' -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -gt (Get-Date).AddDays(-7) })) { $files.Add([pscustomobject]@{ file=$file; slug=$slug }) }
    }
    foreach ($candidate in ($files | Sort-Object { $_.file.LastWriteTime } -Descending | Select-Object -First 5)) {
            $file = $candidate.file; $slug = $candidate.slug
            $id = [IO.Path]::GetFileNameWithoutExtension($file.Name)
            $linked = @($Tasks | Where-Object { $_.sessionId -eq $id } | Select-Object -First 1)
            $taskName = if ($linked.Count) { $linked[0].task } else { '' }
            $summary = Get-ClaudeSummary $file.FullName $slug $id $taskName
            $sessions.Add([pscustomobject]$summary)
        }
    return @($sessions | Sort-Object { $_.lastActivity } -Descending)
}

function Resolve-Chat([string]$Key) {
    $kind = Get-ChatKeyKind $Key
    if (-not $kind) { return @{ status = 400; value = $null } }
    $file = ''; $title = ''; $model = ''; $id = $Key
    if ($kind -eq 'codex') { $session = $Key.Substring(6); $file = Get-CodexRollout $session ''; $title = $session }
    elseif ($kind -eq 'agy') {
        $session = $Key.Substring(4); $file = Join-Path $script:AgyHome ("brain\{0}\.system_generated\logs\transcript.jsonl" -f $session); $title = $session
    }
    else {
        $parts = $Key -split ':'; $slug = $parts[1]; $session = $parts[2]; $agentId = if ($parts.Count -eq 4) { $parts[3] } else { '' }
        $base = Join-Path (Join-Path $script:ClaudeHome 'projects') $slug
        if ($agentId) { $file = Join-Path $base (Join-Path $session (Join-Path 'subagents' ("agent-{0}.jsonl" -f $agentId))) }
        else { $file = Join-Path $base ("{0}.jsonl" -f $session) }
        if ($agentId) { $metaPath = Join-Path $base (Join-Path $session (Join-Path 'subagents' ("agent-{0}.meta.json" -f $agentId))); if (Test-Path -LiteralPath $metaPath) { try { $meta = $script:JsonSerializer.DeserializeObject([IO.File]::ReadAllText($metaPath)); $title = [string](Get-JsonValue $meta 'description' ''); $model = [string](Get-JsonValue $meta 'model' '') } catch { } } }
        if (-not $agentId -and (Test-Path -LiteralPath $file -PathType Leaf)) { $summary = Get-ClaudeSummary $file $slug $session '' -NoSubagents; $title = $summary.title; $model = $summary.model }
    }
    if (-not $file -or -not (Test-Path -LiteralPath $file -PathType Leaf)) { return @{ status = 404; value = $null } }
    if ($kind -in @('codex','agy')) { $taskInfo = Get-ChatTaskInfo $kind $session; $title = $taskInfo.title; $model = $taskInfo.model; if (-not $title) { $title = $session } }
    $script:JsonLinesDroppedLong = $false
    $records = Read-JsonLinesBounded $file 4194304
    $messages = New-Object System.Collections.Generic.List[object]; $truncated = ((Get-Item -LiteralPath $file).Length -gt 4194304) -or $script:JsonLinesDroppedLong; $updated = ''
    foreach ($r in $records) {
        $stamp = Convert-ToIso (Get-JsonValue $r 'timestamp' (Get-JsonValue $r 'created_at' '')); $type = [string](Get-JsonValue $r 'type' '')
        if ($kind -eq 'codex') {
            $p = Get-JsonValue $r 'payload'; $pt = [string](Get-JsonValue $p 'type' '')
            if ($type -eq 'response_item' -and $pt -eq 'message') { $role = [string](Get-JsonValue $p 'role' ''); if ($role -ne 'developer') { foreach ($c in (Get-JsonValue $p 'content' @())) { if ((Get-JsonValue $c 'type') -in @('input_text','output_text')) { $messages.Add([pscustomobject]@{ at=$stamp; role=$(if ($role -eq 'user') {'user'} else {'assistant'}); name=''; text=(Get-JsonValue $c 'text' '') }) } } } }
            elseif ($type -eq 'response_item' -and $pt -in @('custom_tool_call','function_call')) { $messages.Add([pscustomobject]@{ at=$stamp; role='tool'; name=(Get-JsonValue $p 'name' ''); text=(Get-JsonValue $p 'input' (Get-JsonValue $p 'arguments' '')) | ConvertTo-Json -Compress -Depth 8 }) }
            elseif ($type -eq 'response_item' -and $pt -in @('custom_tool_call_output','function_call_output')) { $out = Get-JsonValue $p 'output' ''; if ($out -isnot [string]) { $out = $out | ConvertTo-Json -Compress -Depth 8 }; $messages.Add([pscustomobject]@{ at=$stamp; role='result'; name=''; text=$out }) }
            elseif ($type -eq 'response_item' -and $pt -eq 'reasoning') { $sum = @((Get-JsonValue $p 'summary' @()) | ForEach-Object { Get-JsonValue $_ 'text' }) -join "`n"; if ($sum) { $messages.Add([pscustomobject]@{ at=$stamp; role='thinking'; name=''; text=$sum }) } }
        }
        elseif ($kind -eq 'agy') {
            switch ($type) {
                USER_INPUT { $messages.Add([pscustomobject]@{ at=$stamp; role='user'; name=''; text=(Get-JsonValue $r 'content' '') }) }
                PLANNER_RESPONSE { $thinking = Get-JsonValue $r 'thinking' ''; if ($thinking) { $messages.Add([pscustomobject]@{ at=$stamp; role='thinking'; name=''; text=$thinking }) }; $content = Get-JsonValue $r 'content' ''; if ($content) { $messages.Add([pscustomobject]@{ at=$stamp; role='assistant'; name=''; text=$content }) }; foreach ($tool in (Get-JsonValue $r 'tool_calls' @())) { $messages.Add([pscustomobject]@{ at=$stamp; role='tool'; name=(Get-JsonValue $tool 'name' ''); text=(Get-JsonValue $tool 'args' @{}) | ConvertTo-Json -Compress -Depth 8 }) } }
                GENERIC { $messages.Add([pscustomobject]@{ at=$stamp; role='result'; name=''; text=(Get-JsonValue $r 'content' '') }) }
                SYSTEM_MESSAGE { $messages.Add([pscustomobject]@{ at=$stamp; role='system'; name=''; text=(Get-JsonValue $r 'content' '') }) }
            }
        }
        else {
            if ($type -eq 'user' -and -not (Get-JsonValue $r 'isMeta' $false)) {
                $content = Get-JsonValue (Get-JsonValue $r 'message') 'content'
                if ($content -is [string]) { $content = [regex]::Replace($content, '<system-reminder>.*?</system-reminder>', '', 'Singleline'); if ($content.Trim()) { $messages.Add([pscustomobject]@{ at=$stamp; role='user'; name=''; text=$content }) } }
                elseif ($content) { foreach ($part in $content) { if ((Get-JsonValue $part 'type') -eq 'text') { $body=[regex]::Replace([string](Get-JsonValue $part 'text' ''), '<system-reminder>.*?</system-reminder>', '', 'Singleline'); if ($body.Trim()) { $messages.Add([pscustomobject]@{ at=$stamp; role='user'; name=''; text=$body }) } } elseif ((Get-JsonValue $part 'type') -eq 'tool_result') { $messages.Add([pscustomobject]@{ at=$stamp; role='result'; name=''; text=(Get-JsonValue $part 'content' '') }) } } }
            }
            elseif ($type -eq 'assistant') { foreach ($part in (Get-JsonValue (Get-JsonValue $r 'message') 'content' @())) { $role='assistant'; $name=''; $body=''; if (Get-JsonValue $part 'text') { $body=Get-JsonValue $part 'text' } elseif (Get-JsonValue $part 'thinking') { $role='thinking'; $body=Get-JsonValue $part 'thinking' } elseif ((Get-JsonValue $part 'type') -eq 'tool_use') { $role='tool'; $name=Get-JsonValue $part 'name' ''; $body=(Get-JsonValue $part 'input' @{}) | ConvertTo-Json -Compress -Depth 8 } elseif (Get-JsonValue $part 'tool_use') { $tool=Get-JsonValue $part 'tool_use'; $role='tool'; $name=Get-JsonValue $tool 'name' ''; $body=(Get-JsonValue $tool 'input' @{}) | ConvertTo-Json -Compress -Depth 8 }; if ($body) { $messages.Add([pscustomobject]@{ at=$stamp; role=$role; name=$name; text=$body }) } } }
            if (-not $title -and $type -eq 'custom-title') { $title = [string](Get-JsonValue $r 'customTitle' '') }
        }
        if ($stamp) { $updated = $stamp }
    }
    if (-not $updated) { try { $updated = (Get-Item -LiteralPath $file).LastWriteTime.ToString("yyyy-MM-dd'T'HH:mm:ss") } catch { } }
    if ($messages.Count -gt 300) { $messages = New-Object System.Collections.Generic.List[object] (,$messages.ToArray()[($messages.Count - 300)..($messages.Count - 1)]); $truncated = $true }
    foreach ($m in $messages) { $max = if ($m.role -in @('tool','result')) { 1500 } else { 4000 }; $rawText = if ($m.text -is [string]) { $m.text } else { $m.text | ConvertTo-Json -Compress -Depth 8 }; $clean = Get-Redacted ([string]$rawText); if ($clean.Length -gt $max) { $clean = $clean.Substring(0, $max - 3) + '...'; $truncated = $true }; $m.text = $clean }
    if (-not $title) { $title = $session }
    return @{ status = 200; value = [pscustomobject]@{ id=$id; agent=$(if ($kind -eq 'agy') {'antigravity'} else {$kind}); title=$title; model=$model; updated=$updated; truncated=$truncated; messages=@($messages.ToArray()) } }
}

function Get-ChatTaskInfo([string]$Agent, [string]$SessionId) {
    $paths = New-Object System.Collections.Generic.List[string]
    foreach ($candidate in $Repos) { if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Container)) { $paths.Add($candidate) } }
    $trinityHome = if ($env:TRINITY_HOME) { $env:TRINITY_HOME } else { Join-Path $env:USERPROFILE '.trinity' }
    $registry = Join-Path $trinityHome 'repos.txt'
    if (Test-Path -LiteralPath $registry -PathType Leaf) { foreach ($line in [IO.File]::ReadAllLines($registry)) { $p=$line.Trim(); if ($p -and (Test-Path -LiteralPath $p -PathType Container)) { $paths.Add($p) } } }
    $paths.Add((Split-Path $PSScriptRoot -Parent))
    foreach ($repo in $paths) {
        $outDir = Join-Path $repo '.codex-out'
        if (-not (Test-Path -LiteralPath $outDir -PathType Container)) { continue }
        foreach ($metaFile in (Get-ChildItem -LiteralPath $outDir -Filter 'meta-*.json' -File -ErrorAction SilentlyContinue)) {
            try { $meta = $script:JsonSerializer.DeserializeObject([IO.File]::ReadAllText($metaFile.FullName)); if ((Get-JsonValue $meta 'sessionId') -eq $SessionId -and ((Get-JsonValue $meta 'agent') -eq $Agent -or ($Agent -eq 'agy' -and (Get-JsonValue $meta 'agent') -eq 'antigravity'))) { return @{ title=($metaFile.BaseName -replace '^meta-', ''); model=[string](Get-JsonValue $meta 'model' ''); effort=[string](Get-JsonValue $meta 'effort' '') } } } catch { }
        }
        $pattern = if ($Agent -eq 'codex') { "session id:\s*$([regex]::Escape($SessionId))" } else { "cascade_id:\s*$([regex]::Escape($SessionId))" }
        foreach ($logFile in (Get-ChildItem -LiteralPath $outDir -Filter $(if ($Agent -eq 'codex') { 'log-*.txt' } else { 'agy-*.log' }) -File -ErrorAction SilentlyContinue)) {
            $text = Get-TextLines $logFile.FullName 100
            if ($text -match $pattern) { $model=''; $effort=''; if ($text -match '(?im)^model:\s*(.+)$') { $model=$Matches[1].Trim() }; if ($text -match '(?im)^reasoning effort:\s*(.+)$') { $effort=$Matches[1].Trim() }; if ($Agent -eq 'agy' -and $text -match 'label="([^"]+)"') { $model=$Matches[1] }; return @{ title=($logFile.BaseName -replace '^(log|agy)-', ''); model=$model; effort=$effort } }
        }
    }
    return @{ title=''; model=''; effort='' }
}

function Invoke-GitRead([string]$Directory, [string[]]$Arguments, [switch]$Bounded, [int]$MaxChars = 262144) {
    if ($Bounded) {
        # No shell; quote each array element for Windows native argument parsing.
        $info = New-Object Diagnostics.ProcessStartInfo
        $info.FileName = 'git'; $info.UseShellExecute = $false; $info.CreateNoWindow = $true
        $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
        $info.StandardOutputEncoding = [Text.Encoding]::UTF8
        $nativeArgs = @('-C', $Directory) + $Arguments
        $info.Arguments = (@($nativeArgs | ForEach-Object { '"' + ([regex]::Replace(([regex]::Replace($_, '(\\*)"', '$1$1\"')), '(\\+)$', '$1$1')) + '"' }) -join ' ')
        $process = New-Object Diagnostics.Process; $process.StartInfo = $info
        try {
            [void]$process.Start(); $errors = $process.StandardError.BaseStream.CopyToAsync([IO.Stream]::Null)
            $text = New-Object Text.StringBuilder; $buffer = New-Object char[] 4096
            $deadline = [datetime]::UtcNow.AddSeconds(4); $truncated = $false
            while ($true) {
                $pending = $process.StandardOutput.ReadAsync($buffer, 0, $buffer.Length)
                $remaining = [int][Math]::Max(0, ($deadline - [datetime]::UtcNow).TotalMilliseconds)
                if (-not $pending.Wait($remaining)) { throw 'Git read timed out' }
                $count = $pending.Result; if ($count -eq 0) { break }
                $take = [Math]::Min($count, $MaxChars - $text.Length)
                if ($take -gt 0) { [void]$text.Append($buffer, 0, $take) }
                if ($take -lt $count) { $truncated = $true; break }
            }
            if ($truncated -and -not $process.HasExited) { $process.Kill() }
            if (-not $process.WaitForExit([int][Math]::Max(1, ($deadline - [datetime]::UtcNow).TotalMilliseconds))) { throw 'Git read timed out' }
            return @{ text=$text.ToString(); code=$process.ExitCode; truncated=$truncated }
        }
        finally { if ($process.Id -and -not $process.HasExited) { $process.Kill(); [void]$process.WaitForExit(1000) }; $process.Dispose() }
    }
    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $output = & git -C $Directory @Arguments 2>$null }
    finally { $ErrorActionPreference = $oldPreference }
    if ($LASTEXITCODE -ne 0) { return $null }
    return ($output -join "`n").Trim()
}

function Read-TaskGit([string]$Repo, [string[]]$Arguments, [int]$Limit = 262144) {
    $result = Invoke-GitRead $Repo $Arguments -Bounded -MaxChars $Limit
    if ($result.code -ne 0 -or $result.truncated) { throw 'Git read failed or exceeded output limit' }
    return $result.text
}

function Get-TaskDiff([string]$Repo, $Task) {
    $range = 'main...' + $Task.branch
    $names = Read-TaskGit $Repo @('-c','core.quotepath=false','diff','--no-ext-diff','--no-textconv','--name-status','-z','--find-renames',$range,'--')
    $nums = Read-TaskGit $Repo @('-c','core.quotepath=false','diff','--no-ext-diff','--no-textconv','--numstat','-z','--find-renames',$range,'--')
    $statuses=@{}; $parts=$names.Split([char]0)
    for ($i=0; $i -lt $parts.Length-1; $i++) {
        $status=$parts[$i]; $i++; $path=$parts[$i]
        if ($status -match '^R') { $i++; $path=$parts[$i] }
        $statuses[$path]=if ($status -eq 'T') { 'M' } else { $status.Substring(0,1) }
    }
    $files=@(); $added=0; $deleted=0; $parts=$nums.Split([char]0)
    for ($i=0; $i -lt $parts.Length; $i++) {
        if ($parts[$i] -match '^(\d+|-)\t(\d+|-)\t(.*)$') {
            $binary=$Matches[1] -eq '-'; $a=0; $d=0; $path=$Matches[3]
            if (-not $binary) { $a=[int]$Matches[1]; $d=[int]$Matches[2] }
            if (-not $path) { $i+=2; $path=$parts[$i] }
            $files+=@{ path=$path; status=$statuses[$path]; added=$a; deleted=$d; binary=$binary }; $added+=$a; $deleted+=$d
        }
    }
    $patch = Invoke-GitRead $Repo @('diff','--no-ext-diff','--no-textconv','--no-color','--find-renames',$range,'--') -Bounded -MaxChars 204800
    if ($patch.code -ne 0 -and -not $patch.truncated) { throw 'Git diff failed' }
    $text=$patch.text; $truncated=$patch.truncated
    # Limit UTF-8 bytes too, and always cut a truncated patch at a line boundary.
    while ([Text.Encoding]::UTF8.GetByteCount($text) -gt 204800) { $text=$text.Substring(0,[Math]::Max(0,$text.Length-1024)); $truncated=$true }
    if ($truncated) { $last=$text.LastIndexOf("`n"); if ($last -ge 0) { $text=$text.Substring(0,$last+1) } else { $text='' } }
    return @{ task=$Task.task; branch=$Task.branch; base='main'; files=@($files); stat=@{ files=$files.Count; added=$added; deleted=$deleted }; patch=$text; truncated=$truncated }
}

function Get-TaskLog([string]$Repo, $Task, [long]$Offset) {
    $file = 'log-' + $Task.task + '.txt'
    if ($Task.agent -eq 'antigravity') { $file='agy-' + $Task.task + '.log' }
    $path=Join-Path (Join-Path $Repo '.codex-out') $file
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return @{ size=0; offset=0; nextOffset=0; text=''; reset=$false; exists=$false } }
    $stream=New-Object IO.FileStream($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
    try {
        $size=$stream.Length; $reset=$Offset -gt $size
        if ($Offset -lt 0 -or $reset) { $Offset=[Math]::Max(0,$size-16384) }
        [void]$stream.Seek($Offset,[IO.SeekOrigin]::Begin); $buffer=New-Object byte[] ([int][Math]::Min(65536,$size-$Offset)); $read=0
        while ($read -lt $buffer.Length) { $n=$stream.Read($buffer,$read,$buffer.Length-$read); if ($n -eq 0) { break }; $read+=$n }
        $start=0; $end=$read
        # A tail or caller offset can begin inside a UTF-8 character.
        if ($Offset -gt 0) { while ($start -lt $end -and ($buffer[$start] -band 0xC0) -eq 0x80) { $start++ } }
        if ($end -gt $start) {
            $lead=$end-1
            while ($lead -gt $start -and ($buffer[$lead] -band 0xC0) -eq 0x80) { $lead-- }
            $byte=$buffer[$lead]; $width=1
            if ($byte -ge 0xC2 -and $byte -le 0xDF) { $width=2 }
            elseif ($byte -ge 0xE0 -and $byte -le 0xEF) { $width=3 }
            elseif ($byte -ge 0xF0 -and $byte -le 0xF4) { $width=4 }
            # Leave a partial character for the next poll, including at EOF.
            if ($end-$lead -lt $width) { $end=$lead }
        }
        $text=Get-Redacted ([Text.Encoding]::UTF8.GetString($buffer,$start,$end-$start))
        $text=[regex]::Replace($text,'[\x00-\x08\x0b-\x1f\x7f]',{ param($m) '\x{0:x2}' -f [int][char]$m.Value })
        return @{ size=$size; offset=$Offset; nextOffset=($Offset+$end); text=$text; reset=$reset; exists=$true }
    } finally { $stream.Dispose() }
}

function Get-TaskMergeCheck([string]$Repo, $Task) {
    $blockers=New-Object Collections.Generic.List[object]
    if ($Task.state -ne 'done') { $blockers.Add(@{ id='not-done'; label='Task is not done'; severity='block'; detail=[string]$Task.state }) }
    $pidPath=Join-Path $Repo ('.codex-out\pid-' + $Task.task + '.txt'); $alive=$false
    if (Test-Path -LiteralPath $pidPath) { $pidText=(Get-HeadText $pidPath 64).Trim(); $runnerId=0; if ([int]::TryParse($pidText,[ref]$runnerId) -and $runnerId -gt 0) { $alive=[bool](Get-Process -Id $runnerId -ErrorAction SilentlyContinue) } }
    if ($alive) { $blockers.Add(@{ id='runner-alive'; label='Runner is alive'; severity='block'; detail='Runner process is still running' }) }
    $counts=(Read-TaskGit $Repo @('rev-list','--left-right','--count',('main...' + $Task.branch),'--')).Trim() -split '\s+'
    $behind=[int]$counts[0]; $ahead=[int]$counts[1]
    if ($ahead -eq 0) { $blockers.Add(@{ id='no-commits'; label='No commits'; severity='block'; detail='Branch has no commits ahead of main' }) }
    if ((Read-TaskGit $Repo @('status','--porcelain','--untracked-files=normal')).Trim()) { $blockers.Add(@{ id='main-dirty'; label='Main is dirty'; severity='block'; detail='Main checkout has uncommitted changes' }) }
    $head=(Read-TaskGit $Repo @('rev-parse','--short','main')).Trim()
    $conflicts=@(); $merge=Invoke-GitRead $Repo @('merge-tree','--write-tree','--name-only','main',('refs/heads/' + $Task.branch)) -Bounded
    if ($merge.truncated) { throw 'Merge check exceeded output limit' }
    if ($merge.code -eq 1) {
        $lines=$merge.text -split "`n"; foreach ($line in ($lines | Select-Object -Skip 1)) { if (-not $line.Trim()) { break }; $conflicts+=$line.TrimEnd("`r") }
        $blockers.Add(@{ id='conflicts'; label='Merge conflicts'; severity='block'; detail='Branch conflicts with main' })
    } elseif ($merge.code -eq 129) { $blockers.Add(@{ id='conflicts-unchecked'; label='Conflicts unchecked'; severity='warn'; detail='Git merge-tree --write-tree is unavailable' }) } elseif ($merge.code -ne 0) { throw 'Git merge check failed' }
    $violations=@(); $scope=[string]$Task.scope
    if ($scope -and $scope -ne '-' -and $scope -ne 'unspecified') {
        $globs=@($scope.Split(',') | ForEach-Object { '^' + [regex]::Escape($_.Trim().Replace('\','/')).Replace('\*','.*') + '$' })
        $paths=Read-TaskGit $Repo @('-c','core.quotepath=false','diff','--name-only','--no-renames',('main...' + $Task.branch),'--')
        foreach ($path in ($paths -split "`n")) { if (-not $path) { continue }; $matched=$false; foreach ($glob in $globs) { if ($path -match $glob) { $matched=$true; break } }; if (-not $matched) { $violations+=$path } }
        if ($violations.Count) { $blockers.Add(@{ id='scope-violation'; label='Outside scope'; severity='block'; detail='Branch changes files outside task scope' }) }
    }
    if ($behind -gt 0) { $blockers.Add(@{ id='behind-main'; label='Behind main'; severity='warn'; detail='re-review recommended' }) }
    return @{ task=$Task.task; branch=$Task.branch; canMerge=(@($blockers | Where-Object { $_.severity -eq 'block' }).Count -eq 0); blockers=@($blockers.ToArray()); conflicts=@($conflicts); scopeViolations=@($violations); ahead=$ahead; behind=$behind; mainHead=$head; checkedAt=(Get-Date).ToString('o') }
}

function Get-TextLines([string]$Path, [int]$Limit, [switch]$Tail) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
    # Agent output is UTF-8 (Get-Content in PS 5.1 would read it as ANSI). Read at most 64 KB from the head or
    # the tail, since logs grow to megabytes, and share ReadWrite so a running agent's log is readable mid-write.
    $text = ''
    $partial = $false
    try {
        $stream = New-Object IO.FileStream($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        try {
            $count = [int][Math]::Min($stream.Length, 65536)
            if ($Tail -and $stream.Length -gt $count) { [void]$stream.Seek(-$count, [IO.SeekOrigin]::End); $partial = $true }
            $buffer = New-Object byte[] $count
            $read = 0
            while ($read -lt $count) {
                $n = $stream.Read($buffer, $read, $count - $read)
                if ($n -le 0) { break }
                $read += $n
            }
            $text = [Text.Encoding]::UTF8.GetString($buffer, 0, $read)
        }
        finally { $stream.Dispose() }
    }
    catch { return '' }
    $lines = @($text.TrimStart([char]0xFEFF).TrimEnd("`r", "`n") -split "`r?`n")
    # A tail read starts mid-line (maybe mid-character); drop that fragment.
    if ($partial -and $lines.Count -gt 1) { $lines = $lines[1..($lines.Count - 1)] }
    if ($Tail -and $lines.Count -gt $Limit) { $lines = $lines[($lines.Count - $Limit)..($lines.Count - 1)] }
    elseif (-not $Tail -and $lines.Count -gt $Limit) { $lines = $lines[0..($Limit - 1)] }
    return ($lines -join "`n")
}

function Get-TaskState([string]$Status, [bool]$RunnerAlive) {
    if ($Status -match '\(stalled') { return 'stalled' }
    if ($RunnerAlive -or $Status -match '^(started|running|working)(\s|:|$)') { return 'running' }
    if ($Status -match '^ready') { return 'ready' }
    if ($Status -match '^failed') { return 'failed' }
    if ($Status -match '^merged') { return 'merged' }
    if ($Status -match '^cancelled') { return 'cancelled' }
    if ($Status -match '^done') { return 'done' }
    if ($Status -match '^waiting') { return 'waiting' }
    return 'other'
}

function Test-TaskActionState([string]$Action, [string]$State, [bool]$HasWorktree, [string]$Branch) {
    return -not (($Action -eq 'cancel' -and $State -in @('merged','cancelled')) -or ($Action -eq 'merge' -and $State -notin @('done','ready')) -or ($Action -in @('review-task','open-folder') -and (-not $HasWorktree -or -not $Branch -or $Branch -eq '-')))
}

function Get-RepoTasks([string]$Main, [string]$Common) {
    $boardPath = Join-Path $Common 'agent-board.md'
    if (-not (Test-Path -LiteralPath $boardPath -PathType Leaf)) { return @() }
    $sections = New-Object System.Collections.Generic.List[object]
    $entry = $null
    foreach ($line in [IO.File]::ReadAllLines($boardPath)) {
        if ($line -match '^##\s+(.+)$') {
            if ($entry) { $sections.Add($entry) }
            $entry = [ordered]@{ task = $Matches[1].Trim(); agent = ''; branch = ''; worktree = ''; scope = ''; status = ''; session = '' }
        }
        elseif ($entry -and $line -match '^-\s+(agent|branch|worktree|scope|status|session):\s*(.*)$') {
            $entry[$Matches[1]] = $Matches[2].Trim()
        }
    }
    if ($entry) { $sections.Add($entry) }

    $outDir = Join-Path $Main '.codex-out'
    # Commits ahead of main for every branch in one git call (git 2.41+); older git falls back to rev-list per task.
    $aheadOf = @{}
    $refs = Invoke-GitRead $Main @('for-each-ref', '--format=%(refname:short) %(ahead-behind:main)', 'refs/heads')
    $batched = [bool]$refs
    if (-not $batched) { $refs = Invoke-GitRead $Main @('for-each-ref', '--format=%(refname:short)', 'refs/heads') }
    if ($refs) {
        foreach ($line in ($refs -split "`n")) {
            $parts = @($line.Trim() -split '\s+')
            if (-not $parts[0]) { continue }
            $aheadOf[$parts[0]] = $null
            if ($batched -and $parts.Count -ge 2 -and $parts[1] -match '^\d+$') { $aheadOf[$parts[0]] = [int]$parts[1] }
        }
    }
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
        if ($item.branch -and $item.branch -ne '-' -and $aheadOf.ContainsKey($item.branch)) {
            if ($null -ne $aheadOf[$item.branch]) { $commits = $aheadOf[$item.branch] }
            else {
                $count = Invoke-GitRead $Main @('rev-list', '--count', "main..$($item.branch)")
                if ($count -match '^\d+$') { $commits = [int]$count }
            }
        }
        $result = Get-Redacted (Get-TextLines (Join-Path $outDir ("result-{0}.md" -f $item.task)) 15)
        $logTail = Get-Redacted (Get-TextLines (Join-Path $outDir ("log-{0}.txt" -f $item.task)) 15 -Tail)
        $meta = $null
        $metaPath = Join-Path $outDir ("meta-{0}.json" -f $item.task)
        if (Test-Path -LiteralPath $metaPath -PathType Leaf) { try { $meta = $script:JsonSerializer.DeserializeObject([IO.File]::ReadAllText($metaPath)) } catch { } }
        $detail = @{ model=''; effort=''; sessionId=''; started=''; finished=''; durationSec=$null; lastActivity=''; tokens=$null; contextWindow=$null; toolCalls=0; rateLimits=@(); chat=''; subChats=@(); contextUsed=0L; steps=0; thinkingSteps=0; toolBreakdown=@(); lastTool=''; filesTouched=@(); backgroundTasks=0 }
        if ($item.agent -eq 'codex') { $detail = Get-CodexData $outDir $item.task $meta ($state -eq 'running') $item.worktree }
        elseif ($item.agent -eq 'antigravity') { $detail = Get-AgyData $outDir $item.task $meta ($state -eq 'running') $item.worktree }
        else {
            $detail.sessionId = [string]$item.session
            if ($item.session -match '^[0-9a-fA-F-]{36}$') {
                foreach ($slug in @((Get-ClaudeProjectSlug $Main), $(if ($item.worktree -and $item.worktree -ne '-') { Get-ClaudeProjectSlug $item.worktree }))) {
                    $claudeFile = Join-Path (Join-Path (Join-Path $script:ClaudeHome 'projects') $slug) ("{0}.jsonl" -f $item.session)
                    if (Test-Path -LiteralPath $claudeFile -PathType Leaf) {
                        $summary = Get-ClaudeSummary $claudeFile $slug $item.session '' -NoSubagents
                        $detail.chat = "claude:${slug}:$($item.session)"; $detail.model = $summary.model; $detail.effort = $summary.effort; $detail.started = $summary.started; $detail.lastActivity = $summary.lastActivity
                        break
                    }
                }
            }
        }
        $started = Convert-ToIso (Get-JsonValue $meta 'started' $detail.started)
        if (-not $started) { $started = $detail.started }
        $finished = Convert-ToIso (Get-JsonValue $meta 'finished' $detail.finished)
        if (-not $detail.sessionId) { $detail.sessionId = [string](Get-JsonValue $meta 'sessionId' '') }
        $duration = Get-JsonValue $meta 'durationSec'
        if ($null -eq $duration -and $started) { try { $begin = [datetime]::Parse($started); $end = if ($finished) { [datetime]::Parse($finished) } else { Get-Date }; $duration = [Math]::Round(($end - $begin).TotalSeconds, 1) } catch { } }
        $detail.model = [string](Get-JsonValue $meta 'model' $detail.model)
        $detail.effort = [string](Get-JsonValue $meta 'effort' $detail.effort)
        if ($meta -and $state -ne 'running' -and (Get-JsonValue $meta 'lastActivity')) { $detail.lastActivity = Convert-ToIso (Get-JsonValue $meta 'lastActivity') }
        if ($meta -and (Get-JsonValue $meta 'tokens') -and $state -ne 'running') { $detail.tokens = Get-JsonValue $meta 'tokens' }
        if (-not $detail.lastActivity) {
            $activityPath = if ($detail.rollout) { $detail.rollout } elseif ($item.agent -eq 'antigravity') { Join-Path $outDir ("agy-{0}.log" -f $item.task) } else { Join-Path $outDir ("log-{0}.txt" -f $item.task) }
            if ($activityPath -and (Test-Path -LiteralPath $activityPath -PathType Leaf)) { try { $detail.lastActivity = (Get-Item -LiteralPath $activityPath).LastWriteTime.ToString("yyyy-MM-dd'T'HH:mm:ss") } catch { } }
        }
        $lastActivity = $detail.lastActivity
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
            model = [string]$detail.model
            effort = [string]$detail.effort
            sessionId = [string]$detail.sessionId
            started = $started
            finished = $finished
            durationSec = $duration
            lastActivity = $lastActivity
            tokens = $detail.tokens
            contextWindow = $detail.contextWindow
            toolCalls = [int]$detail.toolCalls
            contextUsed = [long]$detail.contextUsed
            steps = [int]$detail.steps
            thinkingSteps = [int]$detail.thinkingSteps
            toolBreakdown = @($detail.toolBreakdown)
            lastTool = [string]$detail.lastTool
            filesTouched = @($detail.filesTouched)
            backgroundTasks = [int]$detail.backgroundTasks
            rateLimits = @($detail.rateLimits)
            chat = [string]$detail.chat
            subChats = @($detail.subChats)
            worktree = [string]$item.worktree
        })
    }
    return @($tasks | Sort-Object @{ Expression = { if ($_.state -eq 'running') { 0 } else { 1 } } }, @{ Expression = { $_.updated }; Descending = $true })
}

$script:TrinityFileCache = @{}
$script:DecisionCache = @{}
function Read-TrinityFile([string]$Path) {
    try {
        $file = Get-Item -LiteralPath $Path -ErrorAction Stop
        $key = $file.FullName.ToLowerInvariant(); $stamp = $file.LastWriteTimeUtc.Ticks; $length = $file.Length
        $cached = $script:TrinityFileCache[$key]
        if ($cached -and $cached.stamp -eq $stamp -and $cached.length -eq $length) { return $cached.text }
        $text = [IO.File]::ReadAllText($file.FullName)
        $script:TrinityFileCache[$key] = @{ stamp=$stamp; length=$length; text=$text }
        return $text
    } catch { if (Test-Path -LiteralPath $Path) { throw }; $key=[IO.Path]::GetFullPath($Path).ToLowerInvariant(); $script:TrinityFileCache.Remove($key); return '' }
}
function Merge-TrinityDefaults($Defaults, $Patch) {
    foreach ($key in @($Patch.Keys)) {
        if ($Defaults.ContainsKey($key) -and $Defaults[$key] -is [System.Collections.IDictionary] -and $Patch[$key] -is [System.Collections.IDictionary]) { Merge-TrinityDefaults $Defaults[$key] $Patch[$key] }
        else { $Defaults[$key] = $Patch[$key] }
    }
}
function Get-TrinityState([string]$Root, $Tasks) {
    $dir = Join-Path $Root '.trinity'; $errorText = ''
    $config = @{ version=1; slots=@{codex=2; antigravity=1; claude=1}; base=''; test=''; autoMerge=$false; maxRounds=3; deadlineMinutes=120; models=@{codex=''; antigravity=''; claude=''}; autopilot=@{enabled=$false; approval=$true; maxTasksPerHour=6; maxConsecutiveFailures=3; cleanRunsBeforeAutoMerge=10} }
    try { $raw=Read-TrinityFile (Join-Path $dir 'trinity.json'); if ($raw) { $patch=$script:JsonSerializer.DeserializeObject($raw); if ($patch -isnot [System.Collections.IDictionary]) { throw 'Config must be an object' }; Merge-TrinityDefaults $config $patch } } catch { $errorText=$_.Exception.Message }
    $queue=@(); $decisions=@(); $heartbeat=$null; $reason=''
    try { $raw=Read-TrinityFile (Join-Path $dir 'queue.json'); if ($raw) { $queue=@((Get-JsonValue ($script:JsonSerializer.DeserializeObject($raw)) 'items' @())) } } catch { if (-not $errorText) { $errorText=$_.Exception.Message } }
    try { $raw=Read-TrinityFile (Join-Path $dir 'scheduler.json'); if ($raw) { $heartbeat=$script:JsonSerializer.DeserializeObject($raw) } } catch { if (-not $errorText) { $errorText=$_.Exception.Message } }
    $skipped=0
    try {
        $decisionPath=Join-Path $dir 'decisions.jsonl'; $raw=Read-TrinityFile $decisionPath; $key=[IO.Path]::GetFullPath($decisionPath).ToLowerInvariant(); $fileCache=$script:TrinityFileCache[$key]; $cached=$script:DecisionCache[$key]
        if ($fileCache -and $cached -and $cached.stamp -eq $fileCache.stamp -and $cached.length -eq $fileCache.length) { $decisions=$cached.decisions; $skipped=$cached.skipped }
        elseif ($fileCache) {
            foreach ($line in ($raw -split "`r?`n")) { if ($line.Trim()) { try { $parsed=$script:JsonSerializer.DeserializeObject($line); if ($parsed -isnot [System.Collections.IDictionary]) { throw 'Decision must be an object' }; $decisions+=@($parsed) } catch { $skipped++ } } }
            $script:DecisionCache[$key]=@{stamp=$fileCache.stamp; length=$fileCache.length; decisions=$decisions; skipped=$skipped}
        }
    } catch { if (-not $errorText) { $errorText=$_.Exception.Message } }
    $pausePath=Join-Path $dir 'PAUSE'; $paused=Test-Path -LiteralPath $pausePath -PathType Leaf
    if ($paused) { try { $reason=(Read-TrinityFile $pausePath).Trim() } catch { if (-not $errorText) { $errorText=$_.Exception.Message } } }
    $slots=@{}; foreach ($agent in @('codex','antigravity','claude')) { $slots[$agent]=@{used=@($Tasks | Where-Object { $_.agent -eq $agent -and $_.state -in @('running','stalled') }).Count; max=[int](Get-JsonValue $config.slots $agent 0)} }
    $items=@(foreach ($item in $queue) {
        $overlaps=New-Object System.Collections.Generic.List[string]
        foreach ($task in @($Tasks | Where-Object { $_.state -in @('running','stalled') })) {
            $hit=$false
            foreach ($a in @(([string](Get-JsonValue $item 'scope' '')).Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })) { foreach ($b in @(([string]$task.scope).Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })) { $ap=($a -split '\*',2)[0]; $bp=($b -split '\*',2)[0]; if ($ap.StartsWith($bp,[StringComparison]::OrdinalIgnoreCase) -or $bp.StartsWith($ap,[StringComparison]::OrdinalIgnoreCase) -or $a -like $b -or $b -like $a) { $hit=$true } } }
            if ($hit) { $overlaps.Add([string]$task.task) }
        }
        [pscustomobject]@{task=[string](Get-JsonValue $item 'task' ''); agent=[string](Get-JsonValue $item 'agent' ''); scope=[string](Get-JsonValue $item 'scope' ''); promptFile=[string](Get-JsonValue $item 'promptFile' ''); base=[string](Get-JsonValue $item 'base' ''); model=[string](Get-JsonValue $item 'model' ''); addedAt=[string](Get-JsonValue $item 'addedAt' ''); waiting=[string](Get-JsonValue $item 'waiting' ''); overlaps=@($overlaps.ToArray())}
    })
    $alive=$false; $tick=[string](Get-JsonValue $heartbeat 'lastTickAt' '')
    try { $proc=Get-Process -Id ([int](Get-JsonValue $heartbeat 'pid' 0)) -ErrorAction Stop; $start=[datetime]::Parse([string](Get-JsonValue $heartbeat 'processStart' '')); $tickTime=[datetime]::Parse($tick); $age=([datetime]::UtcNow-$tickTime.ToUniversalTime()).TotalSeconds; $alive=([Math]::Abs(($proc.StartTime.ToUniversalTime()-$start.ToUniversalTime()).TotalMilliseconds) -lt 1000 -and $age -ge 0 -and $age -le 90) } catch { }
    $rounds=@{}; $clean=0; $counting=$true
    for ($i=$decisions.Count-1; $i -ge 0; $i--) { $d=$decisions[$i]; $task=[string](Get-JsonValue $d 'task' ''); $round=[int](Get-JsonValue $d 'round' 0); if ($task -and (-not $rounds.ContainsKey($task) -or $round -gt $rounds[$task])) { $rounds[$task]=$round }; $act=[string](Get-JsonValue $d 'action' ''); if ($counting) { if ($act -eq 'failed') { $counting=$false } elseif ($act -in @('ready','merged')) { $clean++ } } }
    $newest=@(); for ($i=$decisions.Count-1; $i -ge 0 -and $newest.Count -lt 20; $i--) { $newest+=@($decisions[$i]) }
    $breach=''; if ($paused -and $reason -match '^limit:') { $breach=$reason } elseif ($newest.Count -and (Get-JsonValue $newest[0] 'action' '') -eq 'limit') { $breach=[string](Get-JsonValue $newest[0] 'reason' 'limit') }
    $auto=@{enabled=[bool]$config.autopilot.enabled; approval=[bool]$config.autopilot.approval; autoMergeAllowed=([bool]$config.autoMerge -and -not [bool]$config.autopilot.approval -and $clean -ge [int]$config.autopilot.cleanRunsBeforeAutoMerge); cleanRuns=$clean; paused=$paused; pauseReason=$reason; roundsUsed=$rounds; decisions=$newest; limitBreach=$breach}; if ($skipped -gt 0) { $auto.decisionsSkipped=$skipped }
    return @{config=$config; configError=$errorText; queue=$items; slots=$slots; scheduler=@{alive=$alive; lastTickAt=$tick; now=[string](Get-JsonValue $heartbeat 'now' ''); next=[string](Get-JsonValue $heartbeat 'next' '')}; autopilot=$auto }
}

function Get-RepoState([string]$Path) {
    # Every poll rebuilds state, and each git spawn costs ~50 ms on Windows: three calls per repo in total.
    $revParse = Invoke-GitRead $Path @('rev-parse', '--show-toplevel', '--path-format=absolute', '--git-common-dir')
    $revLines = @(if ($revParse) { $revParse -split "`n" })
    if ($revLines.Count -lt 2) { return $null }
    $root = [IO.Path]::GetFullPath($revLines[0].Trim())
    $common = [IO.Path]::GetFullPath($revLines[1].Trim())
    # A registered path may be a worktree; board, .codex-out and PLAN live with the main checkout.
    $main = Split-Path $common -Parent
    if (Test-Path -LiteralPath (Join-Path $main '.git')) { $root = $main }
    # Branch, commits ahead of upstream and changed files in one call.
    $branch = ''
    $ahead = 0
    $uncommitted = 0
    $status = Invoke-GitRead $root @('status', '--porcelain=v2', '--branch')
    if ($status) {
        foreach ($line in ($status -split "`n")) {
            if ($line -match '^# branch\.head (.+)$') { if ($Matches[1] -ne '(detached)') { $branch = $Matches[1].Trim() } }
            elseif ($line -match '^# branch\.ab \+(\d+) ') { $ahead = [int]$Matches[1] }
            elseif ($line -and $line -notmatch '^#') { $uncommitted++ }
        }
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
    $tasks = @(Get-RepoTasks $root $common)
    $claudeSessions = @(Get-ClaudeSessions $root $tasks)
    $extra = Get-TrinityState $root $tasks
    return [pscustomobject]@{
        name = (Split-Path $root -Leaf)
        path = $root
        branch = $branch
        uncommitted = $uncommitted
        ahead = $ahead
        plan = [pscustomobject]$plan
        handoff = @($handoff)
        tasks = $tasks
        claudeSessions = $claudeSessions
        config = $extra.config
        configError = $extra.configError
        queue = @($extra.queue)
        slots = $extra.slots
        scheduler = $extra.scheduler
        autopilot = $extra.autopilot
    }
}

function Get-AgentDefaults($RepoStates) {
    $defaults = [ordered]@{ claude = @{ model=''; effort='' }; codex = @{ model=''; effort='' }; antigravity = @{ model=''; effort='' } }
    $config = Join-Path $script:CodexHome 'config.toml'
    if (Test-Path -LiteralPath $config -PathType Leaf) {
        $text = Get-TextLines $config 100
        foreach ($line in ($text -split "`r?`n")) {
            if ($line -match '^\s*\[') { break }
            if (-not $defaults.codex.model -and $line -match '^\s*model\s*=\s*"([^"]+)"') { $defaults.codex.model = $Matches[1] }
            if (-not $defaults.codex.effort -and $line -match '^\s*model_reasoning_effort\s*=\s*"([^"]+)"') { $defaults.codex.effort = $Matches[1] }
        }
    }
    $agyLogs = Join-Path $script:AgyHome 'log'
    if (Test-Path -LiteralPath $agyLogs -PathType Container) {
        foreach ($file in (Get-ChildItem -LiteralPath $agyLogs -Filter 'cli-*.log' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 50)) {
            $log = Get-TextLines $file.FullName 65536
            if ($log -match 'label="([^"]+)"') { $defaults.antigravity.model = $Matches[1]; break }
        }
    }
    $sessions = @($RepoStates | ForEach-Object { $_.claudeSessions } | Sort-Object { $_.lastActivity } -Descending)
    if ($sessions.Count) { $defaults.claude.model = $sessions[0].model; $defaults.claude.effort = $sessions[0].effort }
    return $defaults
}

function Get-Availability($Defaults) {
    if (-not $script:AvailabilityCache -or ((Get-Date) - $script:AvailabilityCachedAt).TotalSeconds -ge 60) {
        . (Join-Path $PSScriptRoot 'lib\board.ps1')
        $script:AvailabilityCache = Get-AgentAvailability
        $script:AvailabilityCachedAt = Get-Date
    }
    $out = [ordered]@{}
    foreach ($agent in @('claude','codex','antigravity')) {
        $raw = $script:AvailabilityCache[$agent]
        $out[$agent] = [pscustomobject]@{ available=[bool]$raw.available; detail=[string]$raw.detail; model=[string]$Defaults[$agent].model; effort=[string]$Defaults[$agent].effort }
    }
    return [pscustomobject]$out
}

function Get-DashboardState {
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    $candidatePaths = New-Object System.Collections.Generic.List[string]
    $trinityHome = if ($env:TRINITY_HOME) { $env:TRINITY_HOME } else { Join-Path $env:USERPROFILE '.trinity' }
    $registry = Join-Path $trinityHome 'repos.txt'
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
    $seenCandidates = @{}
    $repoStates = New-Object System.Collections.Generic.List[object]
    foreach ($candidate in $candidatePaths) {
        if (-not (Test-Path -LiteralPath $candidate -PathType Container)) { continue }
        try { $candidatePath = [IO.Path]::GetFullPath($candidate).TrimEnd('\', '/'); $candidateKey = $candidatePath.ToLowerInvariant() } catch { continue }
        if ($seenCandidates.ContainsKey($candidateKey)) { continue }
        $seenCandidates[$candidateKey] = $true
        # Optional test instrumentation counts collector calls without depending on timing.
        if ($env:TRINITY_DASHBOARD_TEST_COLLECT_LOG) { [IO.File]::AppendAllText($env:TRINITY_DASHBOARD_TEST_COLLECT_LOG, $candidateKey + "`r`n") }
        $state = Get-RepoState $candidatePath
        if (-not $state) { continue }
        $key = $state.path.ToLowerInvariant()
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        $repoStates.Add($state)
    }
    $allTasks = @($repoStates | ForEach-Object { $_.tasks })
    $defaults = Get-AgentDefaults $repoStates
    $agents = [ordered]@{}
    foreach ($agent in @('claude', 'codex', 'antigravity')) {
        $agentTasks = @($allTasks | Where-Object { $_.agent -eq $agent })
        $agents[$agent] = [pscustomobject]@{
            running = @($agentTasks | Where-Object { $_.state -eq 'running' }).Count
            done = @($agentTasks | Where-Object { $_.state -in @('done', 'merged') }).Count
            failed = @($agentTasks | Where-Object { $_.state -eq 'failed' }).Count
            total = $agentTasks.Count
            models = @($agentTasks | Where-Object { $_.state -eq 'running' -and $_.model } | ForEach-Object { $_.model } | Select-Object -Unique)
        }
    }
    $agents.claude.models = @(@($agents.claude.models) + @($repoStates | ForEach-Object { $_.claudeSessions } | Where-Object { $_.active -and $_.model } | ForEach-Object { $_.model }) | Select-Object -Unique)
    $availability = Get-Availability $defaults
    $repoChecks = @(foreach ($repo in $repoStates) {
        $hooksPath = Invoke-GitRead $repo.path @('config', '--get', 'core.hooksPath')
        $commonDir = [string](Invoke-GitRead $repo.path @('rev-parse', '--path-format=absolute', '--git-common-dir'))
        $boardFound = [bool]($commonDir.Trim() -and (Test-Path -LiteralPath (Join-Path $commonDir.Trim() 'agent-board.md') -PathType Leaf))
        [pscustomobject]@{ repo = $repo; hooksPath = [string]$hooksPath; boardFound = $boardFound }
    })
    $stopwatch.Stop()
    $collectMs = [int][Math]::Round($stopwatch.Elapsed.TotalMilliseconds)
    $script:CollectDurations.Add($collectMs)
    while ($script:CollectDurations.Count -gt 10) { $script:CollectDurations.RemoveAt(0) }
    $avgCollectMs = [int][Math]::Round(($script:CollectDurations | Measure-Object -Average).Average)
    $scriptHashOnDisk = Get-ShortFileHash $PSCommandPath
    $server = [pscustomobject]@{
        startedAt = $script:ServerFacts.startedAt
        scriptHash = $script:ServerFacts.scriptHash
        scriptHashOnDisk = $scriptHashOnDisk
        listenerScope = 'loopback'
        blockedRemoteCount = [int]$script:BlockedRemoteCount
        actionsEnabled = $true
        collectMs = $collectMs
        avgCollectMs = $avgCollectMs
    }
    $health = New-Object System.Collections.Generic.List[object]
    $serverStatus = if ($collectMs -lt 1000) { 'ok' } elseif ($collectMs -lt 3000) { 'warn' } else { 'fail' }
    $health.Add([pscustomobject]@{ id='dashboard-server'; label='Dashboard server'; status=$serverStatus; detail="Snapshot collected in ${collectMs} ms" })
    $health.Add([pscustomobject]@{ id='listener-loopback'; label='Listener'; status='ok'; detail="loopback only, $($server.blockedRemoteCount) blocked" })
    $hashStatus = if ($server.scriptHash -eq $server.scriptHashOnDisk) { 'ok' } else { 'warn' }
    $health.Add([pscustomobject]@{ id='server-outdated'; label='Server code'; status=$hashStatus; detail=$(if ($hashStatus -eq 'ok') { 'Running script matches disk' } else { 'Running script differs from disk' }) })
    $missingBoards = @($repoChecks | Where-Object { -not $_.boardFound } | ForEach-Object { $_.repo.name })
    $boardStatus = if ($missingBoards.Count) { 'warn' } else { 'ok' }
    $boardDetail = if ($missingBoards.Count) { 'No agent-board.md in: ' + ($missingBoards -join ', ') } else { 'All repository boards found and parsed' }
    $health.Add([pscustomobject]@{ id='board-readable'; label='Agent boards'; status=$boardStatus; detail=$boardDetail })
    foreach ($check in $repoChecks) {
        $repo = $check.repo
        $repoId = ([string]$repo.name).ToLowerInvariant() -replace '[^a-z0-9]+', '-'
        $repoId = $repoId.Trim('-')
        $hooksPath = $check.hooksPath
        $hooksOk = ([string]$hooksPath).TrimEnd('\', '/') -match '(^|[\\/])\.githooks$'
        $health.Add([pscustomobject]@{ id="hooks-enabled-$repoId"; label="Hooks: $($repo.name)"; status=$(if ($hooksOk) { 'ok' } else { 'warn' }); detail=$(if ($hooksOk) { 'core.hooksPath is .githooks' } else { 'core.hooksPath is not .githooks' }) })
    }
    foreach ($agent in @('claude', 'codex', 'antigravity')) {
        $agentAvailability = $availability.$agent
        $health.Add([pscustomobject]@{ id="agent-$agent"; label="Agent: $agent"; status=$(if ($agentAvailability.available) { 'ok' } else { 'warn' }); detail=[string]$agentAvailability.detail })
    }
    $attention = New-Object System.Collections.Generic.List[object]
    foreach ($repo in $repoStates) {
        if ($repo.autopilot.limitBreach) { $attention.Add([pscustomobject]@{ repo=$repo.name; repoPath=$repo.path; task=''; agent=''; kind='limit'; reason='limit'; detail=$repo.autopilot.limitBreach; since='' }) }
        foreach ($task in $repo.tasks) {
            $reason = $null
            if ($task.state -eq 'failed') { $reason = 'failed' }
            elseif ($task.state -eq 'done') { $reason = 'done-unmerged' }
            elseif ($task.state -eq 'ready') { $reason = 'ready' }
            elseif ($task.state -eq 'stalled') { $reason = 'stalled' }
            elseif ($task.state -eq 'running' -and -not $task.runnerAlive) { $reason = 'runner-dead' }
            if ($reason) {
                $detail = if ($task.status) { [string]$task.status } else { [string]$task.result }
                $since = ''
                if ($task.updated) { try { $since = ([datetime]::Parse($task.updated)).ToString("yyyy-MM-dd'T'HH:mm:ssK") } catch { } }
                $attention.Add([pscustomobject]@{ repo=$repo.name; repoPath=$repo.path; task=$task.task; agent=$task.agent; kind=$reason; reason=$reason; detail=$detail; since=$since })
            }
        }
    }
    return [pscustomobject]@{
        generated = (Get-Date -Format "yyyy-MM-dd'T'HH:mm:ss")
        availability = $availability
        agents = [pscustomobject]$agents
        repos = @($repoStates | Sort-Object name)
        attention = @($attention | Sort-Object { $_.since } -Descending)
        health = @($health.ToArray())
        server = $server
    }
}

# ASCII-only JSON (non-ASCII as \uXXXX) survives any console code page when -Once output is captured.
function Convert-StateToJson($State) {
    $json = $State | ConvertTo-Json -Depth 12 -Compress
    return [regex]::Replace($json, '[^\x00-\x7F]', { param($m) '\u{0:x4}' -f [int][char]$m.Value })
}

# Request failures go to <trinity home>\dashboard-errors.log (route + exception only, never chat content), kept under 512 KB.
function Write-DashboardError([string]$Route, $ErrorRecord) {
    try {
        $dir = if ($env:TRINITY_HOME) { $env:TRINITY_HOME } else { Join-Path $env:USERPROFILE '.trinity' }
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
        $log = Join-Path $dir 'dashboard-errors.log'
        if ((Test-Path $log) -and (Get-Item $log).Length -gt 512KB) { Move-Item $log "$log.1" -Force }
        $where = if ($ErrorRecord.InvocationInfo) { $ErrorRecord.InvocationInfo.PositionMessage -replace '\s+', ' ' } else { '' }
        $line = '{0} {1} {2}: {3} {4}' -f (Get-Date -Format 's'), $Route, $ErrorRecord.Exception.GetType().Name, $ErrorRecord.Exception.Message, $where
        [IO.File]::AppendAllText($log, ($line -replace '[\r\n]+', ' ') + "`r`n", (New-Object Text.UTF8Encoding($false)))
    }
    catch { }
}

function Send-JsonResponse($Response, [int]$Status, $Value) {
    $bytes = [Text.Encoding]::UTF8.GetBytes((Convert-StateToJson $Value))
    $Response.StatusCode = $Status
    $Response.ContentType = 'application/json; charset=utf-8'
    $Response.Headers['Cache-Control'] = 'no-store'
    $Response.ContentLength64 = $bytes.Length
    $Response.OutputStream.Write($bytes, 0, $bytes.Length)
}

function Test-ServerToken([string]$Candidate, [string]$Expected) {
    $candidateBytes = [Text.Encoding]::ASCII.GetBytes($Candidate)
    $expectedBytes = [Text.Encoding]::ASCII.GetBytes($Expected)
    $difference = $candidateBytes.Length -bxor $expectedBytes.Length
    for ($i = 0; $i -lt $expectedBytes.Length; $i++) {
        $value = if ($i -lt $candidateBytes.Length) { [int]$candidateBytes[$i] } else { 0 }
        $difference = $difference -bor ($value -bxor [int]$expectedBytes[$i])
    }
    return ($difference -eq 0)
}

function Add-ActionLog([string]$Action, [string]$Repo, [string]$Task, [string]$Result, [string]$ExitCode = '', [string]$Agent = '') {
    try {
        $dir = if ($env:TRINITY_HOME) { $env:TRINITY_HOME } else { Join-Path $env:USERPROFILE '.trinity' }
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
        $log = Join-Path $dir 'actions.log'
        if ((Test-Path -LiteralPath $log) -and (Get-Item -LiteralPath $log).Length -gt 512KB) { Move-Item -LiteralPath $log -Destination "$log.1" -Force }
        $fields = New-Object System.Collections.Generic.List[string]
        foreach ($field in @($Action, $Repo, $Task, $Result, $ExitCode, $Agent)) {
            $value = [regex]::Replace([string]$field, '[\r\n]+', ' ')
            if ($value.Length -gt 512) { $value = $value.Substring(0, 512) }
            if ($script:ServerToken) { $value = $value.Replace($script:ServerToken, '[redacted]') }
            $fields.Add($value)
        }
        $line = '{0} action={1} repo={2} task={3} result={4} exitCode={5} agent={6}' -f (Get-Date).ToString("yyyy-MM-dd'T'HH:mm:ssK"), $fields[0], $fields[1], $fields[2], $fields[3], $fields[4], $fields[5]
        [IO.File]::AppendAllText($log, $line + "`r`n", (New-Object Text.UTF8Encoding($false)))
    } catch { }
}

function Quote-ProcessArgument([string]$Value) {
    if ($Value.Length -eq 0) { return '""' }
    if ($Value -notmatch '[\s"]') { return $Value }
    return '"' + ($Value -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
}

# Shared read-only validation; only validated task names reach git or filesystem probes.
function Get-DispatchCheck($RepoState, $Availability, [string]$Agent, [string]$Task, [string]$Scope) {
    $r = @{ taskOk=$true; taskReason=''; agentOk=$true; agentReason=''; effectiveAgent=$Agent; rerouted=$false; scopeOk=$true; scopeReason=''; scopeNormalized=@(); overlaps=@(); command=''; canDispatch=$false }
    if ($Task.Length -gt 40 -or $Task -cnotmatch '^[a-z0-9][a-z0-9-]*$') { $r.taskOk=$false; $r.taskReason='Task must be 1-40 lowercase letters, digits or hyphens, starting with a letter or digit' }
    if ($Agent -cnotin @('codex','antigravity','claude')) { $r.agentOk=$false; $r.agentReason='Unknown agent' }
    elseif ($Agent -eq 'claude') { $r.agentReason='Park a task: creates a worktree and task file without a headless run' }
    elseif (-not $Availability.$Agent.available) {
        $other = if ($Agent -eq 'codex') { 'antigravity' } else { 'codex' }
        if ($Availability.$other.available) { $r.effectiveAgent=$other; $r.rerouted=$true; $r.agentReason="$Agent unavailable; rerouted to $other" }
        else { $r.agentOk=$false; $r.agentReason='No headless worker available; use Claude to park a task' }
    }
    if (-not $Scope.Trim()) { $r.scopeReason='no scope: overlap not checked' }
    else {
        $globs = @($Scope.Split(',') | ForEach-Object { $_.Trim() })
        $r.scopeNormalized=$globs
        if ($globs.Count -gt 20) { $r.scopeOk=$false }
        foreach ($glob in $globs) {
            if (-not $glob -or $glob.Contains('..') -or $glob -match '[:\\\x00-\x1f\x7f]' -or $glob.StartsWith('/')) { $r.scopeOk=$false }
        }
        if (-not $r.scopeOk) { $r.scopeReason='Use at most 20 non-empty relative forward-slash globs without .., colons or controls' }
    }
    if ($Scope -match '\p{Cc}') { $r.scopeOk=$false; $r.scopeReason='Scope must not contain control characters' }
    if ($r.taskOk -and $r.agentOk -and $r.scopeOk) {
        $repoPath=[string]$RepoState.path
        if (@($RepoState.tasks | Where-Object { $_.task -eq $Task -and $_.state -ne 'cancelled' }).Count) { $r.taskOk=$false; $r.taskReason='Task already exists on the board' }
        $branchOk=$false; $branches=@()
        try { $branches=@(& git -C $repoPath for-each-ref '--format=%(refname:short)' 'refs/heads/agent/' 2>$null); $branchOk=$LASTEXITCODE -eq 0 } catch { }
        if (-not $branchOk) { $r.taskOk=$false; $r.taskReason='Could not check repository branches' }
        elseif (@($branches | Where-Object { $_ -match ('^agent/[^/]+/' + [regex]::Escape($Task) + '$') }).Count) { $r.taskOk=$false; $r.taskReason='Task branch already exists' }
        $wtRoot=Join-Path (Split-Path $repoPath -Parent) ((Split-Path $repoPath -Leaf)+'.worktrees')
        foreach ($worker in @('codex','antigravity','claude')) {
            if (Test-Path -LiteralPath (Join-Path $wtRoot "$worker-$Task")) { $r.taskOk=$false; $r.taskReason='Task worktree directory already exists' }
        }
        if (Test-Path -LiteralPath (Join-Path $repoPath ".codex-out\prompt-$Task.md")) { $r.taskOk=$false; $r.taskReason='Task prompt file already exists' }
        foreach ($entry in @($RepoState.tasks | Where-Object { $_.state -in @('running','working') })) {
            foreach ($existing in @(([string]$entry.scope).Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
                foreach ($glob in $r.scopeNormalized) {
                    $a=($glob -split '\*',2)[0]; $b=($existing -split '\*',2)[0]
                    $overlap=$a.StartsWith($b,[StringComparison]::OrdinalIgnoreCase) -or $b.StartsWith($a,[StringComparison]::OrdinalIgnoreCase)
                    if (-not $overlap) { try { $overlap=$glob -like $existing -or $existing -like $glob } catch { $overlap=$true } }
                    if ($overlap) {
                        $r.overlaps+=@{ task=$entry.task; agent=$entry.agent; state=$entry.state; glob=$existing }; break
                    }
                }
            }
        }
    }
    # The worker resolves its repository from the script's own path, so a repo without its own copy cannot be targeted.
    if (-not (Test-Path -LiteralPath (Join-Path ([string]$RepoState.path) 'scripts\trinity.ps1') -PathType Leaf)) { $r.agentOk=$false; $r.agentReason='Repository has no scripts\trinity.ps1 (run trinity init there)' }
    $r.canDispatch=$r.taskOk -and $r.agentOk -and $r.scopeOk
    $r.command='trinity dispatch {0} {1} -Scope "{2}" -PromptFile <file>' -f $r.effectiveAgent,$Task,($r.scopeNormalized -join ',')
    return $r
}

function Test-SettingsPatch($Patch) {
    if ($Patch -isnot [System.Collections.IDictionary]) { return $false }
    foreach ($key in $Patch.Keys) {
        $v=$Patch[$key]
        switch -CaseSensitive ($key) {
            'version' { if ($v -isnot [int] -or $v -ne 1) { return $false } }
            { $_ -in @('base','test') } { if ($v -isnot [string] -or $v -match '[^\x20-\x7e]') { return $false } }
            'autoMerge' { if ($v -isnot [bool]) { return $false } }
            { $_ -in @('maxRounds','deadlineMinutes') } { if ($v -isnot [int]) { return $false }; if ($key -eq 'maxRounds' -and ($v -lt 1 -or $v -gt 10)) { return $false }; if ($key -eq 'deadlineMinutes' -and ($v -lt 5 -or $v -gt 1440)) { return $false } }
            { $_ -in @('slots','models','autopilot') } {
                if ($v -isnot [System.Collections.IDictionary]) { return $false }
                foreach ($nested in $v.Keys) {
                    $n=$v[$nested]
                    if ($key -eq 'slots') { if ($nested -cnotin @('codex','antigravity','claude') -or $n -isnot [int] -or $n -lt 0 -or $n -gt 8) { return $false } }
                    elseif ($key -eq 'models') { if ($nested -cnotin @('codex','antigravity','claude') -or $n -isnot [string] -or $n -match '[^\x20-\x7e]') { return $false } }
                    else { switch -CaseSensitive ($nested) { { $_ -in @('enabled','approval') } { if ($n -isnot [bool]) { return $false } }; 'maxTasksPerHour' { if ($n -isnot [int] -or $n -lt 1 -or $n -gt 60) { return $false } }; 'maxConsecutiveFailures' { if ($n -isnot [int] -or $n -lt 1 -or $n -gt 20) { return $false } }; 'cleanRunsBeforeAutoMerge' { if ($n -isnot [int] -or $n -lt 0) { return $false } }; default { return $false } } }
                }
            }
            default { return $false }
        }
    }
    return $true
}
function Write-NewUtf8([string]$Path, [string]$Text) {
    $stream=New-Object IO.FileStream($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try { $bytes=[Text.Encoding]::UTF8.GetBytes($Text); $stream.Write($bytes,0,$bytes.Length) } finally { $stream.Dispose() }
}
function Quote-ActionLiteral([string]$Value) {
    foreach ($code in @(0x27,0x2018,0x2019,0x201a,0x201b)) { $char=[string][char]$code; $Value=$Value.Replace($char,$char+$char) }
    return "'" + $Value + "'"
}
# A command is a list of tokens. A plain string is always a VALUE and is always quoted; only a token made by
# New-ActionFlag (server code, fixed name) is emitted bare as a parameter name, so user text can never become a flag.
function New-ActionFlag([string]$Name) {
    if ($Name -cnotmatch '^-[A-Za-z][A-Za-z0-9]*$') { throw "Invalid action flag: $Name" }
    return @{ flag=$Name }
}
function Convert-ActionToken($Token) {
    if ($Token -is [System.Collections.IDictionary]) {
        $name=[string]$Token['flag']
        if ($Token.Count -eq 1 -and $name -cmatch '^-[A-Za-z][A-Za-z0-9]*$') { return $name }
        throw 'Invalid action flag token'
    }
    return Quote-ActionLiteral ([string]$Token)
}
function Convert-ActionScript([string]$RepoPath, $Commands) {
    $scriptPath=Join-Path $RepoPath 'scripts\trinity.ps1'
    $parts=@(); foreach ($command in $Commands) { $quoted=@($command | ForEach-Object { Convert-ActionToken $_ }); $parts+=('& ' + (Quote-ActionLiteral $scriptPath) + ' ' + ($quoted -join ' ')) }
    return ($parts -join '; if (-not $?) { exit 1 }; ')
}
function Get-ResumeCommand([string]$Task, [string]$File) { return ,@('resume',$Task,(New-ActionFlag '-FeedbackFile'),$File) }
function Get-QueueAddCommand([string]$Agent, [string]$Task, [string]$Scope, [string]$File) { return ,@('queue','add',$Agent,$Task,(New-ActionFlag '-Scope'),$Scope,(New-ActionFlag '-PromptFile'),$File) }
function Get-ConfigSaveCommand([string]$File) { return ,@('config','set',(New-ActionFlag '-Json'),$File) }
function Get-AutopilotCommand([bool]$Enabled, [bool]$Approval) {
    $c=@('autopilot',$(if ($Enabled) { 'on' } else { 'off' })); if ($Enabled -and $Approval) { $c+=,(New-ActionFlag '-Approval') }
    return ,$c
}
function Get-DispatchCommand([string]$Agent, [string]$Task, [string]$Scope, [string]$File, [string]$Base) {
    $c=@('dispatch',$Agent,$Task)
    if ($Scope) { $c+=,(New-ActionFlag '-Scope'); $c+=$Scope }
    if ($File) { $c+=,(New-ActionFlag '-PromptFile'); $c+=$File }
    if ($Base) { $c+=,(New-ActionFlag '-Base'); $c+=$Base }
    return ,$c
}
# Model env var of the agent that really runs the task; claude has none, and a model picked for another agent is not reused after a reroute.
function Get-ModelPrefix([string]$Agent, [string]$ItemAgent, [string]$Model) {
    if (-not $Model -or $Agent -cne $ItemAgent) { return '' }
    $name=switch -CaseSensitive ($Agent) { 'codex' { 'TRINITY_CODEX_MODEL' }; 'antigravity' { 'TRINITY_AGY_MODEL' }; default { '' } }
    if (-not $name) { return '' }
    return '$env:' + $name + '=' + (Quote-ActionLiteral $Model) + '; '
}
# Checks a queue item for start-now: dispatch check first, then the slot of the agent that will really run it.
function Get-StartNowCheck($RepoState, $Availability, $QueueItem, [string]$Task) {
    $r=@{ ok=$false; status=409; error=''; agent=[string]$QueueItem.agent; itemAgent=[string]$QueueItem.agent; scope=[string]$QueueItem.scope; file=[string]$QueueItem.promptFile; base=[string]$QueueItem.base; model=[string]$QueueItem.model; check=$null }
    if (-not $r.file.Trim()) { $r.error='no prompt file'; return $r }
    if ($r.scope -match '[^\x20-\x7e]' -or $r.file -match '[^\x20-\x7e]' -or $r.base -match '[^\x20-\x7e]' -or $r.model -match '[^\x20-\x7e]') { $r.status=400; $r.error='Invalid queue item text'; return $r }
    $check=Get-DispatchCheck $RepoState $Availability $r.itemAgent $Task $r.scope
    $r.check=$check
    if (-not $check.canDispatch) { $r.error=(@($check.taskReason,$check.agentReason,$check.scopeReason) | Where-Object { $_ }) -join '; '; return $r }
    $r.agent=$check.effectiveAgent
    $slot=$RepoState.slots.($r.agent)
    if (-not $slot -or $slot.used -ge $slot.max) { $r.error='no free slot'; return $r }
    $r.ok=$true
    return $r
}

function Start-ActionProcess([string]$Id, [string]$Action, [string]$Task, [string]$RepoPath, [string]$Worktree, [string]$Command, [string]$Agent = '', [string]$Scope = '', [string]$PromptFile = '', [string]$ActionScript = '') {
    $outDir = Join-Path $RepoPath '.codex-out\jobs'
    if (-not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
    $outputPath = Join-Path $outDir "$Id.txt"
    $errorPath = Join-Path $outDir "$Id.stderr.txt"
    $script:Jobs[$Id] = @{ id=$Id; action=$Action; task=$Task; state='running'; exitCode=$null; outputPath=$outputPath; errorPath=$errorPath; command=$Command; process=$null; repo=$RepoPath; agent=$Agent }
    if ($Action -eq 'open-folder') {
        $script:Jobs[$Id].state = 'done'; $script:Jobs[$Id].exitCode = 0
        [IO.File]::WriteAllText($outputPath, '', (New-Object Text.UTF8Encoding($false)))
        Start-Process -FilePath 'explorer.exe' -ArgumentList @((Quote-ProcessArgument $Worktree)) -WorkingDirectory $RepoPath -WindowStyle Hidden | Out-Null
        return
    }
    $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    # trinity.ps1 finds its repo root from its own path, so the review must run the worktree's copy to see the task branch.
    if ($ActionScript) { $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($ActionScript)); $processArguments=@('-NoProfile','-ExecutionPolicy','Bypass','-EncodedCommand',$encoded); $cwd=$RepoPath }
    elseif ($Action -eq 'review-task') { $reviewScript = Join-Path $RepoPath 'scripts\trinity.ps1'; $processArguments=@('-NoProfile','-ExecutionPolicy','Bypass','-File',$reviewScript,'merge',$Task,'-DryRun'); $cwd=$RepoPath }
    elseif ($Action -eq 'dispatch') { $dispatchScript=Join-Path $RepoPath 'scripts\trinity.ps1'; if (-not (Test-Path -LiteralPath $dispatchScript -PathType Leaf)) { $dispatchScript=Join-Path $PSScriptRoot 'trinity.ps1' }; $processArguments=@('-NoProfile','-ExecutionPolicy','Bypass','-File',$dispatchScript,'dispatch',$Agent,$Task,'-Scope',$Scope,'-PromptFile',$PromptFile); $cwd=$RepoPath }
    elseif ($Action -eq 'cancel') { $processArguments=@('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $RepoPath 'scripts\trinity.ps1'),'cancel',$Task); $cwd=$RepoPath }
    else { $processArguments=@('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $RepoPath 'scripts\trinity.ps1'),'merge',$Task,'-Yes'); $cwd=$RepoPath }
    $processArguments = @($processArguments | ForEach-Object { Quote-ProcessArgument ([string]$_) })
    [IO.File]::WriteAllText($outputPath, '', (New-Object Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText($errorPath, '', (New-Object Text.UTF8Encoding($false)))
    $process = Start-Process -FilePath $powershell -ArgumentList $processArguments -WorkingDirectory $cwd -RedirectStandardOutput $outputPath -RedirectStandardError $errorPath -WindowStyle Hidden -PassThru
    $script:Jobs[$Id].process = $process
}

function Update-ActionJobs {
    foreach ($job in @($script:Jobs.Values)) {
        if ($job.state -eq 'running' -and $job.process -and $job.process.HasExited) {
            try {
                $job.process.WaitForExit(); $job.exitCode = [int]$job.process.ExitCode; $job.state = if ($job.exitCode -eq 0) { 'done' } else { 'failed' }
                if (Test-Path -LiteralPath $job.errorPath -PathType Leaf) { $errorText=[IO.File]::ReadAllText($job.errorPath); if ($errorText) { [IO.File]::AppendAllText($job.outputPath, $errorText, (New-Object Text.UTF8Encoding($false))) }; Remove-Item -LiteralPath $job.errorPath -Force -ErrorAction SilentlyContinue }
                Add-ActionLog $job.action $job.repo $job.task $job.id ([string]$job.exitCode) ([string]$job.agent); $job.process.Dispose(); $job.process=$null
            } catch { $job.state='failed'; $job.exitCode=1 }
        }
    }
}

function Read-JobOutput($Job) {
    if (-not (Test-Path -LiteralPath $Job.outputPath -PathType Leaf)) { return '' }
    try {
        $stream = New-Object IO.FileStream($Job.outputPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        try { $count=[int][Math]::Min(65536,$stream.Length); [void]$stream.Seek(-$count,[IO.SeekOrigin]::End); $buffer=New-Object byte[] $count; $read=0; while($read -lt $count){$n=$stream.Read($buffer,$read,$count-$read);if($n -le 0){break};$read+=$n}; $text=[Text.Encoding]::UTF8.GetString($buffer,0,$read) } finally { $stream.Dispose() }
        return [regex]::Replace($text, '[^\x20-\x7E\r\n\t]', '?')
    } catch { return '' }
}

if ($LibraryOnly) { return }

if ($Chat) {
    $kind = Get-ChatKeyKind $Chat
    if (-not $kind) { [Console]::Error.WriteLine('Malformed chat id.'); exit 2 }
    $chatResult = Resolve-Chat $Chat
    if ($chatResult.status -ne 200) { [Console]::Error.WriteLine('Chat not found.'); exit 3 }
    Convert-StateToJson $chatResult.value
    exit 0
}

if ($Once) {
    Convert-StateToJson (Get-DashboardState)
    exit 0
}

$listener = $null
$collectorRunspace = $null
$collectorPowerShell = $null
$collectorAsync = $null
$tokenBytes = New-Object byte[] 32
[Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($tokenBytes)
$script:ServerToken = ([BitConverter]::ToString($tokenBytes) -replace '-', '').ToLowerInvariant()
$script:Jobs = @{}
$sharedState = [hashtable]::Synchronized(@{ bytes = $null; builtAt = [datetime]::MinValue; lastRequestAt = [datetime]::MinValue; stop = $false; error = $null; errorAt = [datetime]::MinValue; errorSeq = 0; serverFacts = $script:ServerFacts; blockedRemoteCount = 0 })
$loggedErrorSeq = 0
try {
    $listener = New-Object System.Net.HttpListener
    $listener.Prefixes.Add("http://localhost:$Port/")
    $listener.Start()
}
catch { [Console]::Error.WriteLine("Dashboard could not listen on port ${Port}: $($_.Exception.Message)"); exit 2 }
try {
    $demandSeconds = 30
    if ($env:TRINITY_DASHBOARD_TEST_DEMAND_SECONDS -match '^\d+$') { $demandSeconds = [Math]::Max(1, [int]$env:TRINITY_DASHBOARD_TEST_DEMAND_SECONDS) }
    $collectorRunspace = [RunspaceFactory]::CreateRunspace()
    $collectorRunspace.Open()
    $collectorPowerShell = [PowerShell]::Create()
    $collectorPowerShell.Runspace = $collectorRunspace
    $collectorScript = {
        param($dashboardPath, [string[]]$repos, $shared, [int]$refreshSeconds, [int]$demandSeconds)
        try {
            . $dashboardPath -LibraryOnly -Repos $repos
            while (-not $shared.stop) {
                $now = [datetime]::UtcNow
                $hasBytes = ($null -ne $shared.bytes -and $shared.bytes.Length -gt 0)
                $demanded = ($shared.lastRequestAt -ne [datetime]::MinValue -and ($now - $shared.lastRequestAt).TotalSeconds -lt $demandSeconds)
                $due = (-not $hasBytes) -or ($demanded -and ($now - $shared.builtAt).TotalSeconds -ge $refreshSeconds)
                if ($due) {
                    try {
                        $script:ServerFacts = $shared.serverFacts
                        $script:BlockedRemoteCount = [int]$shared.blockedRemoteCount
                        $json = Convert-StateToJson (Get-DashboardState)
                        $bytes = [Text.Encoding]::UTF8.GetBytes($json)
                        $shared.bytes = $bytes
                        $shared.builtAt = [datetime]::UtcNow
                    }
                    catch { $shared.error = $_.Exception.ToString(); $shared.errorAt = [datetime]::UtcNow; $shared.errorSeq = [int]$shared.errorSeq + 1; Start-Sleep -Seconds 2 }
                }
                Start-Sleep -Milliseconds 100
            }
        }
        catch { $shared.error = $_.Exception.ToString(); $shared.errorSeq = [int]$shared.errorSeq + 1 }
    }.ToString()
    [void]$collectorPowerShell.AddScript($collectorScript).AddArgument($PSCommandPath).AddArgument($Repos).AddArgument($sharedState).AddArgument($RefreshSeconds).AddArgument($demandSeconds)
    $collectorAsync = $collectorPowerShell.BeginInvoke()
    while ($listener.IsListening) {
        $context = $null
        try { $context = $listener.GetContext() }
        catch [System.Net.HttpListenerException] { break }
        catch [System.ObjectDisposedException] { break }
        if (-not $context) { continue }
        $response = $context.Response
        try {
            $response.Headers['X-Content-Type-Options'] = 'nosniff'
            $hostName = [string]$context.Request.Headers['Host']
            $remoteAddress = $context.Request.RemoteEndPoint.Address
            if ($remoteAddress.IsIPv4MappedToIPv6) { $remoteAddress = $remoteAddress.MapToIPv4() }
            if (-not [System.Net.IPAddress]::IsLoopback($remoteAddress) -or $hostName -cne "localhost:$Port") {
                $sharedState.blockedRemoteCount = [int]$sharedState.blockedRemoteCount + 1
                $response.StatusCode = 403
            }
            elseif ($context.Request.Url.AbsolutePath -eq '/api/dispatch/check' -and $context.Request.HttpMethod -eq 'GET') {
                $snapshot=$null
                if ($sharedState.bytes) { $snapshot=[Text.Encoding]::UTF8.GetString($sharedState.bytes) | ConvertFrom-Json }
                $repoRequest=[string]$context.Request.QueryString['repo']
                $repoState=@($snapshot.repos | Where-Object { [string]::Equals([string]$_.path,$repoRequest,[StringComparison]::OrdinalIgnoreCase) }) | Select-Object -First 1
                if (-not $repoState) { Send-JsonResponse $response 404 @{ error='Unknown repository' } }
                else { Send-JsonResponse $response 200 (Get-DispatchCheck $repoState $snapshot.availability ([string]$context.Request.QueryString['agent']) ([string]$context.Request.QueryString['task']) ([string]$context.Request.QueryString['scope'])) }
            }
            elseif ($context.Request.Url.AbsolutePath -eq '/api/action' -and $context.Request.HttpMethod -eq 'POST') {
                $action = ''; $repoRequest = ''; $taskName = ''; $dispatchAgent = ''; $authPassed = $false; $actionLogged = $false
                try {
                    if ([string]$context.Request.Headers['Origin'] -cne "http://localhost:$Port") { Send-JsonResponse $response 403 @{ error='Origin must match this dashboard' }; continue }
                    if (-not (Test-ServerToken ([string]$context.Request.Headers['X-Trinity-Token']) $script:ServerToken)) { Send-JsonResponse $response 401 @{ error='Missing or invalid token' }; continue }
                    $authPassed = $true
                    if ([string]$context.Request.ContentType -notmatch '^application/json(?:\s*;|$)') { Add-ActionLog '' '' '' '415'; $actionLogged=$true; Send-JsonResponse $response 415 @{ error='Content-Type must be application/json' }; continue }
                    if ($context.Request.ContentLength64 -gt 65536) { Add-ActionLog '' '' '' '413'; $actionLogged=$true; Send-JsonResponse $response 413 @{ error='Request body exceeds 64 KB' }; continue }
                    $bodyStream = New-Object IO.MemoryStream
                    $buffer = New-Object byte[] 1024
                    while ($bodyStream.Length -le 65536) {
                        $read = $context.Request.InputStream.Read($buffer, 0, [int][Math]::Min($buffer.Length, 65537 - $bodyStream.Length))
                        if ($read -le 0) { break }
                        $bodyStream.Write($buffer, 0, $read)
                    }
                    if ($bodyStream.Length -gt 65536) { Add-ActionLog '' '' '' '413'; $actionLogged=$true; Send-JsonResponse $response 413 @{ error='Request body exceeds 64 KB' }; continue }
                    try { $body = $script:JsonSerializer.DeserializeObject([Text.Encoding]::UTF8.GetString($bodyStream.ToArray())) } catch { Add-ActionLog '' '' '' '400'; $actionLogged=$true; $badStatus=if ($bodyStream.Length -gt 8192) { 413 } else { 400 }; Send-JsonResponse $response $badStatus @{ error='Invalid JSON body or body exceeds 8 KB' }; continue }
                    if ($body -isnot [System.Collections.IDictionary]) { Add-ActionLog '' '' '' '400'; $actionLogged=$true; Send-JsonResponse $response 400 @{ error='JSON body must be an object' }; continue }
                    $actionValue = Get-JsonValue $body 'action' ''
                    $repoValue = Get-JsonValue $body 'repo' ''
                    $taskValue = Get-JsonValue $body 'task' ''
                    if ($actionValue -isnot [string] -or $repoValue -isnot [string] -or $taskValue -isnot [string]) { Add-ActionLog '' '' '' '400'; $actionLogged=$true; Send-JsonResponse $response 400 @{ error='action, repo, and task must be strings' }; continue }
                    if ($actionValue -notin @('dispatch','queue-add','resume','settings-save') -and $bodyStream.Length -gt 8192) { Send-JsonResponse $response 413 @{ error='Request body exceeds 8 KB' }; continue }
                    $action = $actionValue
                    $repoRequest = $repoValue
                    $taskName = $taskValue
                    $confirm = (Get-JsonValue $body 'confirm' $false) -eq $true
                    $confirmValue = Get-JsonValue $body 'confirm' $false
                    if ($confirmValue -isnot [bool]) { Add-ActionLog $action $repoRequest $taskName '400'; $actionLogged=$true; Send-JsonResponse $response 400 @{ error='confirm must be a boolean' }; continue }
                    if ($action -notin @('cancel','merge','review-task','open-folder','dispatch','resume','retry','queue-add','queue-remove','queue-move','start-now','settings-save','autopilot','pause','unpause')) { Add-ActionLog $action $repoRequest $taskName '400'; $actionLogged=$true; Send-JsonResponse $response 400 @{ error='Unknown action' }; continue }
                    if (($action -in @('settings-save','autopilot','pause','unpause') -and $taskName -ne '') -or ($action -notin @('settings-save','autopilot','pause','unpause') -and ($taskName.Length -gt 40 -or $taskName -cnotmatch '^[a-z0-9][a-z0-9-]*$'))) { Add-ActionLog $action $repoRequest $taskName '400'; $actionLogged=$true; Send-JsonResponse $response 400 @{ error='Invalid task name' }; continue }
                    if ($action -in @('cancel','merge','resume','retry','queue-add','queue-remove','start-now','settings-save','autopilot','unpause') -and -not $confirm) { Add-ActionLog $action $repoRequest $taskName '412'; $actionLogged=$true; Send-JsonResponse $response 412 @{ error='This action requires confirm:true' }; continue }
                    $snapshot = $null
                    if ($sharedState.bytes) { $snapshot = [Text.Encoding]::UTF8.GetString($sharedState.bytes) | ConvertFrom-Json }
                    $repoState = @($snapshot.repos | Where-Object { [string]::Equals([string]$_.path, $repoRequest, [StringComparison]::OrdinalIgnoreCase) }) | Select-Object -First 1
                    if (-not $repoState) { Add-ActionLog $action $repoRequest $taskName '404'; $actionLogged=$true; Send-JsonResponse $response 404 @{ error='Unknown repository' }; continue }
                    $repoPath = [IO.Path]::GetFullPath([string]$repoState.path)
                    if ($action -eq 'dispatch') {
                        $agentValue=Get-JsonValue $body 'agent' ''; $scopeValue=Get-JsonValue $body 'scope' ''; $promptValue=Get-JsonValue $body 'prompt' ''
                        if (-not $confirm -or $agentValue -isnot [string] -or $scopeValue -isnot [string] -or $promptValue -isnot [string]) { Send-JsonResponse $response 400 @{ error='Dispatch requires confirm:true and string agent, scope and prompt' }; continue }
                        if ($scopeValue -match '[^\x20-\x7e]') { Send-JsonResponse $response 400 @{ error='Scope must be printable ASCII (it reaches the command line)' }; continue }
                        if (-not $promptValue.Trim() -or [Text.Encoding]::UTF8.GetByteCount($promptValue) -gt 32768) { Send-JsonResponse $response 400 @{ error='Prompt must be non-empty and at most 32 KB UTF-8' }; continue }
                        $check=Get-DispatchCheck $repoState $snapshot.availability $agentValue $taskName $scopeValue
                        $dispatchAgent=$check.effectiveAgent
                        if (-not $check.canDispatch) { Send-JsonResponse $response 400 @{ error=(@($check.taskReason,$check.agentReason,$check.scopeReason) | Where-Object { $_ }) -join '; ' }; continue }
                    }
                    elseif ($action -notin @('queue-add','queue-remove','queue-move','start-now','settings-save','autopilot','pause','unpause')) {
                    $taskState = @($repoState.tasks | Where-Object { $_.task -ceq $taskName }) | Select-Object -First 1
                    if (-not $taskState) { Add-ActionLog $action $repoPath $taskName '404'; $actionLogged=$true; Send-JsonResponse $response 404 @{ error='Unknown task' }; continue }
                    $worktree = [string]$taskState.worktree
                    $hasWorktree = $false
                    if ($worktree -and $worktree -ne '-') {
                        try {
                            $worktree = [IO.Path]::GetFullPath($worktree)
                            $expected = [IO.Path]::GetFullPath((Join-Path (Split-Path $repoPath -Parent) ((Split-Path $repoPath -Leaf) + '.worktrees'))).TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
                            $hasWorktree = $worktree.StartsWith($expected, [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $worktree -PathType Container)
                        } catch { $hasWorktree = $false }
                    }
                    if (-not (Test-TaskActionState $action $taskState.state $hasWorktree ([string]$taskState.branch))) {
                        if ($action -eq 'merge') { $stateCode=409 } else { $stateCode=400 }; Add-ActionLog $action $repoPath $taskName ([string]$stateCode); $actionLogged=$true; Send-JsonResponse $response $stateCode @{ error='Task state does not allow this action' }; continue
                    }
                    }
                    Update-ActionJobs
                    $running = @($script:Jobs.Values | Where-Object { $_.state -eq 'running' })
                    if (@($running | Where-Object { [string]::Equals($_.repo,$repoPath,[StringComparison]::OrdinalIgnoreCase) -and $_.task -eq $taskName }).Count) { Add-ActionLog $action $repoPath $taskName '409'; $actionLogged=$true; Send-JsonResponse $response 409 @{ error='An action is already running for this task' }; continue }
                    if ($running.Count -ge 4) { Add-ActionLog $action $repoPath $taskName '429'; $actionLogged=$true; Send-JsonResponse $response 429 @{ error='Too many running actions' }; continue }
                    $idBytes = New-Object byte[] 6; [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($idBytes); $jobId=([BitConverter]::ToString($idBytes) -replace '-','').ToLowerInvariant()
                    $display = switch ($action) { 'cancel' { "trinity cancel $taskName" }; 'merge' { "trinity merge $taskName -Yes" }; 'review-task' { "trinity merge $taskName -DryRun" }; 'open-folder' { "explorer.exe `"$worktree`"" } }
                    $commands=@(); $actionScript=''; $modelPrefix=''; $outDir=Join-Path $repoPath '.codex-out'; [void][IO.Directory]::CreateDirectory($outDir)
                    $queueItem=@($repoState.queue | Where-Object { $_.task -ceq $taskName }) | Select-Object -First 1
                    if ($action -in @('queue-remove','queue-move','start-now') -and -not $queueItem) { Send-JsonResponse $response 404 @{error='Unknown queued task'}; continue }
                    switch ($action) {
                        'resume' {
                            $feedback=Get-JsonValue $body 'feedback' $null
                            if ($feedback -isnot [string] -or -not $feedback.Trim() -or [Text.Encoding]::UTF8.GetByteCount($feedback) -gt 16384) { Send-JsonResponse $response 400 @{error='Feedback must be 1 to 16384 bytes'}; continue }
                            $file=Join-Path $outDir "feedback-$taskName-$jobId.md"; Write-NewUtf8 $file $feedback
                            $commands+=,(Get-ResumeCommand $taskName $file); $display="trinity resume $taskName -FeedbackFile $(Quote-ProcessArgument $file)"
                        }
                        'retry' { $commands+=,@('retry',$taskName); $display="trinity retry $taskName" }
                        'queue-add' {
                            $agentValue=Get-JsonValue $body 'agent' $null; $scopeValue=Get-JsonValue $body 'scope' $null; $promptValue=Get-JsonValue $body 'prompt' $null
                            if ($scopeValue -is [string] -and $scopeValue -match '[^\x20-\x7e]') { Send-JsonResponse $response 400 @{error='Scope must be printable ASCII (it reaches the command line)'}; continue }
                            if ($agentValue -isnot [string] -or $agentValue -cnotin @('codex','antigravity','claude') -or $scopeValue -isnot [string] -or $promptValue -isnot [string] -or -not $promptValue.Trim() -or [Text.Encoding]::UTF8.GetByteCount($promptValue) -gt 32768 -or $scopeValue -match '[^\x20-\x7e]' -or $scopeValue -match '[:\\\x00-\x1f\x7f]' -or $scopeValue.Contains('..') -or $scopeValue.StartsWith('/') -or @($scopeValue.Split(',')).Count -gt 20 -or @($repoState.tasks | Where-Object { $_.task -eq $taskName -and $_.state -ne 'cancelled' }).Count -or $queueItem) { Send-JsonResponse $response 400 @{error='Invalid queue item'}; continue }
                            $file=Join-Path $outDir "prompt-$taskName-$jobId.md"; Write-NewUtf8 $file $promptValue
                            $commands+=,(Get-QueueAddCommand $agentValue $taskName $scopeValue $file); $commands+=,@('scheduler','start')
                            $display="trinity queue add $agentValue $taskName -Scope $(Quote-ProcessArgument $scopeValue) -PromptFile $(Quote-ProcessArgument $file); trinity scheduler start"
                        }
                        'queue-remove' { $commands+=,@('queue','remove',$taskName); $display="trinity queue remove $taskName" }
                        'queue-move' { $index=Get-JsonValue $body 'index' $null; if ($index -isnot [int] -or $index -lt 0) { Send-JsonResponse $response 400 @{error='Invalid index'}; continue }; $commands+=,@('queue','move',$taskName,[string]$index); $display="trinity queue move $taskName $index" }
                        'start-now' {
                            $plan=Get-StartNowCheck $repoState $snapshot.availability $queueItem $taskName
                            if (-not $plan.ok) { Send-JsonResponse $response $plan.status @{error=$plan.error}; continue }
                            $agentValue=$plan.agent; $dispatchArgs=Get-DispatchCommand $agentValue $taskName $plan.scope $plan.file $plan.base
                            $display="trinity dispatch $agentValue $taskName"
                            if ($plan.scope) { $display+=' -Scope ' + (Quote-ProcessArgument $plan.scope) }
                            $display+=' -PromptFile ' + (Quote-ProcessArgument $plan.file)
                            if ($plan.base) { $display+=' -Base ' + (Quote-ProcessArgument $plan.base) }
                            # Dispatch first; the queue item is removed only when dispatch succeeded (Convert-ActionScript stops on failure).
                            $commands+=,$dispatchArgs; $commands+=,@('queue','remove',$taskName); $display+="; trinity queue remove $taskName"
                            $modelPrefix=Get-ModelPrefix $agentValue $plan.itemAgent $plan.model
                            if ($modelPrefix) { $display=$modelPrefix+$display }
                        }
                        'settings-save' { $config=Get-JsonValue $body 'config' $null; if (-not (Test-SettingsPatch $config)) { Send-JsonResponse $response 400 @{error='Invalid settings'}; continue }; $file=Join-Path $outDir "config-$jobId.json"; Write-NewUtf8 $file ($script:JsonSerializer.Serialize($config)); $commands+=,(Get-ConfigSaveCommand $file); $display="trinity config set -Json $(Quote-ProcessArgument $file)" }
                        'autopilot' { $enabled=Get-JsonValue $body 'enabled' $null; if ($enabled -isnot [bool]) { Send-JsonResponse $response 400 @{error='enabled must be a boolean'}; continue }; $approvalValue=(Get-JsonValue $body 'approval' $false) -eq $true; $mode=if ($enabled) {'on'} else {'off'}; $commands+=,(Get-AutopilotCommand $enabled $approvalValue); $display="trinity autopilot $mode"; if ($enabled -and $approvalValue) { $display+=' -Approval' }; if ($enabled) { $commands+=,@('scheduler','start'); $display+='; trinity scheduler start' } }
                        'pause' { $reason=Get-JsonValue $body 'reason' ''; if ($reason -isnot [string] -or $reason.Length -gt 200 -or $reason -match '[\r\n]') { Send-JsonResponse $response 400 @{error='Invalid reason'}; continue }; if (-not $reason) { $reason='user' }; $dir=Join-Path $repoPath '.trinity'; [void][IO.Directory]::CreateDirectory($dir); $temp=Join-Path $dir ("PAUSE-$jobId.tmp"); Write-NewUtf8 $temp ($reason+"`n"); $pausePath=Join-Path $dir 'PAUSE'; if ([IO.File]::Exists($pausePath)) { [IO.File]::Replace($temp,$pausePath,$null) } else { [IO.File]::Move($temp,$pausePath) }; $commands+=,@('scheduler','stop'); $display='trinity scheduler stop' }
                        'unpause' { $commands+=,@('unpause'); $display='trinity unpause' }
                    }
                    if ($response.StatusCode -ge 400) { continue }
                    if ($action -eq 'dispatch') {
                        $promptFile=Join-Path $outDir "prompt-$taskName.md"
                        try { Write-NewUtf8 $promptFile $promptValue } catch [IO.IOException] { Send-JsonResponse $response 400 @{ error='Could not create a new prompt file' }; continue }
                        $display='trinity dispatch {0} {1} -Scope {2} -PromptFile {3}' -f $check.effectiveAgent,$taskName,(Quote-ProcessArgument ($check.scopeNormalized -join ',')),(Quote-ProcessArgument $promptFile)
                        Start-ActionProcess $jobId $action $taskName $repoPath '' $display $check.effectiveAgent ($check.scopeNormalized -join ',') $promptFile
                    }
                    else { if ($commands.Count) { $actionScript=$modelPrefix + (Convert-ActionScript $repoPath $commands) }; Start-ActionProcess $jobId $action $taskName $repoPath $worktree $display '' '' '' $actionScript }
                    Add-ActionLog $action $repoPath $taskName $jobId '' ([string]$script:Jobs[$jobId].agent)
                    $actionLogged=$true
                    $jobFiles = @(Get-ChildItem -LiteralPath (Join-Path $repoPath '.codex-out\jobs') -Filter '*.txt' -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^[0-9a-f]{12}\.txt$' } | Sort-Object LastWriteTimeUtc -Descending)
                    foreach ($oldJob in @($jobFiles | Select-Object -Skip 50)) { $oldId=[IO.Path]::GetFileNameWithoutExtension($oldJob.Name); if ($script:Jobs.ContainsKey($oldId) -and $script:Jobs[$oldId].state -eq 'running') { continue }; Remove-Item -LiteralPath $oldJob.FullName -Force -ErrorAction SilentlyContinue; $script:Jobs.Remove($oldId) }
                    Send-JsonResponse $response 202 @{ job=$jobId; command=$display }
                }
                catch {
                    if ($authPassed -and -not $actionLogged) { Add-ActionLog $action $repoRequest $taskName '500' '' $dispatchAgent; $actionLogged=$true }
                    Write-DashboardError '/api/action' $_
                    Send-JsonResponse $response 500 @{ error='Could not start action' }
                }
                finally { if ($authPassed -and -not $actionLogged -and $action -eq 'dispatch') { Add-ActionLog $action $repoRequest $taskName ([string]$response.StatusCode) '' $dispatchAgent } }
            }
            elseif ($context.Request.Url.AbsolutePath -eq '/api/job' -and $context.Request.HttpMethod -eq 'GET') {
                Update-ActionJobs
                $jobId = [string]$context.Request.QueryString['id']
                if ($jobId -notmatch '^[0-9a-f]{12}$') { Send-JsonResponse $response 400 @{ error='Invalid job id' } }
                elseif (-not $script:Jobs.ContainsKey($jobId)) { Send-JsonResponse $response 404 @{ error='Unknown job' } }
                else { $job=$script:Jobs[$jobId]; Send-JsonResponse $response 200 @{ id=$job.id; action=$job.action; task=$job.task; state=$job.state; exitCode=$job.exitCode; output=(Read-JobOutput $job); command=$job.command } }
            }
            elseif ($context.Request.HttpMethod -ne 'GET') {
                $response.StatusCode = 404
            }
            elseif ($context.Request.Url.AbsolutePath.StartsWith('/ui/')) {
                $name = $context.Request.Url.AbsolutePath.Substring(4)
                if ($name -cnotmatch '^[a-z0-9-]+\.(js|css)$') { $response.StatusCode = 404 }
                else {
                    $uiPath = Join-Path (Join-Path $PSScriptRoot 'dashboard-ui') $name
                    if (-not (Test-Path -LiteralPath $uiPath -PathType Leaf)) { $response.StatusCode = 404 }
                    else {
                        $bytes = [IO.File]::ReadAllBytes($uiPath)
                        $response.ContentType = if ($name.EndsWith('.js')) { 'application/javascript; charset=utf-8' } else { 'text/css; charset=utf-8' }
                        $response.Headers['Cache-Control'] = 'no-cache'
                        $response.ContentLength64 = $bytes.Length
                        $response.OutputStream.Write($bytes, 0, $bytes.Length)
                    }
                }
            }
            elseif ($context.Request.Url.AbsolutePath -eq '/api/history') {
                $snapshot=$null; if ($sharedState.bytes) { $snapshot=[Text.Encoding]::UTF8.GetString($sharedState.bytes) | ConvertFrom-Json }
                $repoFilter=[string]$context.Request.QueryString['repo']; $agentFilter=[string]$context.Request.QueryString['agent']; $outcomeFilter=[string]$context.Request.QueryString['outcome']
                $items=@($(foreach ($repo in @($snapshot.repos)) { if ($repoFilter -and $repoFilter -ne 'all' -and -not [string]::Equals($repo.path,$repoFilter,[StringComparison]::OrdinalIgnoreCase)) { continue }; foreach ($task in @($repo.tasks)) { if ($task.state -notin @('merged','cancelled','failed')) { continue }; if ($agentFilter -and $agentFilter -ne 'all' -and $task.agent -ne $agentFilter) { continue }; if ($outcomeFilter -and $outcomeFilter -ne 'all' -and $task.state -ne $outcomeFilter) { continue }; [pscustomobject]@{repo=$repo.path; task=$task.task; agent=$task.agent; outcome=$task.state; started=$task.started; finished=$task.finished; durationSec=$task.durationSec; commits=$task.commits; model=$task.model; tokens=$task.tokens} } }) | Sort-Object finished -Descending | Select-Object -First 500)
                Send-JsonResponse $response 200 @{items=$items}
            }
            elseif ($context.Request.Url.AbsolutePath -eq '/api/task/review') {
                $taskName=[string]$context.Request.QueryString['task']; $repoRequest=[string]$context.Request.QueryString['repo']
                if ($taskName -cnotmatch '^[a-z0-9][a-z0-9-]*$' -or $taskName.Length -gt 40) { Send-JsonResponse $response 400 @{error='Invalid task name'}; continue }
                $snapshot=$null; if ($sharedState.bytes) { $snapshot=[Text.Encoding]::UTF8.GetString($sharedState.bytes) | ConvertFrom-Json }
                $repoState=@($snapshot.repos | Where-Object { [string]::Equals([string]$_.path,$repoRequest,[StringComparison]::OrdinalIgnoreCase) }) | Select-Object -First 1
                if (-not $repoState -or -not @($repoState.tasks | Where-Object { $_.task -ceq $taskName }).Count) { Send-JsonResponse $response 404 @{error='Unknown repository or task'}; continue }
                $path=Join-Path ([string]$repoState.path) ".codex-out\review-$taskName.md"; $text=''; $at=''; $findings=@()
                if (Test-Path -LiteralPath $path -PathType Leaf) { $text=Get-Redacted ([IO.File]::ReadAllText($path)); $at=(Get-Item -LiteralPath $path).LastWriteTime.ToString("yyyy-MM-dd'T'HH:mm:ss"); foreach ($line in ($text -split "`r?`n")) { if ($line -match '(?i)\b(P[0-3])\b[\]\s:*-]+(.+?)(?:\s+[-(]\s*([^\s():]+):(\d+)\)?)?$') { $findings+=@{severity=$Matches[1].ToUpperInvariant(); title=$Matches[2].Trim(); file=[string]$Matches[3]; line=$(if ($Matches[4]) {[int]$Matches[4]} else {$null})} } } }
                Send-JsonResponse $response 200 @{text=$text; findings=$findings; parsed=($findings.Count -gt 0); at=$at}
            }
            elseif ($context.Request.Url.AbsolutePath -eq '/api/state') {
                $requestStarted = [datetime]::UtcNow
                $sharedState.lastRequestAt = $requestStarted
                $bytes = $null
                $builtAt = [datetime]::MinValue
                if ($sharedState.bytes -and (([datetime]::UtcNow - $sharedState.builtAt).TotalSeconds -lt 15)) {
                    $bytes = $sharedState.bytes
                    $builtAt = $sharedState.builtAt
                }
                else {
                    $deadline = [datetime]::UtcNow.AddSeconds(60)
                    while ([datetime]::UtcNow -lt $deadline) {
                        if ($sharedState.bytes -and $sharedState.builtAt -gt $requestStarted) {
                            $bytes = $sharedState.bytes
                            $builtAt = $sharedState.builtAt
                            break
                        }
                        if ($sharedState.errorAt -gt $requestStarted) { break }
                        Start-Sleep -Milliseconds 75
                    }
                    if (-not $bytes -and $sharedState.bytes) {
                        $bytes = $sharedState.bytes
                        $builtAt = $sharedState.builtAt
                    }
                }
                if ($bytes) {
                    $response.StatusCode = 200
                    $response.ContentType = 'application/json; charset=utf-8'
                    $response.Headers['Cache-Control'] = 'no-store'
                    $ageMs = [int][Math]::Max(0, ([datetime]::UtcNow - $builtAt).TotalMilliseconds)
                    $response.Headers['X-Snapshot-Age-Ms'] = [string]$ageMs
                    $response.ContentLength64 = $bytes.Length
                    $response.OutputStream.Write($bytes, 0, $bytes.Length)
                }
                elseif ($sharedState.error) { $response.StatusCode = 500 }
                else { $response.StatusCode = 503; $response.Headers['Retry-After'] = '5' }
            }
            elseif ($context.Request.Url.AbsolutePath -in @('/api/task/diff','/api/task/log','/api/task/merge-check')) {
                try {
                    $taskName=[string]$context.Request.QueryString['task']; $repoRequest=[string]$context.Request.QueryString['repo']
                    if ($taskName -cnotmatch '^[a-z0-9][a-z0-9-]*$') { Send-JsonResponse $response 400 @{ error='Invalid task name' }; continue }
                    $snapshot=$null; if ($sharedState.bytes) { $snapshot=[Text.Encoding]::UTF8.GetString($sharedState.bytes) | ConvertFrom-Json }
                    $repoState=@($snapshot.repos | Where-Object { [string]::Equals([string]$_.path,$repoRequest,[StringComparison]::OrdinalIgnoreCase) }) | Select-Object -First 1
                    if (-not $repoState) { Send-JsonResponse $response 404 @{ error='Unknown repository' }; continue }
                    $taskState=@($repoState.tasks | Where-Object { $_.task -ceq $taskName }) | Select-Object -First 1
                    if (-not $taskState) { Send-JsonResponse $response 404 @{ error='Unknown task' }; continue }
                    if (-not $taskState.branch -or $taskState.branch -eq '-') { Send-JsonResponse $response 409 @{ error='task has no branch' }; continue }
                    $repoPath=[string]$repoState.path
                    if ($context.Request.Url.AbsolutePath -ne '/api/task/log') {
                        $branchCheck=Invoke-GitRead $repoPath @('rev-parse','--verify','--quiet',('refs/heads/'+[string]$taskState.branch)) -Bounded -MaxChars 256
                        if ($branchCheck.code -ne 0) { Send-JsonResponse $response 409 @{ error='branch no longer exists (already merged or removed)' }; continue }
                    }
                    $offset=-1L; $rawOffset=[string]$context.Request.QueryString['offset']
                    if ($rawOffset -and -not [long]::TryParse($rawOffset,[ref]$offset)) { Send-JsonResponse $response 400 @{ error='Invalid offset' }; continue }
                    switch ($context.Request.Url.AbsolutePath) {
                        '/api/task/diff' { $value=Get-TaskDiff $repoPath $taskState }
                        '/api/task/log' {
                            $value=Get-TaskLog $repoPath $taskState $offset
                        }
                        '/api/task/merge-check' { $value=Get-TaskMergeCheck $repoPath $taskState }
                    }
                    Send-JsonResponse $response 200 $value
                } catch { Send-JsonResponse $response 500 @{ error='Could not read task data' } }
            }
            elseif ($context.Request.Url.AbsolutePath -eq '/api/chat') {
                $key = [string]$context.Request.QueryString['id']
                $chatResult = Resolve-Chat $key
                $response.StatusCode = $chatResult.status
                if ($chatResult.status -eq 200) {
                    $bytes = [Text.Encoding]::UTF8.GetBytes((Convert-StateToJson $chatResult.value))
                    $response.ContentType = 'application/json; charset=utf-8'
                    $response.Headers['Cache-Control'] = 'no-store'
                    $response.ContentLength64 = $bytes.Length
                    $response.OutputStream.Write($bytes, 0, $bytes.Length)
                }
            }
            elseif ($context.Request.Url.AbsolutePath -in @('/', '/dashboard-sample.json')) {
                # The page's ?sample=1 preview fetches the sample file next to it.
                $isSample = $context.Request.Url.AbsolutePath -ne '/'
                $htmlPath = Join-Path $PSScriptRoot $(if ($isSample) { 'dashboard-sample.json' } else { 'dashboard.html' })
                if (Test-Path -LiteralPath $htmlPath -PathType Leaf) {
                    if ($isSample) { $bytes = [IO.File]::ReadAllBytes($htmlPath) }
                    else { $html = [IO.File]::ReadAllText($htmlPath); $bytes = [Text.Encoding]::UTF8.GetBytes($html.Replace('__TRINITY_TOKEN__', $script:ServerToken)) }
                    $response.StatusCode = 200
                    $response.ContentType = $(if ($isSample) { 'application/json; charset=utf-8' } else { 'text/html; charset=utf-8' })
                    $response.ContentLength64 = $bytes.Length
                    $response.OutputStream.Write($bytes, 0, $bytes.Length)
                }
                else { $response.StatusCode = 404 }
            }
            else { $response.StatusCode = 404 }
        }
        catch {
            Write-DashboardError $context.Request.Url.AbsolutePath $_
            $response.StatusCode = 500
        }
        finally {
            try { $response.Close() } catch { }
        }
        while ($loggedErrorSeq -lt $sharedState.errorSeq) {
            $loggedErrorSeq++
            $record = [System.Management.Automation.ErrorRecord]::new([Exception]::new([string]$sharedState.error), 'DashboardCollector', [System.Management.Automation.ErrorCategory]::NotSpecified, $null)
            Write-DashboardError 'collector' $record
        }
    }
}
finally {
    $sharedState.stop = $true
    foreach ($job in @($script:Jobs.Values)) { if ($job.process) { try { if (-not $job.process.HasExited) { $job.process.Kill(); [void]$job.process.WaitForExit(2000) } } catch { }; try { $job.process.Dispose() } catch { } } }
    if ($collectorAsync -and $collectorPowerShell) {
        try { if (-not $collectorAsync.IsCompleted) { [void]$collectorAsync.AsyncWaitHandle.WaitOne(1500) } } catch { }
        try { $collectorPowerShell.Stop() } catch { }; try { $collectorPowerShell.Dispose() } catch { }
    }
    if ($collectorRunspace) { try { $collectorRunspace.Close() } catch { }; try { $collectorRunspace.Dispose() } catch { } }
    if ($listener) { $listener.Close() }
}
