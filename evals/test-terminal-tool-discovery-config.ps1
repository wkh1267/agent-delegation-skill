$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$wrapperPath = Join-Path $repoRoot 'skills\delegating-work\scripts\nemotron-worker.ps1'
$pluginPath = Join-Path $repoRoot 'skills\delegating-work\plugins\delegent-terminal.js'

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message = 'Assertion failed.'
    )
    if (-not $Condition) { throw $Message }
}

Assert-True (Test-Path -LiteralPath $pluginPath -PathType Leaf) 'Delegent terminal plugin must exist.'
$pluginUri = ([System.Uri]::new((Resolve-Path -LiteralPath $pluginPath).Path)).AbsoluteUri
Assert-True ($pluginUri -match '^file:///') 'Terminal plugin path must convert to a file URI on Windows.'

$plugin = Get-Content -Raw $pluginPath
Assert-True ($plugin -match 'delegent_handoff') 'Terminal plugin must register delegent_handoff.'
Assert-True ($plugin -match 'delegent_decision') 'Terminal plugin must register delegent_decision.'
Assert-True ($plugin -notmatch '@opencode-ai/plugin|Invoke-RestMethod|Invoke-WebRequest|api_key|nvapi-') 'Terminal plugin must be dependency-free and credential-blind.'

$wrapper = Get-Content -Raw $wrapperPath
Assert-True ($wrapper -match 'plugins\\delegent-terminal\.js') 'Wrapper must resolve the Delegent terminal plugin.'
Assert-True ($wrapper -match 'terminalPluginUri') 'Wrapper must add the local plugin URI to OpenCode config content.'
Assert-True ($wrapper -match 'Add-Member.+plugin') 'Wrapper must explicitly register the plugin when the base config has no plugin field.'
Assert-True ($wrapper -match 'OPENCODE_CONFIG_DIR\s*=\s*\$null') 'Wrapper must not depend on explicit config-directory tool discovery.'
Assert-True ($wrapper -match "OPENCODE_PURE\s*=\s*'false'") 'Worker server runs must force non-pure mode so external terminal plugins are not skipped.'
Assert-True ($wrapper -notmatch 'Install-DelegentTerminalTools\s+-SkillRoot') 'Wrapper must not use the legacy terminal-tool installer.'
Assert-True ($wrapper -match 'delegent_handoff\.ts' -and $wrapper -match 'delegent_decision\.ts') 'Wrapper must clean stale Delegent tool files from earlier discovery experiments.'
Assert-True ($wrapper -match 'DELEGENT_BOOTSTRAP_TIMEOUT_SECONDS') 'Wrapper must retain a bounded catalog/bootstrap timeout override.'
Assert-True ($wrapper -match '\$bootstrapTimeoutSeconds\s*=\s*60') 'Terminal plugin registration check must have a bounded default window.'
Assert-True ($wrapper -match '\$catalogSawIncomplete\s*=\s*\$true') 'Incomplete catalogs must be tracked as a readiness state.'
Assert-True ($wrapper -match '\$catalogSawIncomplete[\s\S]+terminal_tools_unavailable') 'Only the bounded final state may classify a persistently incomplete catalog as unavailable.'

$immediateUnavailablePattern = 'if\s*\(-not\s*\(Test-DelegentTerminalToolCatalog[\s\S]{0,500}New-DelegentTerminalCatalogError\s+-Kind\s+terminal_tools_unavailable'
Assert-True ($wrapper -notmatch $immediateUnavailablePattern) 'A successful but incomplete catalog must not fail immediately before plugin registration settles.'

Write-Output 'PASS explicit terminal plugin registration and readiness'
exit 0
