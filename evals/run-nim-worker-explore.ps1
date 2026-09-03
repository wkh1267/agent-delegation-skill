[CmdletBinding()]
param(
    [ValidateRange(15, 600)]
    [int]$TimeoutSeconds = 300
)

# D1b — the widened read-only tool surface.
#
# D1 proved the handoff boundary with a single file read. This gate proves the
# Worker can actually do the exploration work that is most worth delegating:
# list a directory, locate text by search, and read what it found -- then report
# through the same validated boundary.
#
# Every assertion below is grounded in a checked repository fact rather than a
# guess: `docs/decisions` holds exactly two records, and within that directory
# the string `unelevated` occurs in 0001 only. Scoping the search that way keeps
# the expectation stable as the rest of the repository grows.
#
# The task prompt never names the handoff fields, so schema conformance cannot
# be explained by prompt-following.
#
# Note: this gate re-implements the schema validator that D1 also carries. That
# duplication is the existing convention for probes in this repo (each is
# self-contained and independently runnable), and consolidating it belongs to D5
# where the production adapter defines the shared surface.

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$credentialSource = 'none'
$schemaPath = Join-Path $repoRoot 'skills\delegating-work\schemas\delegent-handoff.schema.json'
$workerPath = Join-Path $repoRoot 'skills\delegating-work\tools\delegent-nim-worker.js'

$expectedAdrs = @('0001-codex-nim-worker-runtime.md', '0002-direct-nim-worker-runtime.md')
$expectedTitleFragment = 'ADR-0001'

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

function Get-SafeSummary {
    param(
        [string]$Text,
        [string]$Credential
    )

    if ([string]::IsNullOrWhiteSpace($Text)) { return 'none' }
    $safe = [string]$Text
    if (-not [string]::IsNullOrEmpty($Credential)) { $safe = $safe.Replace($Credential, '<redacted>') }
    $safe = [regex]::Replace($safe, '(?i)nvapi-[A-Za-z0-9_-]+', '<redacted>')
    $safe = [regex]::Replace($safe, '(?i)\bBearer\s+\S+', 'Bearer <redacted>')
    $safe = [regex]::Replace($safe, 'https?://\S+', '<url>')
    $safe = [regex]::Replace($safe, '(?i)\b[A-Z]:\\(?:[^\\\s:"<>|]+\\)*[^\\\s:"<>|]*', '<path>')
    $safe = [regex]::Replace($safe, '\b[A-Za-z0-9_-]{48,}\b', '<token>')
    $safe = [regex]::Replace($safe, '[\r\n\t]+', ' ')
    $safe = [regex]::Replace($safe, '\s{2,}', ' ').Trim()
    if ($safe.Length -gt 600) { $safe = $safe.Substring(0, 600) + '...' }
    if ([string]::IsNullOrWhiteSpace($safe)) { return 'redacted' }
    return $safe
}

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
        # @($null).Count is 1 in PowerShell, so drop nulls before deciding an
        # enum exists, or every free-text field looks enum-constrained.
        $allowed = @(@($Schema.enum) | Where-Object { $null -ne $_ })
        if ($allowed.Count -gt 0 -and $allowed -notcontains [string]$Value) {
            return @("$Path is outside its allowed values")
        }
        return @()
    }

    return @("$Path has an unsupported schema type")
}

function Get-WorkingTreeState {
    $lines = @(& git -C $repoRoot status --porcelain=v1 --untracked-files=all 2>$null)
    return ($lines -join "`n")
}

$key = Get-NimCredential
if ([string]::IsNullOrWhiteSpace($key)) {
    Write-Output 'NIM_WORKER_EXPLORE'
    Write-Output 'credential_present=False'
    Write-Output 'process_started=False'
    Write-Output 'overall=FAIL'
    Write-Output 'credential_value_logged=False'
    exit 1
}
$key = $key.Trim('"').Trim("'")

$node = Get-Command node -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $node) {
    Write-Output 'NIM_WORKER_EXPLORE'
    Write-Output 'node_found=False'
    Write-Output 'overall=FAIL'
    Write-Output 'credential_value_logged=False'
    exit 1
}

if (-not (Test-Path -LiteralPath $schemaPath -PathType Leaf)) { throw 'Delegent handoff schema is missing.' }
if (-not (Test-Path -LiteralPath $workerPath -PathType Leaf)) { throw 'Delegent NIM Worker runtime is missing.' }

# The gate's expectations are only meaningful if the repository still looks the
# way they assume, so verify that up front instead of failing mysteriously.
$decisionsDir = Join-Path $repoRoot 'docs\decisions'
$actualAdrs = @(Get-ChildItem -LiteralPath $decisionsDir -File -Filter '*.md' | ForEach-Object { $_.Name })
if ($actualAdrs.Count -ne $expectedAdrs.Count) {
    throw "This gate assumes $($expectedAdrs.Count) decision records but found $($actualAdrs.Count). Update the expectations."
}
foreach ($name in $expectedAdrs) {
    if ($actualAdrs -notcontains $name) { throw "Expected decision record $name is missing. Update the expectations." }
}

$schema = Get-Content -Raw -LiteralPath $schemaPath | ConvertFrom-Json

$runtimeRoot = if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'agent-delegation-skills\nim-worker' }
               else { Join-Path ([IO.Path]::GetTempPath()) 'agent-delegation-skills\nim-worker' }
New-Item -ItemType Directory -Force -Path $runtimeRoot | Out-Null
$handoffPath = Join-Path $runtimeRoot 'delegent-explore-handoff.json'
foreach ($stale in @($handoffPath, ($handoffPath + '.tmp'))) {
    if (Test-Path -LiteralPath $stale) { Remove-Item -LiteralPath $stale -Force }
}

$beforeTree = Get-WorkingTreeState
$oldNimApiKey = $env:NIM_API_KEY
$process = $null
$timedOut = $false
$stdout = ''
$stderr = ''
$exitCode = $null

try {
    $env:NIM_API_KEY = $key

    $arguments = '"' + $workerPath + '"' +
        ' --schema "' + $schemaPath + '"' +
        ' --out "' + $handoffPath + '"' +
        ' --repo "' + $repoRoot + '"'

    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = $node.Source
    $startInfo.Arguments = $arguments
    $startInfo.WorkingDirectory = $repoRoot
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true

    $process = New-Object Diagnostics.Process
    $process.StartInfo = $startInfo
    if (-not $process.Start()) { throw 'Worker runtime did not start.' }

    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $task = 'Under docs/decisions, find out how many architecture decision records exist and what each one is called. Then find which single record mentions the Windows sandbox setting unelevated, and read that record to get its first line. Report every decision-record filename you found as separate evidence, and also include that first line verbatim as evidence. You are only inspecting the repository, so report no modified files and no tests.'
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
$turnFailed = @($events | Where-Object { $_.type -eq 'turn.failed' -or $_.type -eq 'error' }).Count -gt 0
$providerRetries = @($events | Where-Object { $_.type -eq 'provider.retry' }).Count
$proseRejected = @($events | Where-Object { $_.type -eq 'item.completed' -and $_.item.type -eq 'prose_answer_rejected' }).Count

$toolCalls = @($events | Where-Object { $_.type -eq 'item.completed' -and $_.item.type -eq 'tool_call' })
function Test-ToolUsed {
    param([string]$Name)
    return @($toolCalls | Where-Object { ([string]$_.item.name) -ceq $Name -and $_.item.ok }).Count -ge 1
}
$listFilesUsed = Test-ToolUsed -Name 'list_files'
$searchUsed = Test-ToolUsed -Name 'search'
$readFileUsed = Test-ToolUsed -Name 'read_file'

$handoffEvents = @($events | Where-Object { $_.type -eq 'item.completed' -and $_.item.type -eq 'handoff' })
$handoffAcceptedEvents = @($handoffEvents | Where-Object { $_.item.accepted })
$handoffRejectedEvents = @($handoffEvents | Where-Object { -not $_.item.accepted })
$filteredStringCount = 0
if ($handoffAcceptedEvents.Count -gt 0) { $filteredStringCount = [int]$handoffAcceptedEvents[0].item.filtered_string_count }

$handoffPresent = Test-Path -LiteralPath $handoffPath -PathType Leaf
$handoff = $null
$handoffParsed = $false
if ($handoffPresent) {
    try {
        $handoff = Get-Content -Raw -LiteralPath $handoffPath | ConvertFrom-Json -ErrorAction Stop
        $handoffParsed = $null -ne $handoff
    }
    catch { $handoffParsed = $false }
}

$schemaViolations = @('handoff was not produced')
if ($handoffParsed) { $schemaViolations = @(Test-JsonAgainstSchema -Value $handoff -Schema $schema) }
$schemaExact = $handoffParsed -and ($schemaViolations.Count -eq 0)

$statusCompleted = $false
$changesEmpty = $false
$adrsFound = 0
$titleQuoted = $false
if ($schemaExact) {
    $statusCompleted = ([string]$handoff.status) -ceq 'completed'
    $changesEmpty = @($handoff.changes).Count -eq 0
    # Look across the whole reported handoff: a Worker may legitimately put a
    # filename in evidence, summary or review targets.
    $reported = ($handoff | ConvertTo-Json -Depth 20 -Compress)
    foreach ($name in $expectedAdrs) {
        if ($reported.Contains($name)) { $adrsFound++ }
    }
    $titleQuoted = $reported.Contains($expectedTitleFragment)
}

$credentialLeakDetected = $false
if (-not [string]::IsNullOrEmpty($key)) {
    $credentialLeakDetected = $stdout.Contains($key) -or $stderr.Contains($key)
    if (-not $credentialLeakDetected -and $handoffPresent) {
        $credentialLeakDetected = (Get-Content -Raw -LiteralPath $handoffPath).Contains($key)
    }
}

$stderrSummary = Get-SafeSummary -Text $stderr -Credential $key
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
    $listFilesUsed -and
    $searchUsed -and
    $readFileUsed -and
    $handoffAcceptedEvents.Count -eq 1 -and
    $handoffPresent -and
    $handoffParsed -and
    $schemaExact -and
    $statusCompleted -and
    $changesEmpty -and
    $adrsFound -eq $expectedAdrs.Count -and
    $titleQuoted -and
    $filteredStringCount -gt 0 -and
    $workingTreeUnchanged -and
    -not $credentialLeakDetected
)

Write-Output 'NIM_WORKER_EXPLORE'
Write-Output "node_version=$(& $node.Source --version)"
Write-Output 'runtime=direct-nim-responses-loop'
Write-Output 'harness_mode=read-only-exploration'
Write-Output 'boundary=function-call-arguments-validated-at-boundary'
Write-Output 'tool_surface=list_files,search,read_file,delegent_handoff'
Write-Output 'mutation_capable=False'
Write-Output 'shell_tool_present=False'
Write-Output 'prompt_declares_fields=False'
Write-Output 'model=nvidia/nemotron-3-super-120b-a12b'
Write-Output 'model_provider=nim'
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
Write-Output "provider_retry_count=$providerRetries"
Write-Output "prose_answer_rejected_count=$proseRejected"
Write-Output "tool_call_count=$($toolCalls.Count)"
Write-Output "list_files_used=$([bool]$listFilesUsed)"
Write-Output "search_used=$([bool]$searchUsed)"
Write-Output "read_file_used=$([bool]$readFileUsed)"
Write-Output "handoff_attempt_count=$($handoffEvents.Count)"
Write-Output "handoff_rejected_count=$($handoffRejectedEvents.Count)"
Write-Output "handoff_accepted_count=$($handoffAcceptedEvents.Count)"
Write-Output "handoff_present=$([bool]$handoffPresent)"
Write-Output "schema_violation_count=$($schemaViolations.Count)"
Write-Output "schema_violation_summary=$schemaViolationSummary"
Write-Output "schema_exact=$([bool]$schemaExact)"
Write-Output "status_completed=$([bool]$statusCompleted)"
Write-Output "changes_empty=$([bool]$changesEmpty)"
Write-Output "decision_records_reported=$adrsFound/$($expectedAdrs.Count)"
Write-Output "adr_title_quoted=$([bool]$titleQuoted)"
Write-Output "sensitive_filter_applied_to_strings=$filteredStringCount"
Write-Output "working_tree_unchanged=$([bool]$workingTreeUnchanged)"
Write-Output "credential_leak_detected=$([bool]$credentialLeakDetected)"
Write-Output "overall=$(if ($overallPass) { 'PASS' } else { 'FAIL' })"
Write-Output 'credential_value_logged=False'

if ($overallPass) { exit 0 }
exit 1
