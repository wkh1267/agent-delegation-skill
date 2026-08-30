$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $repoRoot 'skills\delegating-work\scripts\worker-protocol.ps1')
. (Join-Path $repoRoot 'skills\delegating-work\scripts\worker-terminal-protocol.ps1')

function Debug-NewNormalResult {
    [ordered]@{
        status = 'completed'
        summary = 'done'
        evidence = 'focused evidence'
        changes = 'none'
        tests = 'passed'
        risks = 'none'
        decisions_needed = 'none'
        review_targets = 'adapter'
    }
}

function Debug-NewTerminalPart {
    param(
        [string]$Tool,
        [object]$Input,
        [string]$Status = 'completed'
    )
    @{
        type = 'tool'
        tool = $Tool
        callID = 'call_test'
        state = @{
            status = $Status
            input = $Input
            output = 'recorded'
            title = 'terminal'
            metadata = @{}
            time = @{ start = 1; end = 2 }
        }
    }
}

function Debug-NewResponseJson {
    param(
        [object[]]$Parts = @(),
        [string]$Id = 'msg_new',
        [object]$ResponseError = $null
    )
    $info = @{ id = $Id; role = 'assistant' }
    if ($null -ne $ResponseError) { $info.error = $ResponseError }
    @{ info = $info; parts = $Parts } | ConvertTo-Json -Depth 16 -Compress
}

$script:DebugFakeRoutes = @{}
$script:DebugFakeRequest = {
    param($Method, $Path, $BodyJson, $TimeoutSeconds)
    $key = "$Method $Path"
    if (-not $script:DebugFakeRoutes.ContainsKey($key) -or $script:DebugFakeRoutes[$key].Count -eq 0) {
        throw "Unexpected fake request: $key"
    }
    $item = $script:DebugFakeRoutes[$key].Dequeue()
    return [string]$item
}
function Debug-NewFakeRequest {
    param([hashtable]$Routes)
    $script:DebugFakeRoutes = @{}
    foreach ($key in $Routes.Keys) {
        $queue = New-Object Collections.Queue
        foreach ($item in @($Routes[$key])) { $queue.Enqueue($item) }
        $script:DebugFakeRoutes[$key] = $queue
    }
    return $script:DebugFakeRequest
}

Write-Output 'DEBUG helper-generated shape'
$helperParts = @(Debug-NewTerminalPart 'delegent_handoff' (Debug-NewNormalResult))
$helperJson = Debug-NewResponseJson $helperParts
$helperMessage = ConvertFrom-DelegentUniqueJson $helperJson
$helperPart = @($helperMessage.parts)[0]
$helperFieldNames = @($helperPart.state.input.PSObject.Properties | ForEach-Object Name)
Write-Output ("helper_info_has_error={0}" -f ($null -ne $helperMessage.info.PSObject.Properties['error']))
Write-Output ("helper_parts_count={0}; type={1}; tool={2}; state={3}" -f @($helperMessage.parts).Count, $helperPart.type, $helperPart.tool, $helperPart.state.status)
Write-Output ("helper_input_fields={0}" -f ($helperFieldNames -join ','))
$helperTerminal = Get-DelegentTerminalResult $helperMessage
Write-Output ("helper_direct_status={0}" -f $helperTerminal.status)

Write-Output 'DEBUG helper-generated request invoke'
$helperRequest = Debug-NewFakeRequest @{
    'GET /session/ses_helper/message' = @('[]')
    'POST /session/ses_helper/message' = @($helperJson)
}
$helperResult = Invoke-DelegentWorkerProtocol ([pscustomobject]@{ Session = 'ses_helper'; Title = $null; Agent = 'plan'; Dir = $null; Prompt = 'task' }) $helperRequest
Write-Output ("helper_invoke_exit={0}" -f $helperResult.ExitCode)
Write-Output $helperResult.Output

Write-Output 'DEBUG original Error parameter collision'
function Debug-NewResponseJsonWithErrorName {
    param(
        [object[]]$Parts = @(),
        [string]$Id = 'msg_new',
        [object]$Error = $null
    )
    $info = @{ id = $Id; role = 'assistant' }
    if ($null -ne $Error) { $info.error = $Error }
    @{ info = $info; parts = $Parts } | ConvertTo-Json -Depth 16 -Compress
}
$errorNameJson = Debug-NewResponseJsonWithErrorName $helperParts
$errorNameMessage = ConvertFrom-DelegentUniqueJson $errorNameJson
Write-Output ("error_name_info_has_error={0}; error_name_error_type={1}" -f ($null -ne $errorNameMessage.info.PSObject.Properties['error']), $(if ($null -ne $errorNameMessage.info.PSObject.Properties['error']) { $errorNameMessage.info.error.GetType().FullName } else { 'none' }))
try {
    $errorNameTerminal = Get-DelegentTerminalResult $errorNameMessage
    Write-Output ("error_name_terminal_status={0}" -f $errorNameTerminal.status)
}
catch {
    Write-Output ("error_name_extract_exception={0}: {1}" -f $_.Exception.GetType().FullName, $_.Exception.Message)
}

Write-Output 'DEBUG command identity'
$definition = (Get-Command Invoke-DelegentWorkerProtocol).Definition
Write-Output ("has_terminal_call={0}" -f ($definition -match 'Get-DelegentTerminalResult'))
Write-Output ("has_structured_output_call={0}" -f ($definition -match 'Get-DelegentStructuredOutput\s+\$primary'))
