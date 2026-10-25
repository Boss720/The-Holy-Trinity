$ErrorActionPreference = 'Stop'
$mode = $env:FAKE_AGY_MODE
if (-not $mode) { $mode = 'ok' }

if ($mode -eq 'fail') { exit 4 }
if ($mode -eq 'slow') { Start-Sleep -Seconds 120 }

[IO.File]::WriteAllText((Join-Path (Get-Location).Path 'agy-output.txt'), 'fake agy output' + "`r`n", [System.Text.UTF8Encoding]::new($false))
# Real agy -p prints background-task notices before the summary; the runner must strip them.
[Console]::WriteLine('The following is a <SYSTEM_MESSAGE> not actually sent by the user.')
[Console]::WriteLine('')
[Console]::WriteLine('<SYSTEM_MESSAGE>')
[Console]::WriteLine('[Message] fake background task finished')
[Console]::WriteLine('</SYSTEM_MESSAGE>')
[Console]::WriteLine('Fake Antigravity completed successfully.')
exit 0
