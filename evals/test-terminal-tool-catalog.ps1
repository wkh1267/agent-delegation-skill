$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$catalogPath = Join-Path $repoRoot 'skills\delegating-work\scripts\worker-terminal-catalog.ps1'
. $catalogPath

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message = 'Assertion failed.'
    )
    if (-not $Condition) { throw $Message }
}

$passed = 0

try {
    Assert-True (Test-DelegentTerminalToolCatalog @('read', 'delegent_handoff', 'delegent_decision'))
    Write-Output 'PASS complete terminal tool catalog'
    $passed++
}
catch {
    Write-Output "FAIL complete terminal tool catalog: $($_.Exception.Message)"
}

try {
    Assert-True (-not (Test-DelegentTerminalToolCatalog @('read', 'delegent_handoff')))
    Write-Output 'PASS incomplete terminal tool catalog'
    $passed++
}
catch {
    Write-Output "FAIL incomplete terminal tool catalog: $($_.Exception.Message)"
}

try {
    $errorResult = New-DelegentTerminalCatalogError -Kind terminal_tools_unavailable -SessionId 'not safe/session'
    Assert-True (
        $errorResult.ExitCode -eq 1 -and
        $errorResult.Output -match '^WORKER_PROTOCOL_ERROR' -and
        $errorResult.Output -match 'kind: terminal_tools_unavailable' -and
        $errorResult.Output -match 'session_id: none' -and
        $errorResult.Output -notmatch 'not safe/session'
    )
    Write-Output 'PASS terminal tool unavailable error contract'
    $passed++
}
catch {
    Write-Output "FAIL terminal tool unavailable error contract: $($_.Exception.Message)"
}

try {
    $errorResult = New-DelegentTerminalCatalogError -Kind terminal_tool_bootstrap_timeout
    Assert-True (
        $errorResult.ExitCode -eq 1 -and
        $errorResult.Output -match 'kind: terminal_tool_bootstrap_timeout' -and
        $errorResult.Output -match 'bounded timeout' -and
        $errorResult.Output -notmatch 'npm|node_modules|@opencode-ai/plugin'
    )
    Write-Output 'PASS terminal tool bootstrap timeout contract'
    $passed++
}
catch {
    Write-Output "FAIL terminal tool bootstrap timeout contract: $($_.Exception.Message)"
}

try {
    $errorResult = New-DelegentTerminalCatalogError -Kind terminal_tool_catalog_error
    Assert-True (
        $errorResult.ExitCode -eq 1 -and
        $errorResult.Output -match 'kind: terminal_tool_catalog_error' -and
        $errorResult.Output -match 'runtime catalog'
    )
    Write-Output 'PASS terminal tool catalog failure contract'
    $passed++
}
catch {
    Write-Output "FAIL terminal tool catalog failure contract: $($_.Exception.Message)"
}

if ($passed -ne 5) {
    Write-Output "FAILED $passed/5"
    exit 1
}

Write-Output 'PASS 5/5'
exit 0
