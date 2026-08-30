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
    $errorResult = New-DelegentTerminalToolsUnavailableError 'not safe/session'
    Assert-True (
        $errorResult.ExitCode -eq 1 -and
        $errorResult.Output -match '^WORKER_PROTOCOL_ERROR' -and
        $errorResult.Output -match 'kind: terminal_tools_unavailable' -and
        $errorResult.Output -match 'session_id: none' -and
        $errorResult.Output -notmatch 'not safe/session'
    )
    Write-Output 'PASS terminal tool catalog error contract'
    $passed++
}
catch {
    Write-Output "FAIL terminal tool catalog error contract: $($_.Exception.Message)"
}

if ($passed -ne 3) {
    Write-Output "FAILED $passed/3"
    exit 1
}

Write-Output 'PASS 3/3'
exit 0
