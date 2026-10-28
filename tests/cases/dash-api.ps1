Run-Case 'dash-api: merge accepts ready and rejects running' {
    param($f)
    & {
        . (Join-Path $f.Repo 'scripts\dashboard.ps1') -LibraryOnly
        Assert-True (Test-TaskActionState 'merge' 'ready' $false '') 'ready merge rejected'
        Assert-True (Test-TaskActionState 'merge' 'done' $false '') 'done merge rejected'
        Assert-True (-not (Test-TaskActionState 'merge' 'running' $false '')) 'running merge accepted'
    }
}

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
        $dir=Join-Path $f.Repo '.trinity'; [void][IO.Directory]::CreateDirectory($dir)
        [IO.File]::WriteAllText((Join-Path $dir 'queue.json'), '{"items":[{"task":"noprompt","agent":"claude"},{"task":"taken","agent":"claude","promptFile":"prompt.md"}]}')
        Set-CliTask $f 'taken' 'done'
        Set-CliTask $f 'ready-task' 'ready: review clean'
        Set-CliTask $f 'running-task' 'running'
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
        $reply=& $send '/api/action' @{action='start-now';repo=$f.Repo;task='noprompt';confirm=$true} $token
        Assert-True ($reply.status -eq 409 -and $reply.text -match 'no prompt file') 'missing prompt was accepted'
        $reply=& $send '/api/action' @{action='start-now';repo=$f.Repo;task='taken';confirm=$true} $token
        Assert-True ($reply.status -eq 409 -and $reply.text -match 'already exists') 'dispatch check did not reject existing task'
        Assert-True ((Get-Content (Join-Path $dir 'queue.json') -Raw) -match 'taken') 'rejected dispatch removed queue item'
        $badScope='src/' + [char]0x2019 + '; calc'
        $reply=& $send '/api/action' @{action='queue-add';repo=$f.Repo;task='unsafe';agent='claude';scope=$badScope;prompt='test';confirm=$true} $token
        Assert-True ($reply.status -eq 400) 'non-ASCII scope reached a job'
        Assert-True (-not (Test-Path (Join-Path $f.Repo '.codex-out\jobs'))) 'unsafe request created a job'
        $reply=& $send '/api/action' @{action='merge';repo=$f.Repo;task='ready-task';confirm=$true} $token; Assert-True ($reply.status -eq 202) "ready merge rejected: $($reply.text)"
        $reply=& $send '/api/action' @{action='merge';repo=$f.Repo;task='running-task';confirm=$true} $token; Assert-True ($reply.status -eq 409 -and $reply.text -match 'Task state does not allow this action') "running merge accepted: $($reply.text)"
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

Run-Case 'dash-api: decision cache skips malformed lines and escapes quotes' {
    param($f)
    & {
        . (Join-Path $f.Repo 'scripts\dashboard.ps1') -LibraryOnly
        $dir=Join-Path $f.Repo '.trinity'; [void][IO.Directory]::CreateDirectory($dir)
        $path=Join-Path $dir 'decisions.jsonl'
        [IO.File]::WriteAllText($path, "{`"task`":`"first`",`"round`":1}`n{bad`n{`"task`":`"last`",`"round`":2}`n")
        $a=Get-TrinityState $f.Repo @(); $b=Get-TrinityState $f.Repo @()
        Assert-True ($a.autopilot.decisionsSkipped -eq 1 -and $b.autopilot.decisions.Count -eq 2 -and $b.autopilot.decisions[0].task -eq 'last') 'malformed decision lost valid records'
        $key=[IO.Path]::GetFullPath($path).ToLowerInvariant(); Assert-True ($script:DecisionCache[$key].skipped -eq 1) 'parsed cache missing'
        [IO.File]::AppendAllText($path, "{`"task`":`"new`",`"round`":3}`n")
        $c=Get-TrinityState $f.Repo @(); Assert-True ($c.autopilot.decisions[0].task -eq 'new') 'decision cache did not invalidate'
        foreach ($code in @(0x27,0x2018,0x2019,0x201a,0x201b)) { $ch=[string][char]$code; Assert-True ((Quote-ActionLiteral ("a"+$ch+"b")) -eq ("'a"+$ch+$ch+"b'")) 'quote was not doubled' }
    }
}

Run-Case 'dash-api: failed dispatch stops queue removal and model is inherited' {
    param($f)
    & {
        . (Join-Path $f.Repo 'scripts\dashboard.ps1') -LibraryOnly
        $marker=Join-Path $f.Repo 'calls.txt'; $scriptPath=Join-Path $f.Repo 'scripts\trinity.ps1'
        $fake="param([Parameter(ValueFromRemainingArguments=`$true)]`$rest)`r`n[IO.File]::AppendAllText('" + $marker.Replace("'","''") + "', (`$rest -join ' ') + ':' + `$env:TRINITY_CODEX_MODEL + [Environment]::NewLine)`r`nexit 1`r`n"
        [IO.File]::WriteAllText($scriptPath,$fake)
        $commands=@(); $commands+=,(Get-DispatchCommand 'claude' 'queued' '' 'prompt.md' ''); $commands+=,@('queue','remove','queued')
        $action='$env:TRINITY_CODEX_MODEL=' + (Quote-ActionLiteral 'test-model') + '; ' + (Convert-ActionScript $f.Repo $commands)
        $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($action))
        & (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -NoProfile -EncodedCommand $encoded
        $calls=@(Get-Content $marker); Assert-True ($calls.Count -eq 1 -and $calls[0] -match '^dispatch .*:test-model$') 'failed dispatch removed queue item or lost model'
    }
}

Run-Case 'dash-api: resume script emits FeedbackFile flag bare and value quoted' {
    param($f)
    & {
        . (Join-Path $f.Repo 'scripts\dashboard.ps1') -LibraryOnly
        $file='C:\x\feedback-t-ab12.md'
        $script=Convert-ActionScript $f.Repo @(,(Get-ResumeCommand 'task-a' $file))
        Assert-True ($script.Contains(" -FeedbackFile '$file'")) "flag not bare or value not quoted: $script"
        Assert-True (-not $script.Contains("'-FeedbackFile'")) 'flag was quoted'
        Assert-True ($script.Contains("'resume' 'task-a' -FeedbackFile")) "resume order wrong: $script"
    }
}

Run-Case 'dash-api: user value starting with a dash stays quoted' {
    param($f)
    & {
        . (Join-Path $f.Repo 'scripts\dashboard.ps1') -LibraryOnly
        $script=Convert-ActionScript $f.Repo @(,(Get-QueueAddCommand 'codex' 'task-a' '-Force' 'C:\p.md'))
        Assert-True ($script.Contains(" -Scope '-Force' -PromptFile 'C:\p.md'")) "scope value not quoted: $script"
        Assert-True (-not ($script -match "(^|\s)-Force(\s|$)")) 'bare -Force emitted'
        $threw=$false; try { New-ActionFlag '-Force; calc' | Out-Null } catch { $threw=$true }
        Assert-True $threw 'invalid flag name accepted'
        $script=Convert-ActionScript $f.Repo @(,@('queue','add',(New-ActionFlag '-Yes'),'-Yes'))
        Assert-True ($script.Contains(" -Yes '-Yes'")) "plain string became a flag: $script"
    }
}

Run-Case 'dash-api: settings-save, autopilot and dispatch command lines' {
    param($f)
    & {
        . (Join-Path $f.Repo 'scripts\dashboard.ps1') -LibraryOnly
        $script=Convert-ActionScript $f.Repo @(,(Get-ConfigSaveCommand 'C:\c\config-1.json'))
        Assert-True ($script.Contains("'config' 'set' -Json 'C:\c\config-1.json'")) "settings-save line wrong: $script"
        $script=Convert-ActionScript $f.Repo @(,(Get-AutopilotCommand $true $true))
        Assert-True ($script.EndsWith("'autopilot' 'on' -Approval")) "autopilot on line wrong: $script"
        $script=Convert-ActionScript $f.Repo @(,(Get-AutopilotCommand $false $true))
        Assert-True ($script.EndsWith("'autopilot' 'off'")) "autopilot off line wrong: $script"
        $script=Convert-ActionScript $f.Repo @((Get-DispatchCommand 'codex' 'task-a' 'src/*' 'C:\p.md' 'main'),@('queue','remove','task-a'))
        Assert-True ($script.Contains("'dispatch' 'codex' 'task-a' -Scope 'src/*' -PromptFile 'C:\p.md' -Base 'main'; if (-not `$?) { exit 1 }; & ")) "dispatch line wrong: $script"
        Assert-True ((Get-ModelPrefix 'codex' 'codex' 'm1') -eq '$env:TRINITY_CODEX_MODEL=''m1''; ') 'codex model env wrong'
        Assert-True ((Get-ModelPrefix 'antigravity' 'antigravity' 'g1') -eq '$env:TRINITY_AGY_MODEL=''g1''; ') 'agy model env wrong'
        Assert-True ((Get-ModelPrefix 'claude' 'claude' 'x') -eq '') 'claude model not ignored'
        Assert-True ((Get-ModelPrefix 'antigravity' 'codex' 'm1') -eq '') 'model leaked across reroute'
    }
}

Run-Case 'dash-api: start-now checks the slot of the rerouted agent' {
    param($f)
    & {
        . (Join-Path $f.Repo 'scripts\dashboard.ps1') -LibraryOnly
        $avail=@{ codex=@{available=$false}; antigravity=@{available=$true}; claude=@{available=$true} }
        $item=[pscustomobject]@{ task='rq'; agent='codex'; scope='src/rq/*'; promptFile='C:\p.md'; base=''; model='m1' }
        # codex slot is free but codex is rerouted to antigravity, whose slot is full
        $repo=@{ path=$f.Repo; tasks=@(); slots=@{ codex=@{used=0;max=2}; antigravity=@{used=1;max=1}; claude=@{used=0;max=1} } }
        $r=Get-StartNowCheck $repo $avail $item 'rq'
        Assert-True ((-not $r.ok) -and $r.status -eq 409 -and $r.error -eq 'no free slot') "rerouted full slot not rejected: $($r.error)"
        # codex slot is full but the rerouted agent has room
        $repo.slots=@{ codex=@{used=2;max=2}; antigravity=@{used=0;max=1}; claude=@{used=0;max=1} }
        $r=Get-StartNowCheck $repo $avail $item 'rq'
        Assert-True ($r.ok -and $r.agent -eq 'antigravity' -and $r.itemAgent -eq 'codex') "rerouted free slot rejected: $($r.error)"
    }
}

Run-Case 'dash-api: em-dash prompt accepted, non-ASCII scope rejected' {
    param($f)
    $process=$null
    try {
        $tcp=New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,0); $tcp.Start(); $port=$tcp.LocalEndpoint.Port; $tcp.Stop()
        $process=Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -WindowStyle Hidden -PassThru -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"{0}"' -f (Join-Path $f.Repo 'scripts\dashboard.ps1')),'-Port',[string]$port,'-Repos',('"{0}"' -f $f.Repo))
        $base="http://localhost:$port"; $page=$null; $deadline=(Get-Date).AddSeconds(30)
        while (-not $page -and (Get-Date) -lt $deadline -and -not $process.HasExited) { try { $page=Invoke-WebRequest "$base/" -UseBasicParsing -TimeoutSec 2 } catch { Start-Sleep -Milliseconds 100 } }
        if (-not $page -and $process.HasExited) { Skip-Case 'HttpListener is unsupported or blocked in this environment' }
        Assert-True ([bool]$page) 'server did not start'
        $token=[regex]::Match($page.Content,'<meta\s+name="trinity-token"\s+content="([^"]+)">').Groups[1].Value
        $send={ param($path,$body)
            $req=[Net.HttpWebRequest]::Create("$base$path"); $req.Timeout=30000; $req.Method='POST'; $req.ContentType='application/json'; $req.Headers.Add('Origin',$base); $req.Headers.Add('X-Trinity-Token',$token)
            $bytes=[Text.Encoding]::UTF8.GetBytes(($body | ConvertTo-Json -Depth 8 -Compress)); $req.ContentLength=$bytes.Length; $stream=$req.GetRequestStream(); $stream.Write($bytes,0,$bytes.Length); $stream.Dispose()
            try { $res=$req.GetResponse() } catch [Net.WebException] { if (-not $_.Exception.Response) { throw }; $res=$_.Exception.Response }
            $reader=New-Object IO.StreamReader($res.GetResponseStream()); $result=@{status=[int]$res.StatusCode; text=$reader.ReadToEnd()}; $reader.Dispose(); $res.Dispose(); return $result
        }
        $stateOk=$false; for ($i=0; $i -lt 50 -and -not $stateOk; $i++) { try { $stateOk=@((Invoke-WebRequest "$base/api/state" -UseBasicParsing -TimeoutSec 5).Content | ConvertFrom-Json).repos.Count -gt 0 } catch { }; if (-not $stateOk) { Start-Sleep -Milliseconds 200 } }
        $dash=[string][char]0x2014
        $reply=& $send '/api/action' @{action='queue-add';repo=$f.Repo;task='em-queue';agent='claude';scope='src/em/*';prompt=("do this $dash then that");confirm=$true}
        Assert-True ($reply.status -eq 202) "em-dash queue-add rejected: $($reply.status) $($reply.text)"
        $written=@(Get-ChildItem (Join-Path $f.Repo '.codex-out') -Filter 'prompt-em-queue-*.md')
        Assert-True ($written.Count -eq 1 -and ([IO.File]::ReadAllText($written[0].FullName) -match $dash)) 'em-dash prompt file missing or mangled'
        $reply=& $send '/api/action' @{action='dispatch';repo=$f.Repo;task='em-disp';agent='claude';scope='src/emd/*';prompt=("go $dash now");confirm=$true}
        Assert-True ($reply.status -eq 202) "em-dash dispatch rejected: $($reply.status) $($reply.text)"
        $bad='src/' + [char]0x2019 + 'x'
        $reply=& $send '/api/action' @{action='dispatch';repo=$f.Repo;task='bad-disp';agent='claude';scope=$bad;prompt='x';confirm=$true}
        Assert-True ($reply.status -eq 400 -and $reply.text -match 'Scope must be printable ASCII') "u2019 scope not rejected on dispatch: $($reply.text)"
        $reply=& $send '/api/action' @{action='queue-add';repo=$f.Repo;task='bad-queue';agent='claude';scope=$bad;prompt='x';confirm=$true}
        Assert-True ($reply.status -eq 400 -and $reply.text -match 'Scope must be printable ASCII') "u2019 scope not rejected on queue-add: $($reply.text)"
    } finally { if ($process) { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue } }
}

Run-Case 'dash-api: generated queue-add script binds named parameters end to end' {
    param($f)
    & {
        . (Join-Path $f.Repo 'scripts\dashboard.ps1') -LibraryOnly
        $promptFile=Join-Path $f.Repo 'e2e-prompt.md'; [IO.File]::WriteAllText($promptFile,'hello')
        $script=Convert-ActionScript $f.Repo @(,(Get-QueueAddCommand 'claude' 'e2e-task' 'src/e2e/*' $promptFile))
        $ps=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($script))
        $out=& $ps -NoProfile -ExecutionPolicy Bypass -EncodedCommand $encoded 2>&1 | Out-String
        Assert-True ($LASTEXITCODE -eq 0 -and $out -match 'Queued e2e-task') "queue add failed ($LASTEXITCODE): $out"
        $list=& $ps -NoProfile -ExecutionPolicy Bypass -File (Join-Path $f.Repo 'scripts\trinity.ps1') queue list -Json | Out-String
        $item=@((ConvertFrom-Json $list).items)[0]
        Assert-True ($item.task -eq 'e2e-task' -and $item.agent -eq 'claude' -and $item.scope -eq 'src/e2e/*' -and $item.promptFile -eq $promptFile) "queue item wrong: $list"
    }
}
