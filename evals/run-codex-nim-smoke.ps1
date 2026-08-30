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

    $command = Get-Command codex -CommandType Application, ExternalScript -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $command) { return $null }

    $extension = [IO.Path]::GetExtension([string]$command.Source).ToLowerInvariant()
    if ($extension -eq '.ps1') {
        $powershell = Get-Command powershell.exe -CommandType Application -ErrorAction Stop | Select-Object -First 1
        return [pscustomobject]@{
            VersionCommand = $command.Source
            FileName = $powershell.Source
            ArgumentsPrefix = ('-NoProfile -ExecutionPolicy Bypass -File "' + $command.Source + '" ')
            ArgumentsSuffix = ''
            Kind = 'powershell-shim'
        }
    }
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

    if ($CapturedStderr -match '(?i)(profile).*(not found|missing|unknown|does not exist)|failed to load.*profile') {
        return 'profile_config_error'
    }
    if ($CapturedStderr -match '(?i)(unexpected argument|unknown argument|unrecognized option|invalid value.*--|usage:)') {
        return 'cli_argument_error'
    }
    if ($CapturedStderr -match '(?i)(unknown field|unrecognized field|strict.config|failed to load.*config|failed to parse.*config|config\.toml)') {
        return 'config_error'
    }
    if ($CapturedStderr -match '(?i)(401|403|unauthorized|forbidden|authentication|api key|credential)') {
        return 'auth_error'
    }
    if ($CapturedStderr -match '(?i)(responses|request failed|http status|status code|429|500|502|503|504)') {
        return 'provider_request_error'
    }
    return 'startup_error_other'
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

# Recreate the isolated NIM provider + Profile V2 layer before every smoke so
# the probe never depends on the user's normal ~/.codex configuration.
& (Join-Path $PSScriptRoot 'setup-codex-nim.ps1') -RuntimeRoot $RuntimeRoot | Out-Null
$codexHome = Join-Path $RuntimeRoot 'codex-home'
$configPath = Join-Path $codexHome 'config.toml'
$profilePath = Join-Path $codexHome 'nim-worker.config.toml'
if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
    throw 'Isolated Codex NIM base config was not created.'
}
if (-not (Test-Path -LiteralPath $profilePath -PathType Leaf)) {
    throw 'Isolated Codex NIM Profile V2 layer was not created.'
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

    $codexArgs = 'exec --strict-config -p nim-worker --ephemeral --json --sandbox read-only --ignore-rules -'
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
        try {
            & taskkill.exe /PID $process.Id /T /F 1>$null 2>$null
        }
        catch {}
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
    try {
        $events += ($line | ConvertFrom-Json -ErrorAction Stop)
    }
    catch {
        $decodeErrors++
    }
}

$threadEvents = @($events | Where-Object { $_.type -eq 'thread.started' })
$turnCompleted = @($events | Where-Object { $_.type -eq 'turn.completed' }).Count -gt 0
$turnFailed = @($events | Where-Object { $_.type -eq 'turn.failed' -or $_.type -eq 'error' }).Count -gt 0
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
Write-Output 'profile=nim-worker'
Write-Output 'profile_format=v2-layer'
Write-Output "profile_file_exists=$([bool](Test-Path -LiteralPath $profilePath -PathType Leaf))"
Write-Output 'sandbox=read-only'
Write-Output 'ephemeral=True'
Write-Output 'json_mode=True'
Write-Output 'credential_present=True'
Write-Output "credential_source=$credentialSource"
Write-Output 'process_started=True'
Write-Output "timed_out=$([bool]$timedOut)"
Write-Output "process_exit_code=$exitCodeText"
Write-Output "failure_class=$failureClass"
Write-Output "jsonl_line_count=$($lines.Count)"
Write-Output "jsonl_decode_errors=$decodeErrors"
Write-Output "event_types=$eventTypesText"
Write-Output "thread_id_present=$([bool]$threadIdPresent)"
Write-Output "turn_completed=$([bool]$turnCompleted)"
Write-Output "turn_failed=$([bool]$turnFailed)"
Write-Output "agent_message_present=$([bool]$agentMessagePresent)"
Write-Output "agent_message_exact=$([bool]$agentMessageExact)"
Write-Output "stderr_present=$([bool]$stderrPresent)"
Write-Output "credential_leak_detected=$([bool]$credentialLeakDetected)"
Write-Output "overall=$(if ($overallPass) { 'PASS' } else { 'FAIL' })"
Write-Output 'credential_value_logged=False'

if ($overallPass) { exit 0 }
exit 1
