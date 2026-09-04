[CmdletBinding()]
param(
    [string]$RuntimeRoot,
    [ValidateRange(15, 300)]
    [int]$TimeoutSeconds = 240
)

# N4 — deterministic terminal handoff through Codex.
#
# The handoff travels as MCP tool-call arguments, not as a schema-constrained
# final message. That choice is forced by measured provider behaviour, recorded
# by N4a (`evals/probe-nim-structured-output.ps1`):
#
#   - Responses-native structured output is not enforced on hosted NIM. Exact
#     conformance was 8/10 at the provider, every failure being the same
#     mechanical malformation.
#   - Driving it through `codex exec --output-schema` was usable in 1 of 7
#     attempts. The rest hung, because Codex re-requests when the final message
#     fails the schema and a soft-enforcing provider never converges.
#   - Attaching `text.format` also suppresses function calling entirely (0/3),
#     so a tool-using Worker cannot carry the schema at all.
#
# Function calling, by contrast, is reliable here: it passed N1 with valid
# arguments and N3 with a real `exec_command`. So the boundary is the
# `delegent_handoff` MCP tool, whose input schema *is* the shipped Delegent
# handoff schema. The server validates every submission and rejects a
# non-conforming one with its violations, so the contract is enforced at the
# boundary rather than hoped for in a prompt. This probe then re-validates the
# persisted handoff independently, because a gate must not trust the component
# it is testing.
#
# Deliberate design point: the prompt does not describe the output shape. It
# does not name the handoff fields and does not mention JSON. The shape comes
# from the tool's advertised schema.

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$credentialSource = 'none'
$schemaPath = Join-Path $repoRoot 'skills\delegating-work\schemas\delegent-handoff.schema.json'
$serverPath = Join-Path $repoRoot 'skills\delegating-work\tools\delegent-handoff-mcp.js'
$expectedEvidenceLine = 'Context-aware coding-agent orchestration for Codex.'

function Get-NimCredential {
    if (-not [string]::IsNullOrWhiteSpace($env:NIM_API_KEY)) {
        $script:credentialSource = 'NIM_API_KEY'
        return [string]$env:NIM_API_KEY
    }
    if (-not [string]::IsNullOrWhiteSpace($env:DELEGENT_API_KEY)) {
        $script:credentialSource = 'DELEGENT_API_KEY'
        return [string]$env:DELEGENT_API_KEY
    }

    $envPath = Join-Path $repoRoot 'skills\delegating-work\.env'
    if (Test-Path -LiteralPath $envPath -PathType Leaf) {
        $settings = Get-Content -Raw -LiteralPath $envPath | ConvertFrom-StringData
        if (-not [string]::IsNullOrWhiteSpace([string]$settings.api_key)) {
            $script:credentialSource = 'delegating-work-env'
            return [string]$settings.api_key
        }
    }
    return $null
}

function Get-CodexLaunchSpec {
    $native = Get-Command codex.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($native) {
        return [pscustomobject]@{
            FileName = $native.Source
            ArgumentsPrefix = ''
            ArgumentsSuffix = ''
            Kind = 'native'
        }
    }

    $cmdShim = Get-Command codex.cmd -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmdShim) {
        $comspec = if ($env:ComSpec) { $env:ComSpec } else { 'cmd.exe' }
        return [pscustomobject]@{
            FileName = $comspec
            ArgumentsPrefix = ('/d /s /c ""' + $cmdShim.Source + '" ')
            ArgumentsSuffix = '"'
            Kind = 'cmd-shim'
        }
    }

    $command = Get-Command codex -CommandType Application, ExternalScript -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $command) { return $null }

    $extension = [IO.Path]::GetExtension([string]$command.Source).ToLowerInvariant()
    if ($extension -eq '.cmd' -or $extension -eq '.bat') {
        $comspec = if ($env:ComSpec) { $env:ComSpec } else { 'cmd.exe' }
        return [pscustomobject]@{
            FileName = $comspec
            ArgumentsPrefix = ('/d /s /c ""' + $command.Source + '" ')
            ArgumentsSuffix = '"'
            Kind = 'cmd-shim'
        }
    }
    if ($extension -eq '.ps1') {
        $powershell = Get-Command powershell.exe -CommandType Application -ErrorAction Stop | Select-Object -First 1
        return [pscustomobject]@{
            FileName = $powershell.Source
            ArgumentsPrefix = ('-NoProfile -ExecutionPolicy Bypass -File "' + $command.Source + '" ')
            ArgumentsSuffix = ''
            Kind = 'powershell-shim-fallback'
        }
    }

    return [pscustomobject]@{
        FileName = $command.Source
        ArgumentsPrefix = ''
        ArgumentsSuffix = ''
        Kind = 'application'
    }
}

function Get-SafeStderrSummary {
    param(
        [string]$CapturedStderr,
        [string]$Credential
    )

    if ([string]::IsNullOrWhiteSpace($CapturedStderr)) { return 'none' }
    $safe = [string]$CapturedStderr
    if (-not [string]::IsNullOrEmpty($Credential)) { $safe = $safe.Replace($Credential, '<redacted>') }
    $safe = [regex]::Replace($safe, '(?i)nvapi-[A-Za-z0-9_-]+', '<redacted>')
    $safe = [regex]::Replace($safe, '(?i)\bBearer\s+\S+', 'Bearer <redacted>')
    $safe = [regex]::Replace($safe, '(?i)\b(?:sk|key|token)-[A-Za-z0-9_-]{12,}', '<redacted>')
    $safe = [regex]::Replace($safe, 'https?://\S+', '<url>')
    $safe = [regex]::Replace($safe, '(?i)\b[A-Z]:\\(?:[^\\\s:"<>|]+\\)*[^\\\s:"<>|]*', '<path>')
    $safe = [regex]::Replace($safe, '(?<![A-Za-z0-9_])/(?:[^/\s]+/)+[^\s:;,]+', '<path>')
    $safe = [regex]::Replace($safe, '\b[A-Fa-f0-9]{32,}\b', '<id>')
    $safe = [regex]::Replace($safe, '\b[A-Za-z0-9_-]{48,}\b', '<token>')
    $safe = [regex]::Replace($safe, '[\r\n\t]+', ' ')
    $safe = [regex]::Replace($safe, '\s{2,}', ' ').Trim()
    if ($safe.Length -gt 800) { $safe = $safe.Substring(0, 800) + '...' }
    if ([string]::IsNullOrWhiteSpace($safe)) { return 'redacted' }
    return $safe
}

# Codex reports non-fatal startup notices on the same JSONL stream as real
# failures, either as a top-level `error` event or as an error-typed item. A
# single notice can appear on both item.started and item.completed, so items are
# de-duplicated by id before classification.
function Get-StreamErrorMessages {
    param([object[]]$Events)

    $messages = @()
    $seenItemIds = @{}
    foreach ($event in $Events) {
        $eventType = [string]$event.type
        if ($eventType -eq 'error') {
            $text = [string]$event.message
            if ([string]::IsNullOrWhiteSpace($text)) { $text = [string]$event.error }
            $messages += $text
            continue
        }
        if ($eventType -like 'item.*' -and $null -ne $event.item -and [string]$event.item.type -eq 'error') {
            $itemId = [string]$event.item.id
            if (-not [string]::IsNullOrWhiteSpace($itemId)) {
                if ($seenItemIds.ContainsKey($itemId)) { continue }
                $seenItemIds[$itemId] = $true
            }
            $messages += [string]$event.item.message
        }
    }
    return @($messages)
}

# Independent re-validation of the persisted handoff. The MCP boundary already
# validates, but a gate must not take the component under test at its word.
function Test-JsonAgainstSchema {
    param(
        [object]$Value,
        [object]$Schema,
        [string]$Path = '$'
    )

    $violations = @()
    $schemaType = [string]$Schema.type

    if ($schemaType -eq 'object') {
        if ($null -eq $Value -or $Value -is [Array] -or $Value -is [string] -or $Value -is [ValueType]) {
            return @("$Path is not an object")
        }
        $present = @($Value.PSObject.Properties.Name)
        foreach ($required in @($Schema.required)) {
            if ($present -notcontains [string]$required) { $violations += "$Path.$required is missing" }
        }
        $declared = @($Schema.properties.PSObject.Properties.Name)
        if ($false -eq $Schema.additionalProperties) {
            foreach ($name in $present) {
                if ($declared -notcontains $name) { $violations += "$Path.$name is not allowed" }
            }
        }
        foreach ($name in $declared) {
            if ($present -notcontains $name) { continue }
            $violations += Test-JsonAgainstSchema -Value $Value.$name -Schema $Schema.properties.$name -Path "$Path.$name"
        }
        return @($violations)
    }

    if ($schemaType -eq 'array') {
        if ($null -eq $Value -or -not ($Value -is [Array])) { return @("$Path is not an array") }
        $index = 0
        foreach ($element in @($Value)) {
            $violations += Test-JsonAgainstSchema -Value $element -Schema $Schema.items -Path "$Path[$index]"
            $index++
        }
        return @($violations)
    }

    if ($schemaType -eq 'string') {
        if (-not ($Value -is [string])) { return @("$Path is not a string") }
        $allowed = @($Schema.enum)
        if ($allowed.Count -gt 0 -and $allowed -notcontains [string]$Value) {
            return @("$Path is outside its allowed values")
        }
        return @()
    }

    return @("$Path has an unsupported schema type")
}

# Context Firewall: nothing crosses the Worker boundary before this runs.
function Remove-SensitiveValues {
    param(
        [string]$Text,
        [string]$Credential
    )

    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $safe = [string]$Text
    if (-not [string]::IsNullOrEmpty($Credential)) { $safe = $safe.Replace($Credential, '<redacted>') }
    $safe = [regex]::Replace($safe, '(?i)nvapi-[A-Za-z0-9_-]+', '<redacted>')
    $safe = [regex]::Replace($safe, '(?i)\bBearer\s+\S+', 'Bearer <redacted>')
    $safe = [regex]::Replace($safe, '(?i)\b(?:sk|key|token)-[A-Za-z0-9_-]{12,}', '<redacted>')
    $safe = [regex]::Replace($safe, '(?i)\b(api[_-]?key|secret|password|passwd|token)(\s*[:=]\s*)\S+', '$1$2<redacted>')
    $safe = [regex]::Replace($safe, '\b[A-Za-z0-9_-]{48,}\b', '<token>')
    return $safe
}

function Get-FilteredHandoff {
    param(
        [object]$Handoff,
        [object]$Schema,
        [string]$Credential,
        [ref]$FilteredStringCount
    )

    $count = 0
    foreach ($name in @($Schema.properties.PSObject.Properties.Name)) {
        $propertySchema = $Schema.properties.$name
        $value = $Handoff.$name
        if ([string]$propertySchema.type -eq 'string' -and $value -is [string]) {
            $Handoff.$name = Remove-SensitiveValues -Text $value -Credential $Credential
            $count++
        }
        elseif ([string]$propertySchema.type -eq 'array' -and $value -is [Array]) {
            $rewritten = @()
            foreach ($element in @($value)) {
                if ($element -is [string]) {
                    $rewritten += (Remove-SensitiveValues -Text $element -Credential $Credential)
                    $count++
                }
                else { $rewritten += $element }
            }
            $Handoff.$name = $rewritten
        }
    }
    $FilteredStringCount.Value = $count
    return $Handoff
}

function Get-WorkingTreeState {
    $lines = @(& git -C $repoRoot status --porcelain=v1 --untracked-files=all 2>$null)
    return ($lines -join "`n")
}

if ([string]::IsNullOrWhiteSpace($RuntimeRoot)) {
    if ($env:LOCALAPPDATA) { $RuntimeRoot = Join-Path $env:LOCALAPPDATA 'agent-delegation-skills\codex-nim' }
    else { $RuntimeRoot = Join-Path ([IO.Path]::GetTempPath()) 'agent-delegation-skills\codex-nim' }
}

$key = Get-NimCredential
if ([string]::IsNullOrWhiteSpace($key)) {
    Write-Output 'CODEX_NIM_HANDOFF_SCHEMA'
    Write-Output 'credential_present=False'
    Write-Output 'process_started=False'
    Write-Output 'overall=FAIL'
    Write-Output 'credential_value_logged=False'
    exit 1
}
$key = $key.Trim('"').Trim("'")

$launchSpec = Get-CodexLaunchSpec
if ($null -eq $launchSpec) {
    Write-Output 'CODEX_NIM_HANDOFF_SCHEMA'
    Write-Output 'credential_present=True'
    Write-Output 'codex_found=False'
    Write-Output 'process_started=False'
    Write-Output 'overall=FAIL'
    Write-Output 'credential_value_logged=False'
    exit 1
}

$codexCommand = Get-Command codex -CommandType Application, ExternalScript -ErrorAction SilentlyContinue | Select-Object -First 1
$codexVersion = (& $codexCommand.Source --version 2>$null | Select-Object -First 1)
if ([string]::IsNullOrWhiteSpace([string]$codexVersion)) { $codexVersion = 'unknown' }

# The boundary's output lives in the runtime root, never in the repository, so
# the working-tree invariant stays meaningful.
$handoffOutPath = Join-Path $RuntimeRoot 'delegent-handoff.json'
$handoffLogPath = $handoffOutPath + '.log.jsonl'
foreach ($stale in @($handoffOutPath, $handoffLogPath, ($handoffOutPath + '.tmp'))) {
    if (Test-Path -LiteralPath $stale) { Remove-Item -LiteralPath $stale -Force }
}

& (Join-Path $PSScriptRoot 'setup-codex-nim.ps1') -RuntimeRoot $RuntimeRoot `
    -HandoffToolPath $serverPath -HandoffSchemaPath $schemaPath -HandoffOutPath $handoffOutPath | Out-Null

$codexHome = Join-Path $RuntimeRoot 'codex-home'
$configPath = Join-Path $codexHome 'config.toml'
if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) { throw 'Isolated Codex NIM config was not created.' }
$configText = Get-Content -Raw -LiteralPath $configPath
$handoffToolRegistered = $configText -match '(?m)^\[mcp_servers\.delegent\]'
if (-not (Test-Path -LiteralPath $schemaPath -PathType Leaf)) { throw 'Delegent handoff schema is missing.' }
if (-not (Test-Path -LiteralPath $serverPath -PathType Leaf)) { throw 'Delegent handoff MCP server is missing.' }
if (-not (Test-Path -LiteralPath (Join-Path $repoRoot 'README.md') -PathType Leaf)) { throw 'README.md is missing.' }

$schema = Get-Content -Raw -LiteralPath $schemaPath | ConvertFrom-Json
$beforeTree = Get-WorkingTreeState

$oldCodexHome = $env:CODEX_HOME
$oldNimApiKey = $env:NIM_API_KEY
$process = $null
$timedOut = $false
$stdout = ''
$stderr = ''
$exitCode = $null

try {
    $env:CODEX_HOME = $codexHome
    $env:NIM_API_KEY = $key

    $codexArgs = 'exec --json --sandbox read-only -'
    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = $launchSpec.FileName
    $startInfo.Arguments = $launchSpec.ArgumentsPrefix + $codexArgs + $launchSpec.ArgumentsSuffix
    $startInfo.WorkingDirectory = $repoRoot
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true

    $process = New-Object Diagnostics.Process
    $process.StartInfo = $startInfo
    if (-not $process.Start()) { throw 'Codex process did not start.' }

    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $task = 'Read only README.md from the current repository. Use exec_command exactly once. For that call, set cmd to "Get-Content -LiteralPath README.md -TotalCount 3" and set sandbox_permissions to "use_default". Omit justification, prefix_rule, additional_permissions, workdir, shell, tty, login, yield-time, and max-output fields. Do not request escalation. Do not modify any file. Then submit your handoff for this task by calling the Delegent handoff tool that is available to you, exactly once, using whatever name that tool is registered under. One piece of your evidence must be the first non-empty line after the top-level heading, copied verbatim from the command output. You inspected the file and modified nothing, so report no modified files and no tests.'
    $process.StandardInput.WriteLine($task)
    $process.StandardInput.Close()

    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        $timedOut = $true
        try { & taskkill.exe /PID $process.Id /T /F 1>$null 2>$null } catch {}
        try { $process.WaitForExit(5000) | Out-Null } catch {}
    }

    if ($process.HasExited) { $exitCode = $process.ExitCode }
    try { $stdout = [string]$stdoutTask.Result } catch { $stdout = '' }
    try { $stderr = [string]$stderrTask.Result } catch { $stderr = '' }
}
finally {
    if ($null -eq $oldCodexHome) { Remove-Item Env:CODEX_HOME -ErrorAction SilentlyContinue }
    else { $env:CODEX_HOME = $oldCodexHome }
    if ($null -eq $oldNimApiKey) { Remove-Item Env:NIM_API_KEY -ErrorAction SilentlyContinue }
    else { $env:NIM_API_KEY = $oldNimApiKey }
    if ($null -ne $process) { $process.Dispose() }
}

$afterTree = Get-WorkingTreeState
$workingTreeUnchanged = $beforeTree -ceq $afterTree

$lines = @($stdout -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
$events = @()
$decodeErrors = 0
foreach ($line in $lines) {
    try { $events += ($line | ConvertFrom-Json -ErrorAction Stop) }
    catch { $decodeErrors++ }
}

$threadEvents = @($events | Where-Object { $_.type -eq 'thread.started' })
$threadIdPresent = $threadEvents.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$threadEvents[0].thread_id)
$turnCompleted = @($events | Where-Object { $_.type -eq 'turn.completed' }).Count -gt 0

$benignStreamErrorPattern = '(?i)model metadata for .+ not found'
$retryStreamErrorPattern = '(?i)^\s*reconnecting\b'
$streamErrorMessages = @(Get-StreamErrorMessages -Events $events)
$modelMetadataFallbackSeen = @($streamErrorMessages | Where-Object { $_ -match $benignStreamErrorPattern }).Count -gt 0
$unexpectedStreamErrors = @($streamErrorMessages | Where-Object { $_ -notmatch $benignStreamErrorPattern })
$providerRetryNotices = @($unexpectedStreamErrors | Where-Object { $_ -match $retryStreamErrorPattern })
$fatalStreamErrors = @($unexpectedStreamErrors | Where-Object { $_ -notmatch $retryStreamErrorPattern })
$turnFailed = (@($events | Where-Object { $_.type -eq 'turn.failed' }).Count -gt 0) -or ($fatalStreamErrors.Count -gt 0)

$completedCommands = @($events | Where-Object { $_.type -eq 'item.completed' -and $_.item.type -eq 'command_execution' })
$readmeCommands = @($completedCommands | Where-Object { ([string]$_.item.command) -match '(?i)README\.md' })
$readmeToolCommandSucceeded = @($readmeCommands | Where-Object { $_.item.status -eq 'completed' -and [int]$_.item.exit_code -eq 0 }).Count -gt 0
$fileChangeItems = @($events | Where-Object { $_.type -eq 'item.completed' -and $_.item.type -eq 'file_change' })
$mcpToolCalls = @($events | Where-Object { $_.type -eq 'item.completed' -and $_.item.type -eq 'mcp_tool_call' })
# Codex namespaces an MCP tool with its server name, so match on the item rather
# than on a hard-coded wire name.
$handoffToolCalls = @($mcpToolCalls | Where-Object { ($_.item | ConvertTo-Json -Depth 6 -Compress) -match '(?i)handoff' })

# Boundary log: counts and outcomes only, no submitted content.
$boundaryLog = @()
if (Test-Path -LiteralPath $handoffLogPath -PathType Leaf) {
    foreach ($line in @(Get-Content -LiteralPath $handoffLogPath | Where-Object { $_.Trim() })) {
        try { $boundaryLog += ($line | ConvertFrom-Json -ErrorAction Stop) } catch {}
    }
}
$boundaryAccepted = @($boundaryLog | Where-Object { $_.accepted -eq $true }).Count
$boundaryRejected = @($boundaryLog | Where-Object { $_.accepted -eq $false }).Count

$handoffPresent = Test-Path -LiteralPath $handoffOutPath -PathType Leaf
$handoff = $null
$handoffParsed = $false
if ($handoffPresent) {
    try {
        $handoff = Get-Content -Raw -LiteralPath $handoffOutPath | ConvertFrom-Json -ErrorAction Stop
        $handoffParsed = $null -ne $handoff
    }
    catch { $handoffParsed = $false }
}

$schemaViolations = @('handoff was not produced')
if ($handoffParsed) { $schemaViolations = @(Test-JsonAgainstSchema -Value $handoff -Schema $schema) }
$schemaExact = $handoffParsed -and ($schemaViolations.Count -eq 0)

$statusCompleted = $false
$evidenceHasReadmeLine = $false
$changesEmpty = $false
if ($schemaExact) {
    $statusCompleted = ([string]$handoff.status) -ceq 'completed'
    $evidenceHasReadmeLine = @(@($handoff.evidence) | Where-Object { ([string]$_).Contains($expectedEvidenceLine) }).Count -gt 0
    $changesEmpty = @($handoff.changes).Count -eq 0
}

$filteredStringCount = 0
$handoffCredentialLeak = $false
if ($schemaExact) {
    $filtered = Get-FilteredHandoff -Handoff $handoff -Schema $schema -Credential $key -FilteredStringCount ([ref]$filteredStringCount)
    $filteredJson = $filtered | ConvertTo-Json -Depth 20 -Compress
    if (-not [string]::IsNullOrEmpty($key)) { $handoffCredentialLeak = $filteredJson.Contains($key) }
}

$credentialLeakDetected = $false
if (-not [string]::IsNullOrEmpty($key)) { $credentialLeakDetected = $stdout.Contains($key) -or $stderr.Contains($key) }

$stderrSummary = Get-SafeStderrSummary -CapturedStderr $stderr -Credential $key
$fatalStreamErrorSummary = Get-SafeStderrSummary -CapturedStderr ($fatalStreamErrors -join ' | ') -Credential $key
$providerRetrySummary = Get-SafeStderrSummary -CapturedStderr ($providerRetryNotices -join ' | ') -Credential $key
# Violation paths are schema field names, never model content.
$schemaViolationSummary = if ($schemaViolations.Count -eq 0) { 'none' } else { ($schemaViolations -join '; ') }
if ($schemaViolationSummary.Length -gt 600) { $schemaViolationSummary = $schemaViolationSummary.Substring(0, 600) + '...' }

$eventTypes = @($events | ForEach-Object { [string]$_.type } | Select-Object -Unique)
$eventTypesText = if ($eventTypes.Count -eq 0) { 'none' } else { $eventTypes -join ',' }
$exitCodeText = if ($null -eq $exitCode) { 'none' } else { [string]$exitCode }

$overallPass = (
    -not $timedOut -and
    $exitCode -eq 0 -and
    $decodeErrors -eq 0 -and
    $threadIdPresent -and
    $turnCompleted -and
    -not $turnFailed -and
    $handoffToolRegistered -and
    $readmeToolCommandSucceeded -and
    $handoffToolCalls.Count -ge 1 -and
    $boundaryAccepted -eq 1 -and
    $fileChangeItems.Count -eq 0 -and
    $workingTreeUnchanged -and
    $handoffPresent -and
    $handoffParsed -and
    $schemaExact -and
    $statusCompleted -and
    $evidenceHasReadmeLine -and
    $changesEmpty -and
    $filteredStringCount -gt 0 -and
    -not $handoffCredentialLeak -and
    -not $credentialLeakDetected
)

Write-Output 'CODEX_NIM_HANDOFF_SCHEMA'
Write-Output "codex_version=$([string]$codexVersion)"
Write-Output "codex_launcher=$($launchSpec.Kind)"
Write-Output "codex_home=$codexHome"
Write-Output 'config_mode=isolated-default-plus-handoff-tool'
Write-Output 'harness_mode=mcp-tool-call-handoff'
Write-Output 'boundary=mcp-tool-call-arguments-validated-at-boundary'
Write-Output 'boundary_reason=provider-does-not-enforce-responses-structured-output'
Write-Output 'schema_source=skills/delegating-work/schemas/delegent-handoff.schema.json'
Write-Output 'prompt_declares_fields=False'
Write-Output "handoff_tool_registered=$([bool]$handoffToolRegistered)"
Write-Output 'model=nvidia/nemotron-3-super-120b-a12b'
Write-Output 'model_provider=nim'
Write-Output 'sandbox=read-only'
Write-Output 'json_mode=True'
Write-Output 'credential_present=True'
Write-Output "credential_source=$credentialSource"
Write-Output 'process_started=True'
Write-Output "timed_out=$([bool]$timedOut)"
Write-Output "process_exit_code=$exitCodeText"
Write-Output "stderr_summary=$stderrSummary"
Write-Output "jsonl_line_count=$($lines.Count)"
Write-Output "jsonl_decode_errors=$decodeErrors"
Write-Output "event_types=$eventTypesText"
Write-Output "thread_id_present=$([bool]$threadIdPresent)"
Write-Output "turn_completed=$([bool]$turnCompleted)"
Write-Output "turn_failed=$([bool]$turnFailed)"
Write-Output "stream_error_count=$($streamErrorMessages.Count)"
Write-Output "model_metadata_fallback_seen=$([bool]$modelMetadataFallbackSeen)"
Write-Output "provider_retry_notice_count=$($providerRetryNotices.Count)"
Write-Output "provider_retry_summary=$providerRetrySummary"
Write-Output "fatal_stream_error_count=$($fatalStreamErrors.Count)"
Write-Output "fatal_stream_error_summary=$fatalStreamErrorSummary"
Write-Output "command_execution_count=$($completedCommands.Count)"
Write-Output "readme_tool_command_succeeded=$([bool]$readmeToolCommandSucceeded)"
Write-Output "mcp_tool_call_count=$($mcpToolCalls.Count)"
Write-Output "handoff_tool_call_count=$($handoffToolCalls.Count)"
Write-Output "boundary_accepted_count=$boundaryAccepted"
Write-Output "boundary_rejected_count=$boundaryRejected"
Write-Output "file_change_item_count=$($fileChangeItems.Count)"
Write-Output "working_tree_unchanged=$([bool]$workingTreeUnchanged)"
Write-Output "handoff_present=$([bool]$handoffPresent)"
Write-Output "handoff_parsed_as_json=$([bool]$handoffParsed)"
Write-Output "schema_violation_count=$($schemaViolations.Count)"
Write-Output "schema_violation_summary=$schemaViolationSummary"
Write-Output "schema_exact=$([bool]$schemaExact)"
Write-Output "status_completed=$([bool]$statusCompleted)"
Write-Output "evidence_has_readme_line=$([bool]$evidenceHasReadmeLine)"
Write-Output "changes_empty=$([bool]$changesEmpty)"
Write-Output "sensitive_filter_applied_to_strings=$filteredStringCount"
Write-Output "handoff_credential_leak_detected=$([bool]$handoffCredentialLeak)"
Write-Output "stderr_present=$([bool](-not [string]::IsNullOrWhiteSpace($stderr)))"
Write-Output "credential_leak_detected=$([bool]$credentialLeakDetected)"
Write-Output "overall=$(if ($overallPass) { 'PASS' } else { 'FAIL' })"
Write-Output 'credential_value_logged=False'

if ($overallPass) { exit 0 }
exit 1
