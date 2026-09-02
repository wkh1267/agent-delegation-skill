[CmdletBinding()]
param(
    [string]$RuntimeRoot,
    [ValidateRange(15, 180)]
    [int]$TimeoutSeconds = 60
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

    # `Get-Command codex` resolves codex.ps1 ahead of codex.cmd on this PATH, and
    # the npm PowerShell shim is the known-unsafe launcher for this runtime. Probe
    # the cmd shim explicitly so every Codex/NIM probe shares one launcher order.
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

function Get-DoctorCheck {
    param(
        [object]$Report,
        [string]$Id
    )

    if ($null -eq $Report -or $null -eq $Report.checks) { return $null }

    if ($Report.checks -is [System.Collections.IDictionary]) {
        if ($Report.checks.Contains($Id)) { return $Report.checks[$Id] }
    }

    $directProperty = $Report.checks.PSObject.Properties[$Id]
    if ($null -ne $directProperty) { return $directProperty.Value }

    foreach ($check in @($Report.checks)) {
        if ([string]$check.id -ceq $Id) { return $check }
    }
    return $null
}

function Get-DetailValue {
    param(
        [object]$Check,
        [string[]]$Names
    )

    if ($null -eq $Check -or $null -eq $Check.details) { return $null }
    foreach ($name in $Names) {
        $property = $Check.details.PSObject.Properties[$name]
        if ($null -ne $property) { return [string]$property.Value }
    }
    return $null
}

# `codex doctor` prints the concrete Windows backend name only while it is off
# ("disabled"); once a real backend is active the name comes back as the literal
# string "<redacted>" in both the JSON and human reports on 0.151.0. So the
# backend can only be gated negatively, and the raw value is never a secret.
function Get-SandboxBackendClass {
    param([string]$Backend)

    if ([string]::IsNullOrWhiteSpace($Backend)) { return 'missing' }
    $value = $Backend.Trim()
    if ($value -match '^(?i:disabled|none|off)$') { return 'disabled' }
    if ($value -ceq '<redacted>') { return 'enabled-redacted' }
    if ($value -match '^(?i:RestrictedToken|Elevated)$') { return "enabled-$value" }
    return 'unrecognized'
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
    Write-Output 'CODEX_NIM_DOCTOR'
    Write-Output 'credential_present=False'
    Write-Output 'doctor_request=not_run'
    Write-Output 'overall=FAIL'
    Write-Output 'credential_value_logged=False'
    exit 1
}
$key = $key.Trim('"').Trim("'")

$launchSpec = Get-CodexLaunchSpec
if ($null -eq $launchSpec) {
    Write-Output 'CODEX_NIM_DOCTOR'
    Write-Output 'credential_present=True'
    Write-Output 'codex_found=False'
    Write-Output 'doctor_request=not_run'
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

$oldCodexHome = $env:CODEX_HOME
$oldNimApiKey = $env:NIM_API_KEY
$process = $null
$timedOut = $false
$doctorStdout = ''
$doctorStderr = ''
$doctorExitCode = $null

try {
    $env:CODEX_HOME = $codexHome
    $env:NIM_API_KEY = $key

    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = $launchSpec.FileName
    $startInfo.Arguments = $launchSpec.ArgumentsPrefix + 'doctor --json' + $launchSpec.ArgumentsSuffix
    $startInfo.WorkingDirectory = $repoRoot
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true

    $process = New-Object Diagnostics.Process
    $process.StartInfo = $startInfo
    if (-not $process.Start()) { throw 'Codex doctor process did not start.' }

    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()

    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        $timedOut = $true
        try { & taskkill.exe /PID $process.Id /T /F 1>$null 2>$null } catch {}
        try { $process.WaitForExit(5000) | Out-Null } catch {}
    }

    if ($process.HasExited) { $doctorExitCode = $process.ExitCode }
    try { $doctorStdout = [string]$stdoutTask.Result } catch { $doctorStdout = '' }
    try { $doctorStderr = [string]$stderrTask.Result } catch { $doctorStderr = '' }
}
finally {
    if ($null -eq $oldCodexHome) { Remove-Item Env:CODEX_HOME -ErrorAction SilentlyContinue }
    else { $env:CODEX_HOME = $oldCodexHome }

    if ($null -eq $oldNimApiKey) { Remove-Item Env:NIM_API_KEY -ErrorAction SilentlyContinue }
    else { $env:NIM_API_KEY = $oldNimApiKey }

    if ($null -ne $process) { $process.Dispose() }
}

$credentialLeakDetected = $doctorStdout.Contains($key) -or $doctorStderr.Contains($key)
$report = $null
$decodeOk = $false
if (-not [string]::IsNullOrWhiteSpace($doctorStdout)) {
    try {
        $report = $doctorStdout | ConvertFrom-Json -ErrorAction Stop
        $decodeOk = $true
    }
    catch {}
}

$configCheck = Get-DoctorCheck -Report $report -Id 'config.load'
$authCheck = Get-DoctorCheck -Report $report -Id 'auth.credentials'
$reachabilityCheck = Get-DoctorCheck -Report $report -Id 'network.provider_reachability'
$sandboxCheck = Get-DoctorCheck -Report $report -Id 'sandbox.helpers'

$activeModel = Get-DetailValue -Check $configCheck -Names @('model')
$activeProvider = Get-DetailValue -Check $configCheck -Names @('model provider', 'model_provider')
$providerEnv = Get-DetailValue -Check $authCheck -Names @('provider auth env var', 'provider_auth_env_var')
# `checks.<id>.details` is a JSON object, so every detail is read by name.
$sandboxBackend = Get-DetailValue -Check $sandboxCheck -Names @('sandbox backend', 'sandbox_backend')
$approvalPolicy = Get-DetailValue -Check $sandboxCheck -Names @('approval policy', 'approval_policy')
$filesystemSandbox = Get-DetailValue -Check $sandboxCheck -Names @('filesystem sandbox', 'filesystem_sandbox')
$networkSandbox = Get-DetailValue -Check $sandboxCheck -Names @('network sandbox', 'network_sandbox')
$sandboxBackendClass = Get-SandboxBackendClass -Backend $sandboxBackend

$configStatus = if ($null -eq $configCheck) { 'missing' } else { [string]$configCheck.status }
$authStatus = if ($null -eq $authCheck) { 'missing' } else { [string]$authCheck.status }
$reachabilityStatus = if ($null -eq $reachabilityCheck) { 'missing' } else { [string]$reachabilityCheck.status }
$sandboxStatus = if ($null -eq $sandboxCheck) { 'missing' } else { [string]$sandboxCheck.status }
$providerEnvPresent = $false
if (-not [string]::IsNullOrWhiteSpace($providerEnv)) {
    $providerEnvPresent = $providerEnv -match '(?i)present'
}

$expectedModel = 'nvidia/nemotron-3-super-120b-a12b'
$configLoaded = $configStatus -match '^(?i:ok)$'
$providerSelected = $activeProvider -ceq 'nim'
$modelSelected = $activeModel -ceq $expectedModel
# Gate the backend negatively: "disabled" is the exact state that made
# non-interactive exec-policy reject benign commands, and it is the one state
# doctor still reports verbatim. `filesystem sandbox`/`network sandbox` report
# the requested policy in both arms, so neither discriminates the backend.
$windowsSandboxEnabled = $sandboxBackendClass -like 'enabled*'
$doctorSucceeded = (-not $timedOut -and $doctorExitCode -eq 0 -and $decodeOk)
$overallPass = (
    $doctorSucceeded -and
    $configLoaded -and
    $providerSelected -and
    $modelSelected -and
    $providerEnvPresent -and
    $windowsSandboxEnabled -and
    -not $credentialLeakDetected
)

Write-Output 'CODEX_NIM_DOCTOR'
Write-Output "codex_version=$([string]$codexVersion)"
Write-Output "codex_launcher=$($launchSpec.Kind)"
Write-Output "codex_home=$codexHome"
Write-Output "config_file_exists=$([bool](Test-Path -LiteralPath $configPath -PathType Leaf))"
Write-Output 'config_mode=isolated-default'
Write-Output 'credential_present=True'
Write-Output "credential_source=$credentialSource"
Write-Output "timed_out=$([bool]$timedOut)"
Write-Output "doctor_exit_code=$(if ($null -eq $doctorExitCode) { 'none' } else { [string]$doctorExitCode })"
Write-Output "doctor_decode_ok=$([bool]$decodeOk)"
Write-Output "config_status=$configStatus"
Write-Output "config_loaded=$([bool]$configLoaded)"
Write-Output "active_model=$(if ([string]::IsNullOrWhiteSpace($activeModel)) { 'missing' } else { $activeModel })"
Write-Output "active_provider=$(if ([string]::IsNullOrWhiteSpace($activeProvider)) { 'missing' } else { $activeProvider })"
Write-Output "provider_selected=$([bool]$providerSelected)"
Write-Output "model_selected=$([bool]$modelSelected)"
Write-Output "auth_status=$authStatus"
Write-Output "provider_env_present=$([bool]$providerEnvPresent)"
Write-Output "reachability_status=$reachabilityStatus"
Write-Output "sandbox_status=$sandboxStatus"
Write-Output "sandbox_backend_class=$sandboxBackendClass"
Write-Output "windows_sandbox_enabled=$([bool]$windowsSandboxEnabled)"
Write-Output "approval_policy=$(if ([string]::IsNullOrWhiteSpace($approvalPolicy)) { 'missing' } else { $approvalPolicy })"
Write-Output "filesystem_sandbox=$(if ([string]::IsNullOrWhiteSpace($filesystemSandbox)) { 'missing' } else { $filesystemSandbox })"
Write-Output "network_sandbox=$(if ([string]::IsNullOrWhiteSpace($networkSandbox)) { 'missing' } else { $networkSandbox })"
Write-Output "stderr_present=$([bool](-not [string]::IsNullOrWhiteSpace($doctorStderr)))"
Write-Output "credential_leak_detected=$([bool]$credentialLeakDetected)"
Write-Output "overall=$(if ($overallPass) { 'PASS' } else { 'FAIL' })"
Write-Output 'model_inference_used=false'
Write-Output 'credential_value_logged=False'

if ($overallPass) { exit 0 }
exit 1
