$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $repoRoot 'skills\delegating-work\scripts\worker-protocol.ps1')
. (Join-Path $repoRoot 'skills\delegating-work\scripts\worker-terminal-protocol.ps1')

$normal = [ordered]@{
    status = 'completed'
    summary = 'done'
    evidence = 'focused evidence'
    changes = 'none'
    tests = 'passed'
    risks = 'none'
    decisions_needed = 'none'
    review_targets = 'adapter'
}
$part = @{
    type = 'tool'
    tool = 'delegent_handoff'
    callID = 'call_debug'
    state = @{
        status = 'completed'
        input = $normal
        output = 'recorded'
        title = 'terminal'
        metadata = @{}
        time = @{ start = 1; end = 2 }
    }
}
$script:ExpectedJson = @{ info = @{ id = 'msg_debug'; role = 'assistant' }; parts = @($part) } | ConvertTo-Json -Depth 16 -Compress

Write-Output 'DEBUG direct parse'
$message = ConvertFrom-DelegentUniqueJson $script:ExpectedJson
$terminal = Get-DelegentTerminalResult $message
$render = ConvertTo-DelegentLeadOutput $terminal
Write-Output ("direct_exit={0}; direct_status={1}" -f $render.ExitCode, $terminal.status)

Write-Output 'DEBUG simple request invoke'
$script:CapturedPostBody = $null
$request = {
    param($Method, $Path, $BodyJson, $TimeoutSeconds)
    if ($Method -eq 'GET') { return '[]' }
    if ($Method -eq 'POST' -and $Path -match '/message$') {
        $script:CapturedPostBody = $BodyJson
        return $script:ExpectedJson
    }
    throw "Unexpected request $Method $Path"
}
$invocation = [pscustomobject]@{ Session = 'ses_debug'; Title = $null; Agent = 'plan'; Dir = $null; Prompt = 'task' }
$result = Invoke-DelegentWorkerProtocol $invocation $request
Write-Output ("invoke_exit={0}" -f $result.ExitCode)
Write-Output $result.Output
if ($script:CapturedPostBody) {
    $captured = $script:CapturedPostBody | ConvertFrom-Json
    Write-Output ("body_has_format={0}; body_has_agent={1}" -f ($null -ne $captured.PSObject.Properties['format']), ($null -ne $captured.PSObject.Properties['agent']))
}

Write-Output 'DEBUG command identity'
$definition = (Get-Command Invoke-DelegentWorkerProtocol).Definition
Write-Output ("has_terminal_call={0}" -f ($definition -match 'Get-DelegentTerminalResult'))
Write-Output ("has_structured_output_call={0}" -f ($definition -match 'Get-DelegentStructuredOutput\s+\$primary'))
