$script:DelegentRequiredTerminalTools = @(
    'delegent_handoff',
    'delegent_decision'
)

function Test-DelegentTerminalToolCatalog {
    param([object[]]$ToolIds)

    $ids = @($ToolIds | ForEach-Object { [string]$_ })
    foreach ($required in $script:DelegentRequiredTerminalTools) {
        if ($ids -cnotcontains $required) { return $false }
    }
    return $true
}

function New-DelegentTerminalToolsUnavailableError {
    param([string]$SessionId)

    $safeSessionId = if ($SessionId -match '^[A-Za-z0-9_.-]{1,128}$') { $SessionId } else { 'none' }
    $output = @(
        'WORKER_PROTOCOL_ERROR'
        'kind: terminal_tools_unavailable'
        "session_id: $safeSessionId"
        'exit_code: none'
        'summary: OpenCode did not register the required Delegent terminal tools.'
    ) -join [Environment]::NewLine

    [pscustomobject]@{ ExitCode = 1; Output = $output }
}
