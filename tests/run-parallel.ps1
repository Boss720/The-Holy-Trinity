param(
    [int]$Jobs = $(
        $envJobs = 0
        if ([int]::TryParse([string]$env:TRINITY_TEST_JOBS, [ref]$envJobs) -and $envJobs -ge 1 -and $envJobs -le 64) {
            $envJobs
        } else {
            [Math]::Min(4, [Environment]::ProcessorCount)
        }
    ),
    [string]$Only,
    [switch]$Keep
)

$ErrorActionPreference = 'Stop'
if ($Jobs -lt 1) { $Jobs = 1 }
$runner = Join-Path $PSScriptRoot 'run-tests.ps1'
$psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$stamp = [Guid]::NewGuid().ToString('N')
$runTempRoot = Join-Path $env:TEMP "trinity-selftest-$stamp"

function Stop-RunProcesses([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    $normBack = $Path.Replace('/', '\').TrimEnd('\')
    $normFwd = $Path.Replace('\', '/').TrimEnd('/')
    try {
        $procs = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
            $_.ProcessId -ne $PID -and $_.CommandLine -and (
                $_.CommandLine.IndexOf($normBack, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or
                $_.CommandLine.IndexOf($normFwd, [StringComparison]::OrdinalIgnoreCase) -ge 0
            )
        }
        foreach ($p in $procs) {
            try { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue } catch { }
        }
    } catch { }
}

$shards = @()
for ($i = 0; $i -lt $Jobs; $i++) {
    $shardTempRoot = Join-Path $runTempRoot "s$i"
    $out = Join-Path $env:TEMP "trinity-shard-$stamp-$i.out.log"
    $err = Join-Path $env:TEMP "trinity-shard-$stamp-$i.err.log"
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $runner), '-Shard', "$i/$Jobs", '-TempRoot', ('"{0}"' -f $shardTempRoot))
    if ($Only) { $argList += @('-Only', ('"{0}"' -f $Only)) }
    if ($Keep) { $argList += '-Keep' }
    $proc = Start-Process -FilePath $psExe -ArgumentList $argList -WindowStyle Hidden -PassThru -RedirectStandardOutput $out -RedirectStandardError $err
    # PS 5.1: touching Handle caches the process handle so ExitCode is readable after exit.
    [void]$proc.Handle
    $shards += [pscustomobject]@{ Index = $i; Process = $proc; Out = $out; Err = $err }
}

$passed = 0
$failed = 0
$skipped = 0
$bad = $false
try {
    foreach ($s in $shards) {
        $s.Process.WaitForExit()
        $code = $s.Process.ExitCode
        if ($null -eq $code -or "$code" -eq '') { $code = -1 }
        $lines = @()
        if (Test-Path -LiteralPath $s.Out) { $lines = @(Get-Content -LiteralPath $s.Out) }
        foreach ($line in $lines) {
            if ($line -match '^(PASS|FAIL|SKIP)\b') { Write-Output $line }
        }
        $summary = $lines | Where-Object { $_ -match '^\d+ passed, \d+ failed, \d+ skipped$' } | Select-Object -Last 1
        if ($summary -and $summary -match '^(\d+) passed, (\d+) failed, (\d+) skipped$') {
            $passed += [int]$Matches[1]; $failed += [int]$Matches[2]; $skipped += [int]$Matches[3]
            if ([int]$Matches[2] -gt 0) { $bad = $true }
        }
        else {
            $bad = $true
            Write-Output "FAIL shard $($s.Index)/${Jobs}: no summary line (crash); log: $($s.Out)"
            $lines | Select-Object -Last 10 | ForEach-Object { Write-Output "  $_" }
        }
        if ($code -ne 0) {
            $bad = $true
            Write-Output "FAIL shard $($s.Index)/${Jobs}: exit code $code"
        }
        if (Test-Path -LiteralPath $s.Err) {
            $errText = @(Get-Content -LiteralPath $s.Err)
            if ($errText.Count -gt 0 -and $code -ne 0) { $errText | Select-Object -First 10 | ForEach-Object { Write-Output "  stderr: $_" } }
        }
    }
}
finally {
    Stop-RunProcesses $runTempRoot
    if (-not $Keep -and (Test-Path -LiteralPath $runTempRoot)) {
        for ($try = 1; $try -le 5; $try++) {
            Remove-Item -LiteralPath $runTempRoot -Recurse -Force -ErrorAction SilentlyContinue
            if (-not (Test-Path -LiteralPath $runTempRoot)) { break }
            if ($try -lt 5) { Start-Sleep -Milliseconds 300 }
        }
    }
}

# Failing runs keep every shard log: only PASS/FAIL/SKIP lines reach the console, the error details are in the logs.
if (-not $bad -and -not $Keep) {
    foreach ($s in $shards) { Remove-Item -LiteralPath $s.Out, $s.Err -Force -ErrorAction SilentlyContinue }
}
elseif ($bad) {
    foreach ($s in $shards) { Write-Output "shard $($s.Index) log: $($s.Out)" }
}

Write-Output "$passed passed, $failed failed, $skipped skipped"
if ($bad) { exit 1 }
exit 0
