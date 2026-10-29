Run-Case 'shard-balance: duration assignment and fallback' {
    param($f)
    $tokens = $null; $errors = $null
    $tree = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:repoSource 'tests\run-tests.ps1'), [ref]$tokens, [ref]$errors)
    Assert-True ($errors.Count -eq 0) 'test runner did not parse'
    $fn = $tree.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-ShardAssignment' }, $true)
    Assert-True ($null -ne $fn) 'assignment function missing'
    . ([scriptblock]::Create($fn.Extent.Text))
    $names = @('a', 'b', 'c', 'd')
    $path = Join-Path $f.Root 'durations.json'
    [IO.File]::WriteAllText($path, '{"a":100,"b":90,"c":10,"d":5}')
    $map = Get-ShardAssignment $names 2 $path
    $totals = @(0, 0); $values = @(100, 90, 10, 5)
    for ($i = 0; $i -lt $names.Count; $i++) { $totals[$map[$names[$i]]] += $values[$i] }
    Assert-True ([Math]::Abs($totals[0] - $totals[1]) -le 15) 'durations were not balanced'
    foreach ($bad in @((Join-Path $f.Root 'missing.json'), $path)) {
        if ($bad -eq $path) { [IO.File]::WriteAllText($path, '{bad') }
        $map = Get-ShardAssignment $names 2 $bad
        for ($i = 0; $i -lt $names.Count; $i++) { Assert-True ($map[$names[$i]] -eq ($i % 2)) 'fallback changed modulo assignment' }
    }
    [IO.File]::WriteAllText($path, '{"a":100,"b":10}')
    $map = Get-ShardAssignment @('a', 'b', 'c') 2 $path
    Assert-True ($map['a'] -eq 0 -and $map['c'] -eq 1 -and $map['b'] -eq 1) 'unknown case did not use median'
}
