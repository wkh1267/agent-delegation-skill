[CmdletBinding()]
param(
    [ValidateRange(15, 600)]
    [int]$TimeoutSeconds = 300
)

# D2 — Worker continuity.
#
# Continuity is only real if a reused Worker can answer from what it already
# learned. Proving that needs a differential, not one observation: the same
# follow-up question is put to a reused Worker and to a fresh one, and the
# answer must come from memory in the first case and not in the second.
#
#   arm 1  seed    session A, do the exploration
#   arm 2  reuse   session A, follow-up with tools forbidden  -> answers
#   arm 3  fresh   new session, same follow-up                -> cannot answer
#
# Without arm 3, arm 2 proves nothing: a Worker that simply re-read the
# repository would look identical from the outside. So the follow-up forbids
# tool use, and the gate counts non-handoff tool calls to check it.
#
# The expected answer is a long, specific ADR title, so a fresh Worker producing
# it by guesswork is not a plausible confound.

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$credentialSource = 'none'
$schemaPath = Join-Path $repoRoot 'skills\delegating-work\schemas\delegent-handoff.schema.json'
$workerPath = Join-Path $repoRoot 'skills\delegating-work\tools\delegent-nim-worker.js'

# Derived, not hardcoded: the gate should track the record rather than go stale
# if its title is ever edited.
$titleAdr = 'docs\decisions\0001-codex-nim-worker-runtime.md'
$seedAffinity = 'delegent:agent-delegation-skills:docs-decisions:explorer'
$freshAffinity = 'delegent:agent-delegation-skills:docs-decisions:reviewer-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)

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
    Write-Output 'NIM_WORKER_CONTINUITY'
    Write-Output 'credential_present=False'
    Write-Output 'overall=FAIL'
    Write-Output 'credential_value_logged=False'
    exit 1
}
$key = $key.Trim('"').Trim("'")

$node = Get-Command node -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $node) {
    Write-Output 'NIM_WORKER_CONTINUITY'
    Write-Output 'node_found=False'
    Write-Output 'overall=FAIL'
    Write-Output 'credential_value_logged=False'
    exit 1
}

$schema = Get-Content -Raw -LiteralPath $schemaPath | ConvertFrom-Json

$titleAdrPath = Join-Path $repoRoot $titleAdr
if (-not (Test-Path -LiteralPath $titleAdrPath -PathType Leaf)) { throw "The gate's reference record $titleAdr is missing." }
$expectedTitle = ([string](Get-Content -LiteralPath $titleAdrPath -TotalCount 1)).Trim()
if ([string]::IsNullOrWhiteSpace($expectedTitle)) { throw "Could not read the first line of $titleAdr." }

$runtimeRoot = if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'agent-delegation-skills\nim-worker' }
               else { Join-Path ([IO.Path]::GetTempPath()) 'agent-delegation-skills\nim-worker' }
$sessionDir = Join-Path $runtimeRoot 'sessions'
New-Item -ItemType Directory -Force -Path $sessionDir | Out-Null

# Start from no prior state so the gate is repeatable rather than accumulating
# turns from earlier runs.
Get-ChildItem -LiteralPath $sessionDir -File -ErrorAction SilentlyContinue | Remove-Item -Force

function Invoke-Worker {
    param(
        [string]$Label,
        [string]$Affinity,
        [string]$Task
    )

    $handoffPath = Join-Path $runtimeRoot ('continuity-' + $Label + '.json')
    foreach ($stale in @($handoffPath, ($handoffPath + '.tmp'))) {
        if (Test-Path -LiteralPath $stale) { Remove-Item -LiteralPath $stale -Force }
    }

    $oldKey = $env:NIM_API_KEY
    $process = $null
    $stdout = ''
    $stderr = ''
    $exitCode = $null
    $timedOut = $false

    try {
        $env:NIM_API_KEY = $key
        $arguments = '"' + $workerPath + '"' +
            ' --schema "' + $schemaPath + '"' +
            ' --out "' + $handoffPath + '"' +
            ' --repo "' + $repoRoot + '"' +
            ' --session "' + $Affinity + '"' +
            ' --session-dir "' + $sessionDir + '"'

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
        $process.StandardInput.WriteLine($Task)
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
        if ($null -eq $oldKey) { Remove-Item Env:NIM_API_KEY -ErrorAction SilentlyContinue }
        else { $env:NIM_API_KEY = $oldKey }
        if ($null -ne $process) { $process.Dispose() }
    }

    $events = @()
    $decodeErrors = 0
    foreach ($line in @($stdout -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
        try { $events += ($line | ConvertFrom-Json -ErrorAction Stop) }
        catch { $decodeErrors++ }
    }

    $sessionLoaded = @($events | Where-Object { $_.type -eq 'session.loaded' })
    $sessionSaved = @($events | Where-Object { $_.type -eq 'session.saved' })
    # The runtime emits tool_call items only for non-handoff tools, so this count
    # is exactly "did it look something up".
    $toolCalls = @($events | Where-Object { $_.type -eq 'item.completed' -and $_.item.type -eq 'tool_call' })
    $handoffAccepted = @($events | Where-Object { $_.type -eq 'item.completed' -and $_.item.type -eq 'handoff' -and $_.item.accepted })

    $handoff = $null
    $handoffParsed = $false
    if (Test-Path -LiteralPath $handoffPath -PathType Leaf) {
        try {
            $handoff = Get-Content -Raw -LiteralPath $handoffPath | ConvertFrom-Json -ErrorAction Stop
            $handoffParsed = $null -ne $handoff
        }
        catch { $handoffParsed = $false }
    }

    $violations = @('handoff was not produced')
    if ($handoffParsed) { $violations = @(Test-JsonAgainstSchema -Value $handoff -Schema $schema) }
    $reported = if ($handoffParsed) { ($handoff | ConvertTo-Json -Depth 20 -Compress) } else { '' }

    $leak = $false
    if (-not [string]::IsNullOrEmpty($key)) { $leak = $stdout.Contains($key) -or $stderr.Contains($key) -or $reported.Contains($key) }

    return [pscustomobject]@{
        Label = $Label
        TimedOut = $timedOut
        ExitCode = $exitCode
        DecodeErrors = $decodeErrors
        SessionReused = ($sessionLoaded.Count -gt 0) -and [bool]$sessionLoaded[0].reused
        PriorTurns = if ($sessionLoaded.Count -gt 0) { [int]$sessionLoaded[0].prior_turns } else { -1 }
        SessionSavedTurns = if ($sessionSaved.Count -gt 0) { [int]$sessionSaved[0].turns } else { -1 }
        LookupToolCalls = $toolCalls.Count
        HandoffAccepted = $handoffAccepted.Count
        SchemaExact = $handoffParsed -and ($violations.Count -eq 0)
        ViolationCount = $violations.Count
        TitlePresent = $reported.Contains($expectedTitle)
        CredentialLeak = $leak
    }
}

$beforeTree = Get-WorkingTreeState

$seedTask = 'List the files under docs/decisions, then read the file 0001-codex-nim-worker-runtime.md and report its exact first line as evidence. You are only inspecting, so report no modified files and no tests.'
$followUpTask = 'Do not call any tool for this task. Using only what you already know from our earlier exchange in this same session, report the exact first line of 0001-codex-nim-worker-runtime.md as evidence, copied verbatim. If you genuinely do not already know it, set status to blocked and say so instead of looking it up.'

$seed = Invoke-Worker -Label 'seed' -Affinity $seedAffinity -Task $seedTask
$reuse = Invoke-Worker -Label 'reuse' -Affinity $seedAffinity -Task $followUpTask
$fresh = Invoke-Worker -Label 'fresh' -Affinity $freshAffinity -Task $followUpTask

$afterTree = Get-WorkingTreeState
$workingTreeUnchanged = $beforeTree -ceq $afterTree

# The property under test: answered the follow-up from memory, without looking.
$reuseAnsweredFromMemory = $reuse.TitlePresent -and ($reuse.LookupToolCalls -eq 0)
$freshAnsweredFromMemory = $fresh.TitlePresent -and ($fresh.LookupToolCalls -eq 0)
$continuityDifferential = if ($reuseAnsweredFromMemory -and -not $freshAnsweredFromMemory) { 'CONTINUITY_PROVEN' }
                          elseif ($reuseAnsweredFromMemory -and $freshAnsweredFromMemory) { 'CONTROL_ALSO_ANSWERED' }
                          elseif (-not $reuseAnsweredFromMemory) { 'REUSE_DID_NOT_CARRY_CONTEXT' }
                          else { 'INCONCLUSIVE' }

$sessionFiles = @(Get-ChildItem -LiteralPath $sessionDir -File -ErrorAction SilentlyContinue)
$anyLeak = $seed.CredentialLeak -or $reuse.CredentialLeak -or $fresh.CredentialLeak

$overallPass = (
    -not $seed.TimedOut -and -not $reuse.TimedOut -and -not $fresh.TimedOut -and
    $seed.ExitCode -eq 0 -and $reuse.ExitCode -eq 0 -and
    $seed.DecodeErrors -eq 0 -and $reuse.DecodeErrors -eq 0 -and $fresh.DecodeErrors -eq 0 -and
    -not $seed.SessionReused -and
    $seed.SessionSavedTurns -eq 1 -and
    $reuse.SessionReused -and
    $reuse.PriorTurns -eq 1 -and
    $reuse.SessionSavedTurns -eq 2 -and
    -not $fresh.SessionReused -and
    $seed.HandoffAccepted -eq 1 -and $seed.SchemaExact -and $seed.TitlePresent -and
    $reuse.HandoffAccepted -eq 1 -and $reuse.SchemaExact -and
    $continuityDifferential -eq 'CONTINUITY_PROVEN' -and
    $sessionFiles.Count -eq 2 -and
    $workingTreeUnchanged -and
    -not $anyLeak
)

Write-Output 'NIM_WORKER_CONTINUITY'
Write-Output "node_version=$(& $node.Source --version)"
Write-Output 'runtime=direct-nim-responses-loop'
Write-Output 'harness_mode=continuity-differential'
Write-Output 'affinity_scheme=delegent:<project>:<scope>:<role>'
Write-Output 'session_state=local-transcript'
Write-Output 'mutation_capable=False'
Write-Output 'credential_present=True'
Write-Output "credential_source=$credentialSource"
foreach ($arm in @($seed, $reuse, $fresh)) {
    $p = $arm.Label
    Write-Output "$($p)_timed_out=$([bool]$arm.TimedOut)"
    Write-Output "$($p)_exit_code=$(if ($null -eq $arm.ExitCode) { 'none' } else { $arm.ExitCode })"
    Write-Output "$($p)_session_reused=$([bool]$arm.SessionReused)"
    Write-Output "$($p)_prior_turns=$($arm.PriorTurns)"
    Write-Output "$($p)_session_saved_turns=$($arm.SessionSavedTurns)"
    Write-Output "$($p)_lookup_tool_calls=$($arm.LookupToolCalls)"
    Write-Output "$($p)_handoff_accepted=$($arm.HandoffAccepted)"
    Write-Output "$($p)_schema_exact=$([bool]$arm.SchemaExact)"
    Write-Output "$($p)_title_present=$([bool]$arm.TitlePresent)"
}
Write-Output "reuse_answered_from_memory=$([bool]$reuseAnsweredFromMemory)"
Write-Output "fresh_answered_from_memory=$([bool]$freshAnsweredFromMemory)"
Write-Output "continuity_differential=$continuityDifferential"
Write-Output "session_file_count=$($sessionFiles.Count)"
Write-Output "working_tree_unchanged=$([bool]$workingTreeUnchanged)"
Write-Output "credential_leak_detected=$([bool]$anyLeak)"
Write-Output "overall=$(if ($overallPass) { 'PASS' } else { 'FAIL' })"
Write-Output 'credential_value_logged=False'

if ($overallPass) { exit 0 }
exit 1
