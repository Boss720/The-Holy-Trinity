function ConvertTo-TrinityMap($Value) {
    if ($Value -is [System.Collections.IDictionary]) {
        $out = @{}; foreach ($key in $Value.Keys) { $out[$key] = ConvertTo-TrinityMap $Value[$key] }; return $out
    }
    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        $out = @{}; foreach ($property in $Value.PSObject.Properties) { $out[$property.Name] = ConvertTo-TrinityMap $property.Value }; return $out
    }
    if ($Value -is [array]) { return ,@($Value | ForEach-Object { ConvertTo-TrinityMap $_ }) }
    return $Value
}
function Merge-TrinityMap($Target, $Patch) {
    foreach ($key in $Patch.Keys) {
        if ($Target[$key] -is [hashtable] -and $Patch[$key] -is [hashtable]) { Merge-TrinityMap $Target[$key] $Patch[$key] }
        else { $Target[$key] = $Patch[$key] }
    }
}
function Write-TrinityJson([string]$Path, $Value) {
    [void][IO.Directory]::CreateDirectory((Split-Path $Path -Parent))
    $tmp = "$Path.tmp"
    [IO.File]::WriteAllText($tmp, (ConvertTo-Json -InputObject $Value -Depth 100), (New-Object Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}
function Get-TrinityConfig($Paths) {
    $config = @{ version=1; slots=@{codex=2;antigravity=1;claude=1}; base=''; test=''; autoMerge=$false; maxRounds=3; deadlineMinutes=120; models=@{codex='';antigravity='';claude=''}; autopilot=@{enabled=$false;approval=$true;maxTasksPerHour=6;maxConsecutiveFailures=3;cleanRunsBeforeAutoMerge=10} }
    $source = @{}
    foreach ($key in $config.Keys) { $source[$key] = 'default'; if ($config[$key] -is [hashtable]) { foreach ($sub in $config[$key].Keys) { $source["$key.$sub"] = 'default' } } }
    $file = Join-Path $Paths.Main '.trinity\trinity.json'
    if (Test-Path -LiteralPath $file) {
        try {
            $data = ConvertTo-TrinityMap (ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($file)) -ErrorAction Stop)
            if ($data -isnot [hashtable]) { throw 'config must be an object' }
            foreach ($key in $data.Keys) { $source[$key] = 'file'; if ($data[$key] -is [hashtable]) { foreach ($sub in $data[$key].Keys) { $source["$key.$sub"] = 'file' } } }
            Merge-TrinityMap $config $data
        } catch { $config._error = $_.Exception.Message }
    }
    $config._source = $source
    return $config
}
function Set-TrinityConfig($Paths, [hashtable]$Patch) {
    $config = Get-TrinityConfig $Paths
    if ($config.ContainsKey('_error')) { throw "Cannot update unreadable config: $($config._error)" }
    $config.Remove('_source')
    Merge-TrinityMap $config $Patch
    foreach ($rule in @(@('slots.codex',0,8),@('slots.antigravity',0,8),@('slots.claude',0,8),@('maxRounds',1,10),@('deadlineMinutes',5,1440),@('autopilot.maxTasksPerHour',1,60),@('autopilot.maxConsecutiveFailures',1,20))) {
        $parts = $rule[0].Split('.'); $value = $config
        foreach ($part in $parts) { if ($value -isnot [hashtable] -or -not $value.ContainsKey($part)) { throw "Invalid $($rule[0])" }; $value = $value[$part] }
        if ($value -isnot [int] -and $value -isnot [long]) { throw "Invalid $($rule[0]): expected integer" }
        if ($value -lt $rule[1] -or $value -gt $rule[2]) { throw "Invalid $($rule[0]): expected $($rule[1])-$($rule[2])" }
    }
    Write-TrinityJson (Join-Path $Paths.Main '.trinity\trinity.json') $config
    return Get-TrinityConfig $Paths
}
