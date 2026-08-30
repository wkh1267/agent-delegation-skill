[CmdletBinding()]
param(
    [string]$RuntimeRoot,
    [string]$BaseUrl = 'https://integrate.api.nvidia.com/v1',
    [string]$Model = 'nvidia/nemotron-3-super-120b-a12b'
)

$ErrorActionPreference = 'Stop'

function ConvertTo-TomlBasicString {
    param([string]$Value)
    if ($null -eq $Value) { return '' }
    ($Value -replace '\\', '\\\\') -replace '"', '\"'
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

$safeBaseUrl = ConvertTo-TomlBasicString $normalizedBaseUrl
$safeModel = ConvertTo-TomlBasicString $Model
$configText = @"
# Keep the V0.1 NIM Worker surface intentionally small. The main Codex Lead owns
# orchestration; this worker only needs the standard function-tool harness.
web_search = "disabled"

[agents]
enabled = false

[features]
multi_agent_v2 = false

[skills.bundled]
enabled = false

[orchestrator.skills]
enabled = false

[orchestrator.mcp]
enabled = false

[model_providers.nim]
name = "NVIDIA NIM"
base_url = "$safeBaseUrl"
env_key = "NIM_API_KEY"
wire_api = "responses"

[profiles.nim-worker]
model = "$safeModel"
model_provider = "nim"
"@

[IO.File]::WriteAllText($configPath, $configText, (New-Object Text.UTF8Encoding($false)))

Write-Output 'CODEX_NIM_SETUP'
Write-Output 'codex_found=True'
Write-Output "codex_version=$([string]$codexVersion)"
Write-Output "codex_home=$codexHome"
Write-Output "config_path=$configPath"
Write-Output "base_url=$normalizedBaseUrl"
Write-Output "model=$Model"
Write-Output 'profile=nim-worker'
Write-Output 'optional_tool_surface=minimal'
Write-Output 'config_written=True'
Write-Output 'credential_value_logged=False'
