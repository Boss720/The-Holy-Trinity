Run-Case 'dash-api: ready and stalled task states' {
    param($f)
    & {
        . (Join-Path $f.Repo 'scripts\dashboard.ps1') -LibraryOnly
        Assert-True ((Get-TaskState 'running (stalled 5m)' $true) -eq 'stalled') 'live stalled task must be stalled'
        Assert-True ((Get-TaskState 'ready: review clean' $false) -eq 'ready') 'ready task must be ready'
        Assert-True ((Get-TaskState 'running' $true) -eq 'running') 'running task changed'
    }
}
