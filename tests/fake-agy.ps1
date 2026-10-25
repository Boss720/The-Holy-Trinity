$ErrorActionPreference = 'Stop'
$mode = $env:FAKE_AGY_MODE
if (-not $mode) { $mode = 'ok' }
$utf8 = [System.Text.UTF8Encoding]::new($false)
$json = $args -contains 'json'
$logIndex = [array]::IndexOf($args, '--log-file')
if ($logIndex -ge 0) {
    [IO.File]::WriteAllText($args[$logIndex + 1], 'workspaceDirs=[' + (Get-Location).Path + "]`r`nlabel=""Fake Gemini (High)""`r`ncascade_id:11111111-2222-3333-4444-555555555555`r`n", $utf8)
}

function Write-Answer([string]$Text) {
    if (-not $json) { [Console]::WriteLine($Text); return }
    $out = [ordered]@{ conversation_id = '11111111-2222-3333-4444-555555555555'; status = 'SUCCESS'; response = $Text; duration_seconds = 1.5; num_turns = 1
        usage = [ordered]@{ input_tokens = 100; output_tokens = 20; thinking_tokens = 5; cache_read_tokens = 40; total_tokens = 125 } }
    [Console]::WriteLine(($out | ConvertTo-Json -Compress))
}

# Read-only plan mode is how trinity asks Antigravity for reviews and answers; it must not touch files.
$modeIndex = [array]::IndexOf($args, '--mode')
if ($modeIndex -ge 0 -and $args[$modeIndex + 1] -eq 'plan') {
    if ($mode -eq 'fail') { exit 4 }
    $answer = if ($env:FAKE_REVIEW_OUTPUT) { $env:FAKE_REVIEW_OUTPUT } else { 'No findings.' }
    Write-Answer $answer
    exit 0
}

if ($mode -eq 'fail') { exit 4 }
if ($mode -eq 'slow') { Start-Sleep -Seconds 120 }

[IO.File]::WriteAllText((Join-Path (Get-Location).Path 'agy-output.txt'), 'fake agy output' + "`r`n", $utf8)
# Real agy -p prints background-task notices before the summary; the runner must strip them.
Write-Answer ("The following is a <SYSTEM_MESSAGE> not actually sent by the user.`n`n<SYSTEM_MESSAGE>`n[Message] fake background task finished`n</SYSTEM_MESSAGE>`nFake Antigravity completed successfully.")
exit 0
