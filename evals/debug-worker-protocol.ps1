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

Write-Output 'DEBUG queued route harness'
$script:DebugRoutes = @{}
foreach ($entry in @{
    'GET /session/ses_queue/message' = @('[]')
    'POST /session/ses_queue/message' = @($script:ExpectedJson)
}.GetEnumerator()) {
    $q = New-Object Collections.Queue
    foreach ($item in @($entry.Value)) { $q.Enqueue($item) }
    $script:DebugRoutes[$entry.Key] = $q
}
$queuedRequest = {
    param($Method, $Path, $BodyJson, $TimeoutSeconds)
    $key = "$Method $Path"
    $item = $script:DebugRoutes[$key].Dequeue()
    return [string]$item
}
$directGet = & $queuedRequest 'GET' '/session/ses_queue/message' $null 5
$directPost = & $queuedRequest 'POST' '/session/ses_queue/message' '{}' 5
Write-Output ("queued_get={0}; queued_equal={1}; queued_type={2}; queued_len={3}" -f $directGet, ($directPost -ceq $script:ExpectedJson), $directPost.GetType().FullName, $directPost.Length)
$queuedMessage = ConvertFrom-DelegentUniqueJson $directPost
$queuedTerminal = Get-DelegentTerminalResult $queuedMessage
Write-Output ("queued_terminal_status={0}" -f $queuedTerminal.status)

# Rebuild queues, then exercise the real protocol through the same harness.
$script:DebugRoutes = @{}
foreach ($entry in @{
    'GET /session/ses_queue/message' = @('[]')
    'POST /session/ses_queue/message' = @($script:ExpectedJson)
}.GetEnumerator()) {
    $q = New-Object Collections.Queue
    foreach ($item in @($entry.Value)) { $q.Enqueue($item) }
    $script:DebugRoutes[$entry.Key] = $q
}
$queuedResult = Invoke-DelegentWorkerProtocol ([pscustomobject]@{ Session = 'ses_queue'; Title = $null; Agent = 'plan'; Dir = $null; Prompt = 'task' }) $queuedRequest
Write-Output ("queued_invoke_exit={0}" -f $queuedResult.ExitCode)
Write-Output $queuedResult.Output

Write-Output 'DEBUG command identity'
$definition = (Get-Command Invoke-DelegentWorkerProtocol).Definition
Write-Output ("has_terminal_call={0}" -f ($definition -match 'Get-DelegentTerminalResult'))
Write-Output ("has_structured_output_call={0}" -f ($definition -match 'Get-DelegentStructuredOutput\s+\$primary'))
