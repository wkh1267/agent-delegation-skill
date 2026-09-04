[CmdletBinding()]
param(
    [string]$RuntimeRoot,
    [string]$BaseUrl = 'https://integrate.api.nvidia.com/v1',
    [string]$Model = 'nvidia/nemotron-3-super-120b-a12b',
    # Optional Delegent handoff boundary. All three must be supplied together,
    # and only the N4 gate supplies them, so every earlier gate keeps inspecting
    # the same minimal config it was validated against.
    [string]$HandoffToolPath,
    [string]$HandoffSchemaPath,
    [string]$HandoffOutPath
)

$ErrorActionPreference = 'Stop'

function ConvertTo-TomlBasicString {
    param([string]$Value)
    if ($null -eq $Value) { return '' }
    # String .Replace, not -replace: in a regex replacement '\\\\' is four
    # literal backslashes, so the regex form turned one backslash into four and
    # TOML then parsed it back to two. That stayed invisible while this only
    # escaped values without backslashes, and produced broken Windows paths as
    # soon as one was escaped. Backslashes first, then quotes, so the backslash
    # introduced by \" is not doubled.
    $Value.Replace('\', '\\').Replace('"', '\"')
}

if ([string]::IsNullOrWhiteSpace($RuntimeRoot)) {
    if ($env:LOCALAPPDATA) {
        $RuntimeRoot = Join-Path $env:LOCALAPPDATA 'agent-delegation-skills\codex-nim'
    }
    else {
        $RuntimeRoot = Join-Path ([IO.Path]::GetTempPath()) 'agent-delegation-skills\codex-nim'
    }
}

$normalizedBaseUrl = $BaseUrl.TrimEnd('/')
if (-not $normalizedBaseUrl.EndsWith('/v1', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'BaseUrl must include the /v1 suffix required by the Codex NIM provider.'
}

$codexCommand = Get-Command codex -CommandType Application, ExternalScript -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $codexCommand) {
    Write-Output 'CODEX_NIM_SETUP'
    Write-Output 'codex_found=False'
    Write-Output 'config_written=False'
    Write-Output 'credential_value_logged=False'
    exit 1
}

$codexVersion = (& $codexCommand.Source --version 2>$null | Select-Object -First 1)
if ([string]::IsNullOrWhiteSpace([string]$codexVersion)) {
    $codexVersion = 'unknown'
}

$codexHome = Join-Path $RuntimeRoot 'codex-home'
New-Item -ItemType Directory -Force -Path $codexHome | Out-Null
$configPath = Join-Path $codexHome 'config.toml'
$staleProfilePath = Join-Path $codexHome 'nim-worker.config.toml'

$safeBaseUrl = ConvertTo-TomlBasicString $normalizedBaseUrl
$safeModel = ConvertTo-TomlBasicString $Model

# This CODEX_HOME is dedicated to the delegated NIM Worker, so the base config
# can select the Worker model/provider directly. Avoiding a profile removes an
# unnecessary config layer and lets `codex exec` and `codex doctor` inspect the
# exact same effective configuration.
#
# On Codex 0.151.0 for Windows, an unspecified Windows sandbox backend resolves
# to Disabled even when the turn uses a restricted permission profile. In
# non-interactive `codex exec`, exec-policy then rejects otherwise-benign
# unmatched commands because there is no enforceable Windows sandbox and no
# approval prompt. Explicit unelevated mode maps to RestrictedToken and keeps
# the Worker inside Codex's managed Windows sandbox.
$configText = @"
model = "$safeModel"
model_provider = "nim"

[windows]
sandbox = "unelevated"

[model_providers.nim]
name = "NVIDIA NIM"
base_url = "$safeBaseUrl"
env_key = "NIM_API_KEY"
wire_api = "responses"
"@

$handoffRequested = -not (
    [string]::IsNullOrWhiteSpace($HandoffToolPath) -and
    [string]::IsNullOrWhiteSpace($HandoffSchemaPath) -and
    [string]::IsNullOrWhiteSpace($HandoffOutPath)
)
$handoffToolRegistered = $false
if ($handoffRequested) {
    if ([string]::IsNullOrWhiteSpace($HandoffToolPath) -or
        [string]::IsNullOrWhiteSpace($HandoffSchemaPath) -or
        [string]::IsNullOrWhiteSpace($HandoffOutPath)) {
        throw 'HandoffToolPath, HandoffSchemaPath and HandoffOutPath must be supplied together.'
    }
    if (-not (Test-Path -LiteralPath $HandoffToolPath -PathType Leaf)) { throw 'Handoff MCP server was not found.' }
    if (-not (Test-Path -LiteralPath $HandoffSchemaPath -PathType Leaf)) { throw 'Handoff schema was not found.' }

    # Resolve node rather than relying on the child process inheriting a PATH
    # that happens to contain it.
    $nodeCommand = Get-Command node -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $nodeCommand) { throw 'node is required to host the Delegent handoff MCP boundary.' }

    # The hosted NIM endpoint does not enforce Responses-native structured
    # output, so the terminal handoff travels as tool-call arguments instead.
    # See docs/decisions/0001-codex-nim-worker-runtime.md.
    $configText += @"


[mcp_servers.delegent]
command = "$(ConvertTo-TomlBasicString $nodeCommand.Source)"
args = ["$(ConvertTo-TomlBasicString $HandoffToolPath)", "$(ConvertTo-TomlBasicString $HandoffSchemaPath)", "$(ConvertTo-TomlBasicString $HandoffOutPath)"]
enabled = true
required = true
startup_timeout_sec = 20
tool_timeout_sec = 60
default_tools_approval_mode = "auto"
enabled_tools = ["delegent_handoff"]
"@
    $handoffToolRegistered = $true
}

[IO.File]::WriteAllText($configPath, $configText, (New-Object Text.UTF8Encoding($false)))
$staleProfileRemoved = $false
if (Test-Path -LiteralPath $staleProfilePath -PathType Leaf) {
    Remove-Item -LiteralPath $staleProfilePath -Force
    $staleProfileRemoved = $true
}

Write-Output 'CODEX_NIM_SETUP'
Write-Output 'codex_found=True'
Write-Output "codex_version=$([string]$codexVersion)"
Write-Output "codex_home=$codexHome"
Write-Output "config_path=$configPath"
Write-Output "base_url=$normalizedBaseUrl"
Write-Output "model=$Model"
Write-Output 'model_provider=nim'
Write-Output 'windows_sandbox=unelevated'
Write-Output "handoff_tool_registered=$([bool]$handoffToolRegistered)"
Write-Output 'config_mode=isolated-default'
Write-Output 'profile_required=False'
Write-Output "stale_profile_removed=$([bool]$staleProfileRemoved)"
Write-Output 'config_written=True'
Write-Output 'credential_value_logged=False'
