$ErrorActionPreference = 'Stop'
$mode = $env:FAKE_CODEX_MODE
if (-not $mode) { $mode = 'ok' }
$arguments = $env:FAKE_CODEX_ARGUMENTS

if ($arguments -match '^\s*login\s+status') {
    if ($env:FAKE_CODEX_LOGGED_OUT) { [Console]::WriteLine('Not logged in'); exit 1 }
    [Console]::WriteLine('Logged in using ChatGPT')
    exit 0
}

if ($arguments -match '^\s*review(?:\s|$)') {
    # Like the real CLI: a review needs exactly one well-formed target flag.
    if ($arguments -notmatch '(?:^|\s)--(?:uncommitted|base\s+\S+|commit\s+\S+)(?:\s|$)') { [Console]::Error.WriteLine("error: unexpected argument in: $arguments"); exit 2 }
    if ($env:FAKE_REVIEW_OUTPUT) { [Console]::WriteLine($env:FAKE_REVIEW_OUTPUT) }
    else { [Console]::WriteLine('No findings.') }
    exit 0
}

if ($arguments -notmatch '^\s*exec(?:\s|$)') { exit 2 }
if ($mode -eq 'fail') { exit 3 }
if ($mode -eq 'hang') { while ($true) { Start-Sleep -Seconds 10 } }
if ($mode -eq 'stall-then-resume') {
    [Console]::WriteLine('initial output')
    [Console]::Out.Flush()
    Start-Sleep -Seconds 5
    [Console]::WriteLine('resumed output')
    [Console]::Out.Flush()
}

$workingDirectory = $null
$resultPath = $null
if ($arguments -match '(?:^|\s)-C\s+"([^"]+)"') { $workingDirectory = $Matches[1] }
elseif ($arguments -match '(?:^|\s)-C\s+(\S+)') { $workingDirectory = $Matches[1] }
if ($arguments -match '(?:^|\s)-o\s+"([^"]+)"') { $resultPath = $Matches[1] }
elseif ($arguments -match '(?:^|\s)-o\s+(\S+)') { $resultPath = $Matches[1] }
if (-not $workingDirectory -or -not $resultPath) { exit 2 }

$null = [Console]::In.ReadToEnd()
if ($mode -eq 'quiet-edits') {
    # Like Antigravity: no output until exit, but files keep changing.
    for ($i = 0; $i -lt 8; $i++) { [IO.File]::WriteAllText((Join-Path $workingDirectory 'fake-progress.txt'), "step $i", [System.Text.UTF8Encoding]::new($false)); Start-Sleep -Seconds 1 }
}
if ($mode -ne 'nochange') {
    [IO.File]::WriteAllText((Join-Path $workingDirectory 'fake-output.txt'), 'fake codex output' + "`r`n", [System.Text.UTF8Encoding]::new($false))
}
[IO.File]::WriteAllText($resultPath, 'Fake Codex completed successfully.' + "`r`n", [System.Text.UTF8Encoding]::new($false))
exit 0
