Run-Case 'dash-api: ready and stalled task states' {
    param($f)
    & {
        . (Join-Path $f.Repo 'scripts\dashboard.ps1') -LibraryOnly
        Assert-True ((Get-TaskState 'running (stalled 5m)' $true) -eq 'stalled') 'live stalled task must be stalled'
        Assert-True ((Get-TaskState 'ready: review clean' $false) -eq 'ready') 'ready task must be ready'
        Assert-True ((Get-TaskState 'running' $true) -eq 'running') 'running task changed'
    }
}
Run-Case 'dash-api: state defaults and fixture files' {
    param($f)
    & {
        . (Join-Path $f.Repo 'scripts\dashboard.ps1') -LibraryOnly
        $defaults=Get-TrinityState $f.Repo @()
        Assert-True ($defaults.config.slots.codex -eq 2 -and $defaults.queue.Count -eq 0 -and -not $defaults.autopilot.enabled) 'defaults incorrect'
        $dir=Join-Path $f.Repo '.trinity'; [void][IO.Directory]::CreateDirectory($dir)
        [IO.File]::WriteAllText((Join-Path $dir 'trinity.json'), '{"slots":{"codex":3},"autopilot":{"enabled":true}}')
        [IO.File]::WriteAllText((Join-Path $dir 'queue.json'), '{"items":[{"task":"queued","agent":"codex","scope":"src/a/*"}]}')
        [IO.File]::WriteAllText((Join-Path $dir 'decisions.jsonl'), "{`"task`":`"a`",`"action`":`"ready`",`"round`":2}`n")
        [IO.File]::WriteAllText((Join-Path $dir 'PAUSE'), 'limit: test')
        $task=[pscustomobject]@{task='running'; agent='codex'; state='running'; scope='src/a/file.ps1'}
        $state=Get-TrinityState $f.Repo @($task)
        Assert-True ($state.config.slots.codex -eq 3 -and $state.config.slots.claude -eq 1) 'config merge incorrect'
        Assert-True ($state.queue.Count -eq 1 -and $state.queue[0].overlaps[0] -eq 'running') 'queue overlap missing'
        Assert-True ($state.slots.codex.used -eq 1 -and $state.autopilot.enabled -and $state.autopilot.roundsUsed.a -eq 2 -and $state.autopilot.limitBreach) 'state fields incorrect'
        Assert-True (-not (Test-SettingsPatch @{slots=@{codex=9}})) 'out of range slot accepted'
        Assert-True (Test-SettingsPatch @{slots=@{codex=8}}) 'valid settings rejected'
    }
}
Run-Case 'dash-api: listener guards and routes' {
    param($f)
    $process=$null
    try {
        $tcp=New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,0); $tcp.Start(); $port=$tcp.LocalEndpoint.Port; $tcp.Stop()
        $ui=Join-Path $f.Repo 'scripts\dashboard-ui'; [void][IO.Directory]::CreateDirectory($ui); [IO.File]::WriteAllText((Join-Path $ui 'test.js'),'test')
        $process=Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -WindowStyle Hidden -PassThru -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"{0}"' -f (Join-Path $f.Repo 'scripts\dashboard.ps1')),'-Port',[string]$port,'-Repos',('"{0}"' -f $f.Repo))
        $base="http://localhost:$port"; $page=$null; $deadline=(Get-Date).AddSeconds(30)
        while (-not $page -and (Get-Date) -lt $deadline -and -not $process.HasExited) { try { $page=Invoke-WebRequest "$base/" -UseBasicParsing -TimeoutSec 2 } catch { Start-Sleep -Milliseconds 100 } }
        if (-not $page -and $process.HasExited) { Skip-Case 'HttpListener is unsupported or blocked in this environment' }
        Assert-True ([bool]$page) 'server did not start'
        $token=[regex]::Match($page.Content,'<meta\s+name="trinity-token"\s+content="([^"]+)">').Groups[1].Value
        $send={ param($path,$body,$key)
            $req=[Net.HttpWebRequest]::Create("$base$path"); $req.Timeout=30000
            if ($null -ne $body) { $req.Method='POST'; $req.ContentType='application/json'; $req.Headers.Add('Origin',$base); if ($key) { $req.Headers.Add('X-Trinity-Token',$key) }; $bytes=[Text.Encoding]::UTF8.GetBytes(($body | ConvertTo-Json -Depth 8 -Compress)); $req.ContentLength=$bytes.Length; $stream=$req.GetRequestStream(); $stream.Write($bytes,0,$bytes.Length); $stream.Dispose() }
            try { $res=$req.GetResponse() } catch [Net.WebException] { if (-not $_.Exception.Response) { throw }; $res=$_.Exception.Response }
            $reader=New-Object IO.StreamReader($res.GetResponseStream()); $result=@{status=[int]$res.StatusCode; text=$reader.ReadToEnd()}; $reader.Dispose(); $res.Dispose(); return $result
        }
        $state=& $send '/api/state' $null ''; Assert-True ($state.status -eq 200) 'state failed'
        foreach ($action in @('resume','retry','queue-add','queue-remove','queue-move','start-now','settings-save','autopilot','pause','unpause')) { $reply=& $send '/api/action' @{action=$action;repo=$f.Repo;task=''} ''; Assert-True ($reply.status -eq 401) "$action did not require token" }
        foreach ($action in @('settings-save','autopilot','unpause')) { $reply=& $send '/api/action' @{action=$action;repo=$f.Repo;task=''} $token; Assert-True ($reply.status -eq 412) "$action did not require confirm" }
        $reply=& $send '/api/action' @{action='settings-save';repo=$f.Repo;task='';confirm=$true;config=@{slots=@{codex=9}}} $token; Assert-True ($reply.status -eq 400) 'bad settings accepted'
        $reply=& $send '/api/action' @{action='pause';repo=$f.Repo;task='';reason='test'} $token; Assert-True ($reply.status -eq 202 -and ($reply.text | ConvertFrom-Json).command -eq 'trinity scheduler stop') "pause failed: $($reply.text)"
        Assert-True ((Get-Content (Join-Path $f.Repo '.trinity\PAUSE') -Raw).Trim() -eq 'test') 'pause switch missing'
        Assert-True ((& $send '/ui/test.js' $null '').status -eq 200) 'UI file missing'
        Assert-True ((& $send '/ui/test.txt' $null '').status -eq 404) 'bad UI extension accepted'
        Assert-True ((& $send '/api/history?repo=all' $null '').status -eq 200) 'history failed'
    } finally { if ($process) { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue } }
}
Run-Case 'dash-api: heartbeat and cached file changes' {
    param($f)
    & {
        . (Join-Path $f.Repo 'scripts\dashboard.ps1') -LibraryOnly
        $dir=Join-Path $f.Repo '.trinity'; [void][IO.Directory]::CreateDirectory($dir)
        $heartbeat=@{pid=$PID; processStart=(Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o'); lastTickAt=[datetime]::UtcNow.ToString('o'); now='working'; next='next-task'} | ConvertTo-Json -Compress
        [IO.File]::WriteAllText((Join-Path $dir 'scheduler.json'),$heartbeat)
        $state=Get-TrinityState $f.Repo @(); Assert-True ($state.scheduler.alive -and $state.scheduler.next -eq 'next-task') 'live heartbeat not detected'
        $heartbeat=@{pid=$PID; processStart=(Get-Process -Id $PID).StartTime.AddMinutes(-1).ToUniversalTime().ToString('o'); lastTickAt=[datetime]::UtcNow.ToString('o')} | ConvertTo-Json -Compress
        [IO.File]::WriteAllText((Join-Path $dir 'scheduler.json'),$heartbeat)
        $state=Get-TrinityState $f.Repo @(); Assert-True (-not $state.scheduler.alive) 'reused pid accepted'
        [IO.File]::WriteAllText((Join-Path $dir 'trinity.json'),'{bad')
        $state=Get-TrinityState $f.Repo @(); Assert-True ($state.configError -and $state.config.slots.codex -eq 2) 'malformed config did not fall back'
    }
}
