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

function New-DelegentTerminalCatalogError {
    param(
        [ValidateSet('terminal_tools_unavailable', 'terminal_tool_bootstrap_timeout', 'terminal_tool_catalog_error')]
        [string]$Kind,
        [string]$SessionId
    )

    $summaries = @{
        terminal_tools_unavailable      = 'OpenCode did not register the required Delegent terminal tools.'
        terminal_tool_bootstrap_timeout = 'OpenCode did not finish terminal-tool dependency bootstrap before the bounded timeout.'
        terminal_tool_catalog_error     = 'OpenCode could not resolve the terminal-tool runtime catalog.'
    }
    $safeSessionId = if ($SessionId -match '^[A-Za-z0-9_.-]{1,128}$') { $SessionId } else { 'none' }
    $output = @(
        'WORKER_PROTOCOL_ERROR'
        "kind: $Kind"
        "session_id: $safeSessionId"
        'exit_code: none'
        "summary: $($summaries[$Kind])"
    ) -join [Environment]::NewLine

    [pscustomobject]@{ ExitCode = 1; Output = $output }
}

function New-DelegentTerminalToolsUnavailableError {
    param([string]$SessionId)
    New-DelegentTerminalCatalogError -Kind terminal_tools_unavailable -SessionId $SessionId
}
