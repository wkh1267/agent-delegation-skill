[CmdletBinding()]
param(
    [string]$RuntimeRoot,
    [ValidateRange(15, 300)]
    [int]$TimeoutSeconds = 120
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$credentialSource = 'none'

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
            VersionCommand = $native.Source
            FileName = $native.Source
            ArgumentsPrefix = ''
            ArgumentsSuffix = ''
            Kind = 'native'
        }
    }

    # npm installs both codex.cmd and codex.ps1 on Windows. Prefer the cmd shim
    # for redirected-stdin exec probes: Windows PowerShell 5.1 can reject the
    # trailing '-' sentinel before the npm PowerShell shim reaches Codex.
    $cmdShim = Get-Command codex.cmd -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmdShim) {
        $comspec = if ($env:ComSpec) { $env:ComSpec } else { 'cmd.exe' }
        return [pscustomobject]@{
            VersionCommand = $cmdShim.Source
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
            VersionCommand = $command.Source
            FileName = $comspec
            ArgumentsPrefix = ('/d /s /c ""' + $command.Source + '" ')
            ArgumentsSuffix = '"'
            Kind = 'cmd-shim'
        }
    }
    if ($extension -eq '.ps1') {
        $powershell = Get-Command powershell.exe -CommandType Application -ErrorAction Stop | Select-Object -First 1
        return [pscustomobject]@{
            VersionCommand = $command.Source
            FileName = $powershell.Source
            ArgumentsPrefix = ('-NoProfile -ExecutionPolicy Bypass -File "' + $command.Source + '" ')
            ArgumentsSuffix = ''
            Kind = 'powershell-shim-fallback'
        }
    }

    return [pscustomobject]@{
        VersionCommand = $command.Source
        FileName = $command.Source
        ArgumentsPrefix = ''
        ArgumentsSuffix = ''
        Kind = 'application'
    }
}

function Get-SafeFailureClass {
    param(
        [string]$CapturedStderr,
        [Nullable[int]]$ProcessExitCode
    )

    if ($null -eq $ProcessExitCode -or $ProcessExitCode -eq 0) { return 'none' }
    if ([string]::IsNullOrWhiteSpace($CapturedStderr)) { return 'startup_error_no_stderr' }

    if ($CapturedStderr -match '(?i)(PSArgumentException|FullyQualifiedErrorId\s*:\s*Argument,codex\.ps1|\[codex\.ps1\])') {
        return 'powershell_shim_error'
    }
    if ($CapturedStderr -match '(?i)(unexpected argument|unknown argument|unrecognized option|invalid value.*--|usage:)') {
        return 'cli_argument_error'
    }
    if ($CapturedStderr -match '(?i)(Error loading config\.toml|unknown field|unrecognized field|failed to load.*config|failed to parse.*config|config\.toml)') {
        return 'config_error'
    }
    if ($CapturedStderr -match '(?i)(Error loading rules|exec.?policy|rule file)') {
        return 'exec_policy_error'
    }
    if ($CapturedStderr -match '(?i)(Not inside a trusted directory|skip-git-repo-check)') {
        return 'git_trust_error'
    }
    if ($CapturedStderr -match '(?i)(failed to initialize in-process app-server client)') {
        return 'app_server_init_error'
    }
    if ($CapturedStderr -match '(?i)(environment manager|environment config|exec-server protocol error|local environment requires configured runtime paths|CODEX_EXEC_SERVER_URL)') {
        return 'environment_manager_error'
    }
    if ($CapturedStderr -match '(?i)(401|403|unauthorized|forbidden|authentication|api key|credential|NIM_API_KEY)') {
        return 'auth_error'
    }
    if ($CapturedStderr -match '(?i)(responses|request failed|http status|status code|429|500|502|503|504)') {
        return 'provider_request_error'
    }
    return 'startup_error_other'
}

function Get-SafeStderrSummary {
    param(
        [string]$CapturedStderr,
        [string]$Credential
    )

    if ([string]::IsNullOrWhiteSpace($CapturedStderr)) { return 'none' }

    $safe = [string]$CapturedStderr
    if (-not [string]::IsNullOrEmpty($Credential)) {
        $safe = $safe.Replace($Credential, '<redacted>')
    }

    $safe = [regex]::Replace($safe, '(?i)nvapi-[A-Za-z0-9_-]+', '<redacted>')
    $safe = [regex]::Replace($safe, '(?i)\bBearer\s+\S+', 'Bearer <redacted>')
    $safe = [regex]::Replace($safe, '(?i)\b(?:sk|key|token)-[A-Za-z0-9_-]{12,}', '<redacted>')
    $safe = [regex]::Replace($safe, 'https?://\S+', '<url>')
    $safe = [regex]::Replace($safe, '(?i)\b[A-Z]:\\(?:[^\\\s:"<>|]+\\)*[^\\\s:"<>|]*', '<path>')
    $safe = [regex]::Replace($safe, '(?<![A-Za-z0-9_])/(?:[^/\s]+/)+[^\s:;,]+', '<path>')
    $safe = [regex]::Replace($safe, '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}', '<email>')
    $safe = [regex]::Replace($safe, '\b[A-Fa-f0-9]{32,}\b', '<id>')
    $safe = [regex]::Replace($safe, '\b[A-Za-z0-9_-]{48,}\b', '<token>')
    $safe = [regex]::Replace($safe, '[\r\n\t]+', ' ')
    $safe = [regex]::Replace($safe, '\s{2,}', ' ').Trim()

    if ($safe.Length -gt 400) {
        $safe = $safe.Substring(0, 400) + '...'
    }
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

if ([string]::IsNullOrWhiteSpace($RuntimeRoot)) {
    if ($env:LOCALAPPDATA) {
        $RuntimeRoot = Join-Path $env:LOCALAPPDATA 'agent-delegation-skills\codex-nim'
    }
    else {
        $RuntimeRoot = Join-Path ([IO.Path]::GetTempPath()) 'agent-delegation-skills\codex-nim'
    }
}

$key = Get-NimCredential
if ([string]::IsNullOrWhiteSpace($key)) {
    Write-Output 'CODEX_NIM_SMOKE'
    Write-Output 'credential_present=False'
    Write-Output 'process_started=False'
    Write-Output 'overall=FAIL'
    Write-Output 'credential_value_logged=False'
    exit 1
}
$key = $key.Trim('"').Trim("'")

$launchSpec = Get-CodexLaunchSpec
if ($null -eq $launchSpec) {
    Write-Output 'CODEX_NIM_SMOKE'
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

& (Join-Path $PSScriptRoot 'setup-codex-nim.ps1') -RuntimeRoot $RuntimeRoot | Out-Null
$codexHome = Join-Path $RuntimeRoot 'codex-home'
$configPath = Join-Path $codexHome 'config.toml'
if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
    throw 'Isolated Codex NIM config was not created.'
}

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

    $codexArgs = 'exec --json -'
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
    $process.StandardInput.WriteLine('Reply with exactly WORKER_OK.')
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

$lines = @($stdout -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
$events = @()
$decodeErrors = 0
foreach ($line in $lines) {
    try { $events += ($line | ConvertFrom-Json -ErrorAction Stop) }
    catch { $decodeErrors++ }
}

$threadEvents = @($events | Where-Object { $_.type -eq 'thread.started' })
$turnCompleted = @($events | Where-Object { $_.type -eq 'turn.completed' }).Count -gt 0

# A custom NIM model is absent from Codex's model catalog, so every Worker turn
# opens with a fallback-metadata notice delivered as an error-typed entry. It is
# informational and the turn still runs to completion, so treating any
# error-typed entry as a turn failure makes this gate impossible to pass. Only
# unrecognized error text is fatal, and its sanitized text is always reported.
#
# Codex also emits a `Reconnecting... n/m` notice for each recoverable provider
# stream fault. The hosted NIM endpoint intermittently answers a valid model id
# with 404 Model not found or drops the response stream, and Codex retries. The
# turn outcome is decided by turn.completed plus the exact-answer check, so a
# retry that ultimately succeeded must not fail the gate — otherwise this gate
# goes flaky on provider weather. Retries are counted and summarized instead,
# because their rate is the reliability signal the runtime bake-off needs.
$benignStreamErrorPattern = '(?i)model metadata for .+ not found'
$retryStreamErrorPattern = '(?i)^\s*reconnecting\b'
$streamErrorMessages = @(Get-StreamErrorMessages -Events $events)
$modelMetadataFallbackSeen = @($streamErrorMessages | Where-Object { $_ -match $benignStreamErrorPattern }).Count -gt 0
$unexpectedStreamErrors = @($streamErrorMessages | Where-Object { $_ -notmatch $benignStreamErrorPattern })
$providerRetryNotices = @($unexpectedStreamErrors | Where-Object { $_ -match $retryStreamErrorPattern })
$providerModelNotFoundSeen = @($providerRetryNotices | Where-Object { $_ -match '(?i)\bmodel not found\b' }).Count -gt 0
$fatalStreamErrors = @($unexpectedStreamErrors | Where-Object { $_ -notmatch $retryStreamErrorPattern })
$turnFailed = (@($events | Where-Object { $_.type -eq 'turn.failed' }).Count -gt 0) -or ($fatalStreamErrors.Count -gt 0)
$agentMessages = @($events | Where-Object { $_.type -eq 'item.completed' -and $_.item.type -eq 'agent_message' })
$agentMessagePresent = $agentMessages.Count -gt 0
$agentMessageExact = $false
if ($agentMessagePresent) {
    $agentMessageExact = ([string]$agentMessages[$agentMessages.Count - 1].item.text).Trim() -ceq 'WORKER_OK'
}
$threadIdPresent = $false
if ($threadEvents.Count -gt 0) {
    $threadIdPresent = -not [string]::IsNullOrWhiteSpace([string]$threadEvents[0].thread_id)
}

$credentialLeakDetected = $false
if (-not [string]::IsNullOrEmpty($key)) {
    $credentialLeakDetected = $stdout.Contains($key) -or $stderr.Contains($key)
}
$stderrPresent = -not [string]::IsNullOrWhiteSpace($stderr)
$failureClass = Get-SafeFailureClass -CapturedStderr $stderr -ProcessExitCode $exitCode
$stderrSummary = Get-SafeStderrSummary -CapturedStderr $stderr -Credential $key
$fatalStreamErrorSummary = Get-SafeStderrSummary -CapturedStderr ($fatalStreamErrors -join ' | ') -Credential $key
$providerRetrySummary = Get-SafeStderrSummary -CapturedStderr ($providerRetryNotices -join ' | ') -Credential $key
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
    $agentMessageExact -and
    -not $credentialLeakDetected
)

Write-Output 'CODEX_NIM_SMOKE'
Write-Output "codex_version=$([string]$codexVersion)"
Write-Output "codex_launcher=$($launchSpec.Kind)"
Write-Output "codex_home=$codexHome"
Write-Output 'config_mode=isolated-default'
Write-Output 'harness_mode=minimal'
Write-Output 'model=nvidia/nemotron-3-super-120b-a12b'
Write-Output 'model_provider=nim'
Write-Output 'strict_config=False'
Write-Output 'sandbox=default'
Write-Output 'ephemeral=False'
Write-Output 'ignore_rules=False'
Write-Output 'json_mode=True'
Write-Output 'credential_present=True'
Write-Output "credential_source=$credentialSource"
Write-Output 'process_started=True'
Write-Output "timed_out=$([bool]$timedOut)"
Write-Output "process_exit_code=$exitCodeText"
Write-Output "failure_class=$failureClass"
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
Write-Output "provider_model_not_found_seen=$([bool]$providerModelNotFoundSeen)"
Write-Output "provider_retry_summary=$providerRetrySummary"
Write-Output "fatal_stream_error_count=$($fatalStreamErrors.Count)"
Write-Output "fatal_stream_error_summary=$fatalStreamErrorSummary"
Write-Output "agent_message_present=$([bool]$agentMessagePresent)"
Write-Output "agent_message_exact=$([bool]$agentMessageExact)"
Write-Output "stderr_present=$([bool]$stderrPresent)"
Write-Output "credential_leak_detected=$([bool]$credentialLeakDetected)"
Write-Output "overall=$(if ($overallPass) { 'PASS' } else { 'FAIL' })"
Write-Output 'credential_value_logged=False'

if ($overallPass) { exit 0 }
exit 1
