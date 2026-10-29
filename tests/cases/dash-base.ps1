Run-Case 'dash-base: configured base and diff' {
    param($f)
    Invoke-Git $f.Repo @('checkout','-b','develop') | Out-Null
    [IO.File]::WriteAllText((Join-Path $f.Repo 'develop.txt'),'develop')
    Invoke-Git $f.Repo @('add','develop.txt') | Out-Null
    Invoke-Git $f.Repo @('commit','-m','develop') | Out-Null
    Invoke-Git $f.Repo @('checkout','-b','agent/codex/example') | Out-Null
    [IO.File]::WriteAllText((Join-Path $f.Repo 'task.txt'),'task')
    Invoke-Git $f.Repo @('add','task.txt') | Out-Null
    Invoke-Git $f.Repo @('commit','-m','task') | Out-Null
    $dir=Join-Path $f.Repo '.trinity'; [void][IO.Directory]::CreateDirectory($dir)
    [IO.File]::WriteAllText((Join-Path $dir 'trinity.json'),'{"base":"develop"}')
    & {
        . (Join-Path $f.Repo 'scripts\dashboard.ps1') -LibraryOnly
        $state=Get-RepoState $f.Repo
        Assert-True ($state.base -eq 'develop') 'state base incorrect'
        $diff=Get-TaskDiff $f.Repo ([pscustomobject]@{task='example';branch='agent/codex/example'})
        Assert-True ($diff.base -eq 'develop' -and $diff.files.Count -eq 1 -and $diff.files[0].path -eq 'task.txt') 'diff base incorrect'
    }
}
Run-Case 'dash-base: fallback and origin head cache' {
    param($f)
    & {
        . (Join-Path $f.Repo 'scripts\dashboard.ps1') -LibraryOnly
        Assert-True ((Get-RepoBase $f.Repo) -eq 'main') 'fallback incorrect'
        Invoke-Git $f.Repo @('symbolic-ref','refs/remotes/origin/HEAD','refs/remotes/origin/develop') | Out-Null
        Assert-True ((Get-RepoBase $f.Repo) -eq 'main') 'origin fallback was not cached'
        $script:BaseCache.Clear()
        Assert-True ((Get-RepoBase $f.Repo) -eq 'develop') 'origin head incorrect'
    }
}
Run-Case 'dash-base: agent task uses configured base' {
    param($f)
    Invoke-Git $f.Repo @('checkout','-b','develop') | Out-Null
    [IO.File]::WriteAllText((Join-Path $f.Repo 'develop.txt'),'develop')
    Invoke-Git $f.Repo @('add','develop.txt') | Out-Null
    Invoke-Git $f.Repo @('commit','-m','develop') | Out-Null
    Invoke-Git $f.Repo @('checkout','main') | Out-Null
    $dir=Join-Path $f.Repo '.trinity'; [void][IO.Directory]::CreateDirectory($dir)
    [IO.File]::WriteAllText((Join-Path $dir 'trinity.json'),'{"base":"develop"}')
    $exe=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $oldPreference=$ErrorActionPreference; $ErrorActionPreference='Continue'
    try { $output=& $exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $f.Repo 'scripts\agent-task.ps1') -Agent codex -Task sample 2>&1 } finally { $ErrorActionPreference=$oldPreference }
    Assert-True ($LASTEXITCODE -eq 0) "agent task failed: $output"
    $head=Invoke-Git $f.Repo @('rev-parse','agent/codex/sample')
    Assert-True ($head -eq (Invoke-Git $f.Repo @('rev-parse','develop'))) 'task did not branch from develop'
}
Run-Case 'dash-base: first state responds promptly' {
    param($f)
    $process=$null
    try {
        $tcp=New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,0); $tcp.Start(); $port=$tcp.LocalEndpoint.Port; $tcp.Stop()
        $exe=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $process=Start-Process -FilePath $exe -WindowStyle Hidden -PassThru -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"{0}"' -f (Join-Path $f.Repo 'scripts\dashboard.ps1')),'-Port',[string]$port)
        $page=$null; $deadline=(Get-Date).AddSeconds(20)
        while (-not $page -and (Get-Date) -lt $deadline -and -not $process.HasExited) { try { $page=Invoke-WebRequest "http://localhost:$port/" -UseBasicParsing -TimeoutSec 2 } catch { Start-Sleep -Milliseconds 100 } }
        if (-not $page -and $process.HasExited) { Skip-Case 'HttpListener is unsupported or blocked in this environment' }
        Assert-True ([bool]$page) 'server did not start'
        $watch=[Diagnostics.Stopwatch]::StartNew(); $state=Invoke-WebRequest "http://localhost:$port/api/state" -UseBasicParsing -TimeoutSec 5; $watch.Stop()
        Assert-True ($state.StatusCode -eq 200 -and $watch.Elapsed.TotalSeconds -lt 5) 'first state was slow'
    } finally { if ($process) { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue } }
}
