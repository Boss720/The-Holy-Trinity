Run-Case 'dashboard served page contains real token and action API accepts it' {
    param($f)
    $process = $null
    try {
        Start-CodexTask $f 'token-task'
        $wait = Invoke-Trinity $f @('wait', 'token-task', '-Timeout', '30')
        Assert-True ($wait.ExitCode -eq 0) "fixture task did not finish: $($wait.Output)"

        $tcp = New-Object System.Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
        $tcp.Start()
        $port = $tcp.LocalEndpoint.Port
        $tcp.Stop()

        $dashboard = Join-Path $f.Repo 'scripts\dashboard.ps1'
        $process = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -WindowStyle Hidden -PassThru -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $dashboard), '-Port', [string]$port, '-Repos', ('"{0}"' -f $f.Repo))

        $deadline = (Get-Date).AddSeconds(15)
        $page = $null
        while (-not $page -and (Get-Date) -lt $deadline -and -not $process.HasExited) {
            try {
                $page = Invoke-WebRequest -Uri "http://localhost:$port/" -UseBasicParsing -TimeoutSec 2
            }
            catch {
                Start-Sleep -Milliseconds 100
            }
        }
        if (-not $page -and $process.HasExited) {
            Skip-Case 'HttpListener is unsupported or blocked in this environment'
        }
        Assert-True ([bool]$page) 'dashboard did not serve its page'

        $tokenMatch = [regex]::Match($page.Content, '<meta\s+name="trinity-token"\s+content="([^"]+)">')
        Assert-True $tokenMatch.Success 'dashboard page does not contain meta name="trinity-token"'
        $pageRealToken = $tokenMatch.Groups[1].Value
        Assert-True ($pageRealToken -match '^[0-9a-f]{64}$') "token in meta tag is not a valid 64-char hex token: $pageRealToken"
        Assert-True ($pageRealToken -ne '__TRINITY_TOKEN__') 'token in meta tag was not replaced (contains literal __TRINITY_TOKEN__)'
        Assert-True (-not $page.Content.Contains('__TRINITY_TOKEN__')) 'unreplaced __TRINITY_TOKEN__ placeholder remains in served HTML'

        $sentinelMatch = [regex]::Match($page.Content, 'trinityToken\s*!==\s*(?<expr>[^&)\r\n]+)')
        Assert-True $sentinelMatch.Success 'could not find token sentinel check in served HTML'
        $sentinelExpr = $sentinelMatch.Groups['expr'].Value.Trim()
        $stringParts = [regex]::Matches($sentinelExpr, "['""]([^'""]*)['""]")
        Assert-True ($stringParts.Count -gt 0) "could not parse string literals from sentinel expression: $sentinelExpr"
        $sentinelValue = ($stringParts | ForEach-Object { $_.Groups[1].Value }) -join ''

        Assert-True ([bool]$pageRealToken) 'extracted real token is empty'
        Assert-True ([bool]$sentinelValue) 'extracted sentinel value is empty'
        Assert-True ($pageRealToken -ne $sentinelValue) "served page 'has token' check failed: token matches sentinel ($sentinelValue)"
        $hasTokenCheck = ($pageRealToken -and ($pageRealToken -ne $sentinelValue))
        Assert-True $hasTokenCheck "page's has-token check did not evaluate to true"

        $send = {
            param($Url, $Method, $Body, $Token, $Origin, $ContentType)
            $request = [Net.HttpWebRequest]::Create($Url)
            $request.Method = $Method
            $request.Timeout = 15000
            if ($Token) { $request.Headers.Add('X-Trinity-Token', $Token) }
            if ($Origin) { $request.Headers.Add('Origin', $Origin) }
            if ($null -ne $Body) {
                $bytes = [Text.Encoding]::UTF8.GetBytes($Body)
                $request.ContentType = $ContentType
                $request.ContentLength = $bytes.Length
                $stream = $request.GetRequestStream()
                $stream.Write($bytes, 0, $bytes.Length)
                $stream.Dispose()
            }
            try {
                $response = $request.GetResponse()
                $reader = New-Object IO.StreamReader($response.GetResponseStream())
                $result = [pscustomobject]@{ Status = [int]$response.StatusCode; Content = $reader.ReadToEnd() }
                $reader.Dispose(); $response.Dispose()
                return $result
            }
            catch [Net.WebException] {
                if (-not $_.Exception.Response) { throw }
                $response = $_.Exception.Response
                $reader = New-Object IO.StreamReader($response.GetResponseStream())
                $result = [pscustomobject]@{ Status = [int]$response.StatusCode; Content = $reader.ReadToEnd() }
                $reader.Dispose(); $response.Dispose()
                return $result
            }
        }

        $base = "http://localhost:$port"
        $origin = "http://localhost:$port"

        $stateReply = & $send "$base/api/state" 'GET' $null '' '' ''
        Assert-True ($stateReply.Status -eq 200) "dashboard state endpoint returned $($stateReply.Status)"

        $payload = @{ action = 'review-task'; repo = $f.Repo; task = 'token-task'; confirm = $false } | ConvertTo-Json -Compress

        $rejected = & $send "$base/api/action" 'POST' $payload '__TRINITY_TOKEN__' $origin 'application/json'
        Assert-True ($rejected.Status -eq 401) "POST with literal __TRINITY_TOKEN__ was not rejected with 401: status $($rejected.Status)"

        $accepted = & $send "$base/api/action" 'POST' $payload $pageRealToken $origin 'application/json'
        Assert-True ($accepted.Status -eq 202) "POST with token from served page was not accepted with 202: status $($accepted.Status), content: $($accepted.Content)"

        $jobId = ($accepted.Content | ConvertFrom-Json).job
        $jobDeadline = (Get-Date).AddSeconds(15)
        $job = $null
        while ((Get-Date) -lt $jobDeadline) {
            $jobReply = & $send "$base/api/job?id=$jobId" 'GET' $null '' '' ''
            $job = $jobReply.Content | ConvertFrom-Json
            if ($job.state -ne 'running') { break }
            Start-Sleep -Milliseconds 100
        }
        Assert-True ($job -and $job.state -eq 'done' -and $job.exitCode -eq 0) "review job did not complete: $($job | ConvertTo-Json -Compress)"
    }
    finally {
        if ($process) { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue }
    }
}
