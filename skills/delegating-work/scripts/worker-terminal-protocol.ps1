$script:DelegentTerminalNormalFields = @(
    'status',
    'summary',
    'evidence',
    'changes',
    'tests',
    'risks',
    'decisions_needed',
    'review_targets'
)
$script:DelegentDecisionToolFields = @(
    'question',
    'evidence',
    'options',
    'recommendation',
    'confidence'
)

function Install-DelegentTerminalTools {
    param(
        [string]$SkillRoot,
        [string]$ConfigDir
    )

    # ConfigDir is an explicit OpenCode config directory (OPENCODE_CONFIG_DIR),
    # so custom tools live directly under its documented tools/ child.
    $toolTarget = Join-Path $ConfigDir 'tools'
    New-Item -ItemType Directory -Force -Path $toolTarget -ErrorAction Stop | Out-Null
    foreach ($toolName in @('delegent_handoff.ts', 'delegent_decision.ts')) {
        $source = Join-Path (Join-Path $SkillRoot 'tools') $toolName
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
            throw [IO.FileNotFoundException]::new('Missing Delegent terminal tool.')
        }
        Copy-Item -LiteralPath $source -Destination (Join-Path $toolTarget $toolName) -Force -ErrorAction Stop
    }
    return $toolTarget
}

function Get-DelegentTerminalFieldNames {
    param([object]$Value)

    if ($null -eq $Value -or $Value -is [string]) { return @() }
    if ($Value -is [Collections.IDictionary]) {
        return @($Value.Keys | ForEach-Object { [string]$_ })
    }
    return @($Value.PSObject.Properties | ForEach-Object Name)
}

function Get-DelegentTerminalFieldValue {
    param(
        [object]$Value,
        [string]$Name
    )

    if ($Value -is [Collections.IDictionary]) {
        return $Value[$Name]
    }
    $property = $Value.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Test-DelegentTerminalFields {
    param(
        [object]$Value,
        [string[]]$Expected
    )

    $actual = @(Get-DelegentTerminalFieldNames $Value)
    if ($actual.Count -ne $Expected.Count) { return $false }
    foreach ($name in $Expected) {
        if ($actual -cnotcontains $name) { return $false }
        $fieldValue = Get-DelegentTerminalFieldValue $Value $name
        if ($fieldValue -isnot [string] -or [string]::IsNullOrWhiteSpace($fieldValue)) {
            return $false
        }
    }
    return $true
}

function Get-DelegentTerminalResult {
    param([object]$Message)

    if ($null -eq $Message) { return $null }
    $infoProperty = $Message.PSObject.Properties['info']
    $info = if ($null -ne $infoProperty) { $infoProperty.Value } else { $null }
    if ($null -eq $info -or [string]$info.role -cne 'assistant') { return $null }
    if ($null -ne $info.PSObject.Properties['error'] -and $null -ne $info.error) {
        throw [InvalidOperationException]::new('Worker runtime error.')
    }

    $terminal = @(
        @($Message.parts) | Where-Object {
            $_.type -ceq 'tool' -and $_.tool -cin @('delegent_handoff', 'delegent_decision')
        }
    )
    if ($terminal.Count -eq 0) { return $null }
    if ($terminal.Count -ne 1) {
        throw [FormatException]::new('Expected exactly one terminal Delegent tool call.')
    }

    $part = $terminal[0]
    if ($null -eq $part.state -or [string]$part.state.status -cne 'completed') {
        throw [FormatException]::new('Terminal Delegent tool did not complete.')
    }
    $input = $part.state.input

    if ($part.tool -ceq 'delegent_handoff') {
        if (-not (Test-DelegentTerminalFields $input $script:DelegentTerminalNormalFields)) {
            throw [FormatException]::new('Malformed terminal handoff arguments.')
        }
        $status = [string](Get-DelegentTerminalFieldValue $input 'status')
        if ($status -cnotin @('completed', 'blocked')) {
            throw [FormatException]::new('Malformed terminal handoff status.')
        }
        return [pscustomobject][ordered]@{
            status = $status
            summary = [string](Get-DelegentTerminalFieldValue $input 'summary')
            evidence = [string](Get-DelegentTerminalFieldValue $input 'evidence')
            changes = [string](Get-DelegentTerminalFieldValue $input 'changes')
            tests = [string](Get-DelegentTerminalFieldValue $input 'tests')
            risks = [string](Get-DelegentTerminalFieldValue $input 'risks')
            decisions_needed = [string](Get-DelegentTerminalFieldValue $input 'decisions_needed')
            review_targets = [string](Get-DelegentTerminalFieldValue $input 'review_targets')
        }
    }

    if (-not (Test-DelegentTerminalFields $input $script:DelegentDecisionToolFields)) {
        throw [FormatException]::new('Malformed terminal decision arguments.')
    }
    return [pscustomobject][ordered]@{
        kind = 'decision_needed'
        question = [string](Get-DelegentTerminalFieldValue $input 'question')
        evidence = [string](Get-DelegentTerminalFieldValue $input 'evidence')
        options = [string](Get-DelegentTerminalFieldValue $input 'options')
        recommendation = [string](Get-DelegentTerminalFieldValue $input 'recommendation')
        confidence = [string](Get-DelegentTerminalFieldValue $input 'confidence')
    }
}

function Get-DelegentRecoveredTerminalResult {
    param(
        [object[]]$Messages,
        [hashtable]$BaselineIds
    )

    $results = @()
    foreach ($message in @($Messages)) {
        if ($null -eq $message.info -or $message.info.role -cne 'assistant') { continue }
        $messageId = [string]$message.info.id
        if ($BaselineIds.ContainsKey($messageId)) { continue }
        $candidate = Get-DelegentTerminalResult $message
        if ($null -ne $candidate) { $results += ,$candidate }
    }
    if ($results.Count -gt 1) {
        throw [FormatException]::new('Multiple terminal Delegent tool calls were produced.')
    }
    if ($results.Count -eq 1) { return $results[0] }
    return $null
}

function Invoke-DelegentWorkerProtocol {
    param(
        [object]$Invocation,
        [scriptblock]$Request,
        [string[]]$SensitiveValues = @(),
        [ValidateRange(1, 86400)][int]$PromptTimeoutSeconds = 300,
        [ValidateRange(1, 60)][int]$RecoveryTimeoutSeconds = 5
    )

    $sessionId = [string]$Invocation.Session
    if ([string]::IsNullOrWhiteSpace($sessionId)) {
        try {
            $createBody = if ($Invocation.Title) { @{ title = $Invocation.Title } } else { @{} }
            $createJson = & $Request 'POST' '/session' ($createBody | ConvertTo-Json -Compress) $RecoveryTimeoutSeconds
            $created = ConvertFrom-DelegentUniqueJson $createJson
            $sessionId = [string]$created.id
            if ([string]::IsNullOrWhiteSpace($sessionId)) { throw [FormatException]::new('Missing session ID.') }
        }
        catch {
            return New-DelegentProtocolError -Kind runtime_output_error
        }
    }

    $sessionPathId = [Uri]::EscapeDataString($sessionId)
    $baselineIds = @{}
    $canRecover = -not $Invocation.Session
    if ($Invocation.Session) {
        try {
            $baselineJson = & $Request 'GET' "/session/$sessionPathId/message" $null $RecoveryTimeoutSeconds
            foreach ($message in @(ConvertFrom-DelegentUniqueJson $baselineJson)) {
                if ($null -ne $message.info -and $message.info.role -ceq 'assistant') {
                    if (-not $message.info.id) { throw [FormatException]::new('Unidentifiable baseline message.') }
                    $baselineIds[[string]$message.info.id] = $true
                }
            }
            $canRecover = $true
        }
        catch {
            $canRecover = $false
        }
    }

    # Live testing on OpenCode 1.18.25 showed that format=json_schema fails in
    # this stack while ordinary OpenCode and direct Nemotron named-tool calls
    # succeed. Keep the runtime on the normal tool path and read only the
    # dedicated terminal-tool inputs from the returned session message.
    $body = [ordered]@{
        model = @{ providerID = 'nvidia'; modelID = 'nvidia/nemotron-3-super-120b-a12b' }
        parts = @(@{ type = 'text'; text = $Invocation.Prompt })
    }

    $timedOut = $false
    $primaryJson = $null
    try {
        $primaryJson = & $Request 'POST' "/session/$sessionPathId/message" ($body | ConvertTo-Json -Depth 20 -Compress) $PromptTimeoutSeconds
    }
    catch {
        if (Test-DelegentTimeoutError $_) {
            $timedOut = $true
        }
        else {
            return New-DelegentProtocolError -Kind runtime_output_error -SessionId $sessionId
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($primaryJson)) {
        try {
            $primary = ConvertFrom-DelegentUniqueJson $primaryJson
            $terminal = Get-DelegentTerminalResult $primary
            if ($null -ne $terminal) {
                return ConvertTo-DelegentLeadOutput $terminal $SensitiveValues
            }
        }
        catch [InvalidOperationException] {
            return New-DelegentProtocolError -Kind runtime_output_error -SessionId $sessionId
        }
        catch {
            return New-DelegentProtocolError -Kind malformed_handoff -SessionId $sessionId
        }
    }

    if ($canRecover) {
        try {
            $messagesJson = & $Request 'GET' "/session/$sessionPathId/message" $null $RecoveryTimeoutSeconds
            $messages = @(ConvertFrom-DelegentUniqueJson $messagesJson)
            $terminal = Get-DelegentRecoveredTerminalResult $messages $baselineIds
            if ($null -ne $terminal) {
                return ConvertTo-DelegentLeadOutput $terminal $SensitiveValues
            }
        }
        catch [InvalidOperationException] {
            return New-DelegentProtocolError -Kind runtime_output_error -SessionId $sessionId
        }
        catch {
            return New-DelegentProtocolError -Kind malformed_handoff -SessionId $sessionId
        }
    }

    if ($timedOut) {
        try { $null = & $Request 'POST' "/session/$sessionPathId/abort" '{}' $RecoveryTimeoutSeconds } catch {}
        return New-DelegentProtocolError -Kind timeout -SessionId $sessionId
    }
    New-DelegentProtocolError -Kind missing_terminal_handoff -SessionId $sessionId
}
