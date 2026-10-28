$ErrorActionPreference = 'Stop'
# Stand-in for the Claude Code CLI: "auth status" and "-p" (prompt on stdin), read-only.
if ($args.Count -ge 2 -and $args[0] -eq 'auth' -and $args[1] -eq 'status') {
    if ($env:FAKE_CLAUDE_LOGGED_OUT) { [Console]::WriteLine('{"loggedIn":false}'); exit 1 }
    [Console]::WriteLine('{"loggedIn":true}')
    exit 0
}
if ($args -notcontains '-p') { exit 2 }
if ($env:CLAUDECODE) { [Console]::Error.WriteLine('nested Claude session'); exit 5 }
$null = [Console]::In.ReadToEnd()
if ($env:FAKE_CLAUDE_MODE -eq 'fail') { exit 3 }
$modeIndex = [array]::IndexOf($args, '--permission-mode')
if ($modeIndex -ge 0 -and $modeIndex + 1 -lt $args.Count -and $args[$modeIndex + 1] -eq 'acceptEdits') {
    [IO.File]::WriteAllText((Join-Path (Get-Location) 'fake-claude.txt'), "fake Claude edit")
    [Console]::WriteLine('{"type":"result","result":"Fake Claude completed the task.","session_id":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","usage":{"input_tokens":1,"output_tokens":1},"duration_ms":10,"total_cost_usd":0.01,"model":"fake-claude"}')
    exit 0
}
$answer = if ($env:FAKE_REVIEW_OUTPUT) { $env:FAKE_REVIEW_OUTPUT } else { 'No findings.' }
[Console]::WriteLine($answer)
exit 0
