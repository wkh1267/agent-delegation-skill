[CmdletBinding()]
param(
    [string]$RuntimeRoot
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

$codexCommand = Get-Command codex -CommandType Application, ExternalScript -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $codexCommand) {
    Write-Output 'CODEX_NIM_DOCTOR'
    Write-Output 'credential_present=True'
    Write-Output 'codex_found=False'
    Write-Output 'doctor_request=not_run'
    Write-Output 'overall=FAIL'
    Write-Output 'credential_value_logged=False'
    exit 1
}

& (Join-Path $PSScriptRoot 'setup-codex-nim.ps1') -RuntimeRoot $RuntimeRoot | Out-Null
$codexHome = Join-Path $RuntimeRoot 'codex-home'
$profilePath = Join-Path $codexHome 'nim-worker.config.toml'

$oldCodexHome = $env:CODEX_HOME
$oldNimApiKey = $env:NIM_API_KEY
$doctorStdout = ''
$doctorStderr = ''
$doctorExitCode = $null
$stdoutPath = Join-Path $RuntimeRoot ('doctor-stdout-' + [Guid]::NewGuid().ToString('N') + '.txt')
$stderrPath = Join-Path $RuntimeRoot ('doctor-stderr-' + [Guid]::NewGuid().ToString('N') + '.txt')

try {
    New-Item -ItemType Directory -Force -Path $RuntimeRoot | Out-Null
    $env:CODEX_HOME = $codexHome
    $env:NIM_API_KEY = $key

    & $codexCommand.Source -p nim-worker doctor --json 1>$stdoutPath 2>$stderrPath
    $doctorExitCode = $LASTEXITCODE

    if (Test-Path -LiteralPath $stdoutPath -PathType Leaf) {
        $doctorStdout = [IO.File]::ReadAllText($stdoutPath)
    }
    if (Test-Path -LiteralPath $stderrPath -PathType Leaf) {
        $doctorStderr = [IO.File]::ReadAllText($stderrPath)
    }
}
finally {
    if ($null -eq $oldCodexHome) { Remove-Item Env:CODEX_HOME -ErrorAction SilentlyContinue }
    else { $env:CODEX_HOME = $oldCodexHome }

    if ($null -eq $oldNimApiKey) { Remove-Item Env:NIM_API_KEY -ErrorAction SilentlyContinue }
    else { $env:NIM_API_KEY = $oldNimApiKey }

    Remove-Item -LiteralPath $stdoutPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $stderrPath -Force -ErrorAction SilentlyContinue
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

$activeModel = Get-DetailValue -Check $configCheck -Names @('model')
$activeProvider = Get-DetailValue -Check $configCheck -Names @('model provider', 'model_provider')
$providerEnv = Get-DetailValue -Check $authCheck -Names @('provider auth env var', 'provider_auth_env_var')

$configStatus = if ($null -eq $configCheck) { 'missing' } else { [string]$configCheck.status }
$authStatus = if ($null -eq $authCheck) { 'missing' } else { [string]$authCheck.status }
$reachabilityStatus = if ($null -eq $reachabilityCheck) { 'missing' } else { [string]$reachabilityCheck.status }
$providerEnvPresent = $false
if (-not [string]::IsNullOrWhiteSpace($providerEnv)) {
    $providerEnvPresent = $providerEnv -match '(?i)present'
}

$expectedModel = 'nvidia/nemotron-3-super-120b-a12b'
$configLoaded = $configStatus -match '^(?i:ok)$'
$providerSelected = $activeProvider -ceq 'nim'
$modelSelected = $activeModel -ceq $expectedModel
$doctorSucceeded = ($doctorExitCode -eq 0 -and $decodeOk)
$overallPass = (
    $doctorSucceeded -and
    $configLoaded -and
    $providerSelected -and
    $modelSelected -and
    $providerEnvPresent -and
    -not $credentialLeakDetected
)

Write-Output 'CODEX_NIM_DOCTOR'
Write-Output "codex_version=$([string]((& $codexCommand.Source --version 2>$null | Select-Object -First 1)))"
Write-Output "codex_home=$codexHome"
Write-Output 'profile=nim-worker'
Write-Output 'profile_format=v2-layer'
Write-Output "profile_file_exists=$([bool](Test-Path -LiteralPath $profilePath -PathType Leaf))"
Write-Output 'credential_present=True'
Write-Output "credential_source=$credentialSource"
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
Write-Output "stderr_present=$([bool](-not [string]::IsNullOrWhiteSpace($doctorStderr)))"
Write-Output "credential_leak_detected=$([bool]$credentialLeakDetected)"
Write-Output "overall=$(if ($overallPass) { 'PASS' } else { 'FAIL' })"
Write-Output 'model_inference_used=false'
Write-Output 'credential_value_logged=False'

if ($overallPass) { exit 0 }
exit 1
