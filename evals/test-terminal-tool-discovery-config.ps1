$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$protocolPath = Join-Path $repoRoot 'skills\delegating-work\scripts\worker-terminal-protocol.ps1'
$wrapperPath = Join-Path $repoRoot 'skills\delegating-work\scripts\nemotron-worker.ps1'
$skillRoot = Join-Path $repoRoot 'skills\delegating-work'
. $protocolPath

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message = 'Assertion failed.'
    )
    if (-not $Condition) { throw $Message }
}

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('delegent-discovery-' + [Guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
    $target = Install-DelegentTerminalTools -SkillRoot $skillRoot -ConfigDir $tempRoot

    Assert-True ((Split-Path -Leaf $target) -eq 'tools') 'Terminal tools must live in the explicit config directory tools child.'
    Assert-True ((Split-Path -Parent $target) -eq $tempRoot) 'Terminal tool installer must not add an inferred opencode directory.'
    Assert-True (Test-Path -LiteralPath (Join-Path $target 'delegent_handoff.ts'))
    Assert-True (Test-Path -LiteralPath (Join-Path $target 'delegent_decision.ts'))

    $wrapper = Get-Content -Raw $wrapperPath
    Assert-True ($wrapper -match 'OPENCODE_CONFIG_DIR') 'Wrapper must set an explicit OpenCode config directory.'
    Assert-True ($wrapper -match 'Install-DelegentTerminalTools') 'Wrapper must use the shared terminal tool installer.'
    Assert-True ($wrapper -notmatch "XDG_CONFIG_HOME\s+'opencode\\\\tools'") 'Wrapper must not infer terminal discovery from XDG_CONFIG_HOME.'
    Assert-True ($wrapper -match 'DELEGENT_BOOTSTRAP_TIMEOUT_SECONDS') 'Wrapper must expose a bounded cold-bootstrap timeout override.'
    Assert-True ($wrapper -match '\$bootstrapTimeoutSeconds\s*=\s*60') 'Cold terminal-tool bootstrap must have a bounded default window.'
    Assert-True ($wrapper -match 'terminal_tool_bootstrap_timeout') 'Bootstrap timeout must have a deterministic protocol error.'
    Assert-True ($wrapper -match 'terminal_tool_catalog_error') 'Catalog failure must have a deterministic protocol error.'

    Write-Output 'PASS explicit terminal tool discovery config'
    exit 0
}
finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
