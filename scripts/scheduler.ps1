param([Parameter(Mandatory=$true)][string]$Repo, [int]$IntervalSeconds=15, [switch]$Once)
$ErrorActionPreference='Stop'
if ($IntervalSeconds -lt 1) { throw 'IntervalSeconds must be positive' }
. (Join-Path $PSScriptRoot 'lib\scheduler.ps1')
$paths=Get-SchedulerPaths $Repo
$bytes=[Text.Encoding]::UTF8.GetBytes(([IO.Path]::GetFullPath($paths.Main)).ToLowerInvariant())
$hash=[Security.Cryptography.SHA256]::Create(); try { $name=([BitConverter]::ToString($hash.ComputeHash($bytes))).Replace('-','') } finally { $hash.Dispose() }
$mutex=New-Object Threading.Mutex($false, ('Local\TrinityScheduler-' + $name)); $owned=$false
try {
    try { $owned=$mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $owned=$true }
    if (-not $owned) { throw 'Scheduler already running' }
    $heartbeat=Join-Path $paths.Main '.trinity\scheduler.json'
    if (Test-Path -LiteralPath $heartbeat) {
        try { $old=ConvertFrom-Json ([IO.File]::ReadAllText($heartbeat)); $process=Get-Process -Id ([int]$old.pid) -ErrorAction SilentlyContinue; if ($process -and $process.Id -ne $PID -and $process.StartTime.ToString('o') -eq $old.processStart -and ((Get-Date)-[datetimeoffset]::Parse($old.lastTickAt).LocalDateTime).TotalSeconds -lt 90) { throw 'Scheduler already running' } } catch { if ($_.Exception.Message -eq 'Scheduler already running') { throw } }
    }
    $idleSince=$null; $stop=Join-Path $paths.Main '.trinity\scheduler.stop'
    while ($true) {
        if (Test-Path -LiteralPath $stop) { Remove-Item -LiteralPath $stop -Force; break }
        try { $null=Invoke-SchedulerTick $paths } catch {
            $message=$_.Exception.Message; [void][IO.Directory]::CreateDirectory($paths.Out)
            [IO.File]::AppendAllText((Join-Path $paths.Out 'scheduler-error.log'), ((Get-Date).ToString('o') + ' ' + $message + "`r`n"), (New-Object Text.UTF8Encoding($false)))
            $process=Get-Process -Id $PID
            Write-TrinityJson $heartbeat @{pid=$PID;startedAt=$process.StartTime.ToString('o');processStart=$process.StartTime.ToString('o');lastTickAt=(Get-Date).ToString('o');now=('error: ' + $message);next=''}
        }
        if ($Once) { break }
        try { $queue=Get-TrinityQueue $paths; $config=Get-TrinityConfig $paths } catch { $idleSince=$null; Start-Sleep -Seconds $IntervalSeconds; continue }
        if (-not $queue.items.Count -and -not $config.autopilot.enabled) { if (-not $idleSince) { $idleSince=Get-Date }; if (((Get-Date)-$idleSince).TotalMinutes -ge 10) { break } } else { $idleSince=$null }
        for ($i=0; $i -lt $IntervalSeconds; $i++) { Start-Sleep -Seconds 1; if (Test-Path -LiteralPath $stop) { break } }
    }
} finally { if ($owned) { $mutex.ReleaseMutex() }; $mutex.Dispose() }
