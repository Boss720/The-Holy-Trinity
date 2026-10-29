Run-Case 'dash-auto: header and action wiring' {
    param($f)
    $page=[IO.File]::ReadAllText((Join-Path $script:repoSource 'scripts\dashboard.html'))
    $server=[IO.File]::ReadAllText((Join-Path $script:repoSource 'scripts\dashboard.ps1'))
    Assert-True ($page -match 'id="header-auto-btn"') 'Auto button missing'
    Assert-True ($page -match "action:\s*'autopilot'[^}]*enabled:\s*true") 'enabled autopilot action missing'
    Assert-True ($server -match '(?s)\$action -notin @\([^)]*''autopilot''') 'autopilot missing from server allow-list'
    Assert-True ($page -match "(?s)if \(ap\.paused\).*?action:\s*'unpause'.*?await unpause\.done.*?action:\s*'autopilot'") 'unpause must complete before autopilot'
    Assert-True ($page -match "headerAutoBtn\.addEventListener\('click'[^}]*autoAll\(\)") 'Auto button click is not wired to autoAll'
}
