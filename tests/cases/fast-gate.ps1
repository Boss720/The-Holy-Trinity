Run-Case 'fast-gate: docs classifier and filter parameter' {
    param($f)
    $tokens = $null; $errors = $null
    $tree = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $f.Repo 'scripts\trinity.ps1'), [ref]$tokens, [ref]$errors)
    Assert-True ($errors.Count -eq 0) 'trinity.ps1 did not parse'
    $fn = $tree.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Test-DocsOnly' }, $true)
    Assert-True ($null -ne $fn) 'docs classifier missing'
    . ([scriptblock]::Create($fn.Extent.Text))
    Assert-True (Test-DocsOnly @('README.md', 'docs/x.md')) 'Markdown rejected'
    Assert-True (Test-DocsOnly @('docs/x.md', 'docs/y.md')) 'docs rejected'
    Assert-True (-not (Test-DocsOnly @('README.md', 'docs/a.png'))) 'image accepted'
    Assert-True (-not (Test-DocsOnly @('docs/x.md', 'scripts/a.ps1'))) 'mixed changes accepted'
    Assert-True (-not (Test-DocsOnly @())) 'empty changes accepted'
    $runner = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:repoSource 'tests\run-tests.ps1'), [ref]$tokens, [ref]$errors)
    Assert-True ($errors.Count -eq 0) 'test runner did not parse'
    Assert-True (@($runner.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'Filter' }).Count -eq 1) 'Filter parameter missing'
}
