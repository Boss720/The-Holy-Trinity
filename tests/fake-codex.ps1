$ErrorActionPreference = 'Stop'
$mode = $env:FAKE_CODEX_MODE
if (-not $mode) { $mode = 'ok' }
$arguments = $env:FAKE_CODEX_ARGUMENTS

if ($arguments -match '^\s*review(?:\s|$)') {
    if ($env:FAKE_REVIEW_OUTPUT) { [Console]::WriteLine($env:FAKE_REVIEW_OUTPUT) }
    else { [Console]::WriteLine('No findings.') }
    exit 0
}

if ($arguments -notmatch '^\s*exec(?:\s|$)') { exit 2 }
if ($mode -eq 'fail') { exit 3 }

$workingDirectory = $null
$resultPath = $null
if ($arguments -match '(?:^|\s)-C\s+"([^"]+)"') { $workingDirectory = $Matches[1] }
elseif ($arguments -match '(?:^|\s)-C\s+(\S+)') { $workingDirectory = $Matches[1] }
if ($arguments -match '(?:^|\s)-o\s+"([^"]+)"') { $resultPath = $Matches[1] }
elseif ($arguments -match '(?:^|\s)-o\s+(\S+)') { $resultPath = $Matches[1] }
if (-not $workingDirectory -or -not $resultPath) { exit 2 }

$null = [Console]::In.ReadToEnd()
if ($mode -ne 'nochange') {
    [IO.File]::WriteAllText((Join-Path $workingDirectory 'fake-output.txt'), 'fake codex output' + "`r`n", [System.Text.UTF8Encoding]::new($false))
}
[IO.File]::WriteAllText($resultPath, 'Fake Codex completed successfully.' + "`r`n", [System.Text.UTF8Encoding]::new($false))
exit 0
