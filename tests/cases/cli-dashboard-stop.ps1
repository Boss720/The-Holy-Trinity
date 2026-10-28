# Cases for `trinity dashboard` finding its server by port when the pid file is missing or stale (cli-dashstop).
# Dot-sourced by tests/run-tests.ps1, which provides Run-Case, Invoke-Trinity, Assert-True and Skip-Case.

function Get-DashStopFreePort {
    $tcp = New-Object System.Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
    $tcp.Start()
    $port = $tcp.LocalEndpoint.Port
    $tcp.Stop()
    return $port
}

# A real dashboard server on the port, started like an old orphan: nothing writes a pid file for it.
function Start-DashStopServer($Fixture, [int]$Port) {
    $dashboard = Join-Path $Fixture.Repo 'scripts\dashboard.ps1'
    $process = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -WindowStyle Hidden -PassThru -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $dashboard), '-Port', [string]$Port, '-Repos', ('"{0}"' -f $Fixture.Repo))
    $deadline = (Get-Date).AddSeconds(15)
    $up = $false
    while (-not $up -and (Get-Date) -lt $deadline -and -not $process.HasExited) {
        try { Invoke-WebRequest -Uri "http://localhost:$Port/api/state" -UseBasicParsing -TimeoutSec 2 | Out-Null; $up = $true }
        catch { Start-Sleep -Milliseconds 100 }
    }
    if (-not $up) {
        $exited = $process.HasExited
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        if ($exited) { Skip-Case 'HttpListener is unsupported or blocked in this environment' }
        throw 'dashboard never answered /api/state'
    }
    return $process
}

Run-Case 'dashboard -Stop finds a server with no pid file by its port' {
    param($f)
    $oldHome = $env:TRINITY_HOME
    $process = $null
    try {
        $env:TRINITY_HOME = Join-Path $f.Root 'isolated dashboard home'
        $port = Get-DashStopFreePort
        $process = Start-DashStopServer $f $port
        $pidFile = Join-Path $env:TRINITY_HOME 'dashboard.pid'
        Assert-True (-not (Test-Path $pidFile)) 'the isolated home should start without a pid file'

        $stop = Invoke-Trinity $f @('dashboard', '-Stop', '-Port', [string]$port)
        Assert-True ($stop.ExitCode -eq 0) "dashboard -Stop exited $($stop.ExitCode): $($stop.Output)"
        Assert-True ($stop.Output -match ("Dashboard stopped \(pid $($process.Id), found on port $port\)\.")) "unexpected -Stop output: $($stop.Output)"
        Assert-True ($process.WaitForExit(10000)) 'the dashboard process was still running after -Stop'
        $deadline = (Get-Date).AddSeconds(10)
        while ((Get-Date) -lt $deadline -and @(Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue).Count -gt 0) { Start-Sleep -Milliseconds 200 }
        Assert-True (@(Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue).Count -eq 0) 'the port was still listening after -Stop'
    }
    finally {
        if ($process) { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue }
        $env:TRINITY_HOME = $oldHome
    }
}

Run-Case 'dashboard reuses a server found by port past a stale pid file and records it' {
    param($f)
    $oldHome = $env:TRINITY_HOME
    $process = $null
    try {
        $env:TRINITY_HOME = Join-Path $f.Root 'isolated dashboard home'
        New-Item -ItemType Directory -Path $env:TRINITY_HOME -Force | Out-Null
        $port = Get-DashStopFreePort
        $process = Start-DashStopServer $f $port
        $pidFile = Join-Path $env:TRINITY_HOME 'dashboard.pid'
        # 999999 is not a pid Windows hands out (pids are multiples of 4), so this pid file is stale.
        [IO.File]::WriteAllText($pidFile, "999999 $port", (New-Object Text.UTF8Encoding($false)))

        # Starting a dashboard opens the browser; the fixture copy of the script gets that one line removed.
        $text = [IO.File]::ReadAllText($f.Trinity)
        $launch = [regex]::Match($text, '(?m)^[ \t]*Start-Process cmd\.exe[^\r\n]*\$url[^\r\n]*')
        Assert-True $launch.Success 'could not find the browser launch line in the fixture trinity.ps1'
        [IO.File]::WriteAllText($f.Trinity, $text.Replace($launch.Value, '        # browser launch removed by the test'), (New-Object Text.UTF8Encoding($true)))

        $start = Invoke-Trinity $f @('dashboard', '-Port', [string]$port)
        Assert-True ($start.ExitCode -eq 0) "dashboard exited $($start.ExitCode): $($start.Output)"
        Assert-True ($start.Output -match ("Dashboard already running \(pid $($process.Id), found on port $port\)\.")) "unexpected start output: $($start.Output)"
        Assert-True ((([IO.File]::ReadAllText($pidFile)).Trim()) -eq "$($process.Id) $port") 'the reused server was not recorded in the pid file'
        $servers = @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" | Where-Object { $_.CommandLine -match ('dashboard\.ps1.*-Port\s+' + $port + '(\s|$)') })
        Assert-True ($servers.Count -eq 1 -and $servers[0].ProcessId -eq $process.Id) "expected only the original server, found $($servers.Count) dashboard processes"

        # The recorded pid now serves a plain -Stop (no -Port): the pid-file path, no port lookup.
        $stop = Invoke-Trinity $f @('dashboard', '-Stop')
        Assert-True ($stop.ExitCode -eq 0) "dashboard -Stop exited $($stop.ExitCode): $($stop.Output)"
        Assert-True ($stop.Output -match ("Dashboard stopped \(pid $($process.Id)\)\.")) "unexpected -Stop output: $($stop.Output)"
        Assert-True ($process.WaitForExit(10000)) 'the dashboard process was still running after -Stop'
        Assert-True (-not (Test-Path $pidFile)) 'the pid file was not removed by -Stop'
    }
    finally {
        if ($process) { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue }
        $env:TRINITY_HOME = $oldHome
    }
}

Run-Case 'dashboard leaves a non-dashboard listener on the port alone' {
    param($f)
    $oldHome = $env:TRINITY_HOME
    $holder = $null
    try {
        $env:TRINITY_HOME = Join-Path $f.Root 'isolated dashboard home'
        # A plain TcpListener in a child powershell: the port is real and held, but it is not a trinity dashboard.
        $portFile = Join-Path $f.Root 'holder-port.txt'
        $holderScript = Join-Path $f.Root 'holder.ps1'
        $holderCode = '$l = New-Object System.Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0); $l.Start(); [IO.File]::WriteAllText($args[0], [string]$l.LocalEndpoint.Port); Start-Sleep -Seconds 120'
        [IO.File]::WriteAllText($holderScript, $holderCode + "`r`n", (New-Object Text.UTF8Encoding($false)))
        $holder = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -WindowStyle Hidden -PassThru -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $holderScript), ('"{0}"' -f $portFile))
        $port = 0
        $deadline = (Get-Date).AddSeconds(15)
        while ($port -eq 0 -and (Get-Date) -lt $deadline -and -not $holder.HasExited) {
            if (Test-Path $portFile) { [void][int]::TryParse(([IO.File]::ReadAllText($portFile)).Trim(), [ref]$port) }
            if ($port -eq 0) { Start-Sleep -Milliseconds 100 }
        }
        Assert-True ($port -gt 0) 'the holder process never opened its port'

        $stop = Invoke-Trinity $f @('dashboard', '-Stop', '-Port', [string]$port)
        Assert-True ($stop.ExitCode -eq 0) "dashboard -Stop exited $($stop.ExitCode): $($stop.Output)"
        Assert-True ($stop.Output -match ("Port $port is held by powershell\.exe \(pid $($holder.Id)\); not a trinity dashboard, left running\.")) "unexpected -Stop output: $($stop.Output)"
        Assert-True (-not $holder.HasExited) 'dashboard -Stop killed a process that is not a trinity dashboard'

        $start = Invoke-Trinity $f @('dashboard', '-Port', [string]$port)
        Assert-True ($start.ExitCode -ne 0) "dashboard on a held port should fail, exited $($start.ExitCode): $($start.Output)"
        Assert-True ($start.Output -match ("Port $port is held by powershell\.exe \(pid $($holder.Id)\)")) "unexpected start output: $($start.Output)"
        Assert-True ($start.Output -match '-Port') "the failure does not hint at -Port: $($start.Output)"
        Assert-True (-not $holder.HasExited) 'dashboard start killed a process that is not a trinity dashboard'
    }
    finally {
        if ($holder) { Stop-Process -Id $holder.Id -Force -ErrorAction SilentlyContinue }
        $env:TRINITY_HOME = $oldHome
    }
}

Run-Case 'dashboard -Stop says not running when nothing listens on the port' {
    param($f)
    $oldHome = $env:TRINITY_HOME
    try {
        $env:TRINITY_HOME = Join-Path $f.Root 'isolated dashboard home'
        $port = Get-DashStopFreePort
        $stop = Invoke-Trinity $f @('dashboard', '-Stop', '-Port', [string]$port)
        Assert-True ($stop.ExitCode -eq 0) "dashboard -Stop exited $($stop.ExitCode): $($stop.Output)"
        Assert-True ($stop.Output -match 'Dashboard is not running\.') "unexpected -Stop output: $($stop.Output)"
    }
    finally { $env:TRINITY_HOME = $oldHome }
}
