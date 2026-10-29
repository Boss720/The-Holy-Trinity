Run-Case 'dash-auto-behavior: Auto targets and actions' {
    param($f)
    $node = Get-Command node -ErrorAction SilentlyContinue
    if (-not $node) { Skip-Case 'node is not installed' }
    $js = @'
const fs = require('fs');
const page = fs.readFileSync(process.argv[2], 'utf8');
function extract(name) {
  const start = page.indexOf('function ' + name + '(');
  if (start < 0) throw new Error('Missing function ' + name);
  const open = page.indexOf('{', start);
  let depth = 0;
  for (let i = open; i < page.length; i++) {
    if (page[i] === '{') depth++;
    if (page[i] === '}' && --depth === 0) return page.slice(start, i + 1);
  }
  throw new Error('Unclosed function ' + name);
}
const source = ['reposToAuto', 'updateAutoButton', 'autoAll'].map(extract).join('\n');
const run = new Function(source + `
  const headerAutoBtn = {};
  const actionsUiEnabled = () => true;
  let isSample = false, calls = [], toasts = [], lines = '', rejectRepo = '';
  const lastStateData = {repos: [
    {name: 'A', path: 'A', autopilot: {enabled: false, paused: false}, scheduler: {alive: false}},
    {name: 'B', path: 'B', autopilot: {enabled: true, paused: true, approval: true}, scheduler: {alive: true}},
    {name: 'C', path: 'C', autopilot: {enabled: true, paused: false}, scheduler: {alive: true}}
  ]};
  const confirmCommand = async (title, text) => { lines = text; return true; };
  const postAction = async body => {
    calls.push(body);
    if (body.repo === rejectRepo) throw new Error('rejected');
    return {done: Promise.resolve({state: 'done', exitCode: 0})};
  };
  const showToast = text => { toasts.push(text); };
  const pollState = () => {};
  const waitToast = async () => {
    for (let i = 0; i < 100 && !toasts.length; i++) await new Promise(resolve => setImmediate(resolve));
    if (!toasts.length) throw new Error('Auto did not produce a toast');
  };
  return (async () => {
    const targets = reposToAuto(lastStateData).map(r => r.name);
    updateAutoButton(lastStateData);
    const button = {...headerAutoBtn};
    autoAll(); await waitToast();
    const success = {lines, calls, toast: toasts[0]};
    calls = []; toasts = []; isSample = true;
    autoAll(); await waitToast();
    const sample = {calls, toast: toasts[0]};
    calls = []; toasts = []; isSample = false; rejectRepo = 'A';
    autoAll(); await waitToast();
    return {targets, button, success, sample, failure: {calls, toast: toasts[0]}};
  })();
`);
run().then(result => console.log(JSON.stringify(result))).catch(err => { console.error(err); process.exitCode = 1; });
'@
    $path = Join-Path $f.Root 'dash-auto-behavior.js'
    [IO.File]::WriteAllText($path, $js, [Text.Encoding]::UTF8)
    $output = & $node.Source $path (Join-Path $script:repoSource 'scripts\dashboard.html')
    Assert-True ($LASTEXITCODE -eq 0) "node failed: $output"
    $result = $output | ConvertFrom-Json
    Assert-True ((@($result.targets) -join ',') -ceq 'A,B') 'Auto must target A and B only'
    Assert-True (-not $result.button.disabled -and $result.button.title -match '2 repos') 'Auto button must be enabled for two repos'
    $lines = @($result.success.lines -split "`n")
    Assert-True ($lines.Count -eq 2 -and $lines[0] -match '"A"' -and $lines[0] -notmatch 'unpause') 'A confirmation must not unpause'
    Assert-True ($lines[1] -match '"B"' -and $lines[1].Contains('trinity unpause && trinity autopilot on -Approval && trinity scheduler start')) 'B confirmation must show unpause and approval'
    $calls = @($result.success.calls)
    $a = @($calls | Where-Object { $_.repo -ceq 'A' })
    $b = @($calls | Where-Object { $_.repo -ceq 'B' })
    Assert-True ($calls.Count -eq 3 -and $a.Count -eq 1 -and $a[0].action -ceq 'autopilot') 'A must post only autopilot'
    Assert-True ($b.Count -eq 2 -and $b[0].action -ceq 'unpause' -and $b[1].action -ceq 'autopilot') 'B must unpause before autopilot'
    Assert-True ($b[1].enabled -eq $true -and $b[1].approval -eq $true -and $b[1].confirm -eq $true) 'B autopilot must be enabled with approval and confirmation'
    Assert-True ($result.success.toast -ceq 'Auto: started 2 of 2 repos') 'success toast count incorrect'
    Assert-True (@($result.sample.calls).Count -eq 0 -and $result.sample.toast -match 'Sample mode') 'sample mode must not post actions'
    Assert-True ($result.failure.toast -ceq 'Auto: started 1 of 2 repos') 'failure toast count incorrect'
}
