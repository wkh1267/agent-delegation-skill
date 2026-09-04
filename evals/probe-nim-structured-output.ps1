[CmdletBinding()]
param(
    [string]$BaseUrl = 'https://integrate.api.nvidia.com/v1',
    [string]$Model = 'nvidia/nemotron-3-super-120b-a12b',
    [ValidateRange(1, 10)]
    [int]$Repetitions = 3,
    [ValidateRange(15, 300)]
    [int]$TimeoutSeconds = 120
)

# N4a — characterize hosted NIM structured output before N4b relies on it.
#
# Codex sends `--output-schema` as the Responses `text.format` json_schema
# object, so this probe measures that exact shape at the provider, with no Codex
# involved. It is a characterization probe, not a correctness gate: its job is to
# establish what the provider actually guarantees so the adapter can be built
# against reality.
#
# Two properties can only be seen by repeating and by differential arms, and
# both turned out to matter:
#
#   1. Enforcement is soft. A single conforming sample proves nothing, because
#      the provider is not doing constrained decoding: malformed payloads such
#      as a doubled opening brace do occur. So the schema arm is repeated and
#      reported as a conformance *rate*, and the adapter must exact-validate.
#
#   2. Tools and structured output are mutually exclusive here. With
#      `text.format` set, the model stops emitting function calls entirely and
#      answers directly, fabricating content it never read. So a tool-using
#      Worker cannot carry the schema in the same turn.
#
# Control arms exist because a model can coincidentally emit plausible JSON.
# Only the schema arm conforming while the control drifts shows the schema has
# any effect at all.

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$credentialSource = 'none'
$schemaPath = Join-Path $repoRoot 'skills\delegating-work\schemas\delegent-handoff.schema.json'
$expectedFields = @('status', 'summary', 'evidence', 'changes', 'tests', 'risks', 'decisions_needed', 'review_targets')

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

function Invoke-Attempt {
    param(
        [string]$Uri,
        [string]$Credential,
        [string]$InputText,
        [hashtable]$Extra,
        [int]$Timeout
    )

    $body = @{ model = $Model; input = $InputText; max_output_tokens = 1200 }
    foreach ($name in $Extra.Keys) { $body[$name] = $Extra[$name] }

    $httpStatus = $null
    $content = $null
    try {
        $response = Invoke-WebRequest -Uri $Uri -Method POST `
            -Headers @{ Authorization = "Bearer $Credential" } `
            -ContentType 'application/json' `
            -Body ($body | ConvertTo-Json -Depth 40 -Compress) `
            -TimeoutSec $Timeout -UseBasicParsing -ErrorAction Stop
        $httpStatus = [int]$response.StatusCode
        $content = [string]$response.Content
    }
    catch {
        try { $httpStatus = [int]$_.Exception.Response.StatusCode } catch {}
    }

    $result = [pscustomobject]@{
        HttpStatus = $httpStatus
        FunctionCallPresent = $false
        ValidJson = $false
        ExactShape = $false
        CredentialLeak = $false
    }
    if ($null -eq $content) { return $result }
    if (-not [string]::IsNullOrEmpty($Credential)) { $result.CredentialLeak = $content.Contains($Credential) }

    $decoded = $null
    try { $decoded = $content | ConvertFrom-Json -ErrorAction Stop } catch { return $result }

    $text = ''
    foreach ($item in @($decoded.output)) {
        if ([string]$item.type -eq 'function_call') { $result.FunctionCallPresent = $true }
        foreach ($chunk in @($item.content)) {
            if ([string]$chunk.type -eq 'output_text') { $text += [string]$chunk.text }
        }
    }

    $parsed = $null
    try { $parsed = $text | ConvertFrom-Json -ErrorAction Stop } catch { return $result }
    if ($null -eq $parsed) { return $result }
    $result.ValidJson = $true

    # Deliberately not named $extra: the parameter above is [hashtable]$Extra and
    # PowerShell variable names are case-insensitive, so that would clobber it.
    $names = @($parsed.PSObject.Properties.Name)
    $missingCount = @($expectedFields | Where-Object { $names -notcontains $_ }).Count
    $extraCount = @($names | Where-Object { $expectedFields -notcontains $_ }).Count
    $result.ExactShape = ($missingCount -eq 0 -and $extraCount -eq 0)
    return $result
}

$key = Get-NimCredential
if ([string]::IsNullOrWhiteSpace($key)) {
    Write-Output 'NIM_STRUCTURED_OUTPUT'
    Write-Output 'credential_present=False'
    Write-Output 'overall=FAIL'
    Write-Output 'credential_value_logged=False'
    exit 1
}
$key = $key.Trim('"').Trim("'")

if (-not (Test-Path -LiteralPath $schemaPath -PathType Leaf)) { throw 'Delegent handoff schema is missing.' }
$schema = Get-Content -Raw -LiteralPath $schemaPath | ConvertFrom-Json

$normalizedBaseUrl = $BaseUrl.TrimEnd('/')
if (-not $normalizedBaseUrl.EndsWith('/v1', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'BaseUrl must include the /v1 suffix required by the Codex NIM provider.'
}
$uri = $normalizedBaseUrl + '/responses'

$handoffTask = 'Report a Delegent handoff for a trivial no-op inspection task. Use status completed, a one-sentence summary, and an empty array for every list field.'
$toolTask = 'Read the file README.md using the read_file tool, then summarize it.'
$textFormat = @{ format = @{ type = 'json_schema'; name = 'codex_output_schema'; strict = $true; schema = $schema } }
$tools = @(
    @{
        type = 'function'
        name = 'read_file'
        description = 'Read a file from the repository.'
        parameters = @{
            type = 'object'
            additionalProperties = $false
            required = @('path')
            properties = @{ path = @{ type = 'string'; description = 'Repository-relative path.' } }
        }
    }
)

# Repeated arm: the shape Codex sends, measured as a conformance rate.
$schemaAttempts = @()
for ($i = 0; $i -lt $Repetitions; $i++) {
    $schemaAttempts += Invoke-Attempt -Uri $uri -Credential $key -InputText $handoffTask -Timeout $TimeoutSeconds -Extra @{ text = $textFormat }
}

# Repeated arm: does the model still call a tool while the schema is attached?
$toolSchemaAttempts = @()
for ($i = 0; $i -lt $Repetitions; $i++) {
    $toolSchemaAttempts += Invoke-Attempt -Uri $uri -Credential $key -InputText $toolTask -Timeout $TimeoutSeconds -Extra @{ tools = $tools; tool_choice = 'auto'; text = $textFormat }
}

# Single control arms.
$responseFormatArm = Invoke-Attempt -Uri $uri -Credential $key -InputText $handoffTask -Timeout $TimeoutSeconds -Extra @{
    response_format = @{ type = 'json_schema'; json_schema = @{ name = 'codex_output_schema'; strict = $true; schema = $schema } }
}
$controlArm = Invoke-Attempt -Uri $uri -Credential $key -InputText $handoffTask -Timeout $TimeoutSeconds -Extra @{}
$toolsOnlyArm = Invoke-Attempt -Uri $uri -Credential $key -InputText $toolTask -Timeout $TimeoutSeconds -Extra @{ tools = $tools; tool_choice = 'auto' }

$schemaAnswered = @($schemaAttempts | Where-Object { $_.HttpStatus -eq 200 }).Count
$schemaValidJson = @($schemaAttempts | Where-Object { $_.ValidJson }).Count
$schemaExact = @($schemaAttempts | Where-Object { $_.ExactShape }).Count
$schemaMalformed = $schemaAnswered - $schemaValidJson
$toolSchemaFunctionCalls = @($toolSchemaAttempts | Where-Object { $_.FunctionCallPresent }).Count

$credentialLeakDetected = @(@($schemaAttempts + $toolSchemaAttempts + @($responseFormatArm, $controlArm, $toolsOnlyArm)) | Where-Object { $_.CredentialLeak }).Count -gt 0

# Soft enforcement means at least one answered attempt failed to conform. With
# constrained decoding this count would always be zero.
$softEnforcementObserved = ($schemaAnswered -gt 0) -and ($schemaExact -lt $schemaAnswered)
$toolsAndSchemaMutuallyExclusive = $toolsOnlyArm.FunctionCallPresent -and ($toolSchemaFunctionCalls -eq 0)

$controlAnswered = ($controlArm.HttpStatus -eq 200)
$capabilityPresent = ($schemaExact -gt 0)
$differential = 'INCONCLUSIVE'
if ($controlAnswered -and $capabilityPresent) {
    $differential = if ($controlArm.ExactShape) { 'SCHEMA_EFFECT_UNPROVEN' }
    elseif ($softEnforcementObserved) { 'SCHEMA_HONOURED_BUT_SOFT' }
    else { 'SCHEMA_HONOURED' }
}
elseif ($controlAnswered) { $differential = 'SCHEMA_NOT_HONOURED' }

# The gate is capability characterization, not provider perfection. Soft
# enforcement and the tool exclusion are findings the adapter must handle, and
# N4b is where correctness is actually enforced.
$overallPass = (
    $capabilityPresent -and
    $controlAnswered -and
    -not $controlArm.ExactShape -and
    $toolsOnlyArm.FunctionCallPresent -and
    -not $credentialLeakDetected
)

Write-Output 'NIM_STRUCTURED_OUTPUT'
Write-Output "base_url=$normalizedBaseUrl"
Write-Output "model=$Model"
Write-Output 'wire_api=responses'
Write-Output 'credential_present=True'
Write-Output "credential_source=$credentialSource"
Write-Output "schema_field_count=$($expectedFields.Count)"
Write-Output "repetitions=$Repetitions"
Write-Output "text_format_answered=$schemaAnswered"
Write-Output "text_format_valid_json=$schemaValidJson"
Write-Output "text_format_malformed_json=$schemaMalformed"
Write-Output "text_format_exact_shape=$schemaExact"
Write-Output "text_format_conformance=$schemaExact/$schemaAnswered"
Write-Output "response_format_exact_shape=$([bool]$responseFormatArm.ExactShape)"
Write-Output "control_http_status=$(if ($null -eq $controlArm.HttpStatus) { 'none' } else { $controlArm.HttpStatus })"
Write-Output "control_exact_shape=$([bool]$controlArm.ExactShape)"
Write-Output "tools_only_function_call_present=$([bool]$toolsOnlyArm.FunctionCallPresent)"
Write-Output "tools_plus_schema_function_calls=$toolSchemaFunctionCalls/$Repetitions"
Write-Output "soft_enforcement_observed=$([bool]$softEnforcementObserved)"
Write-Output "tools_and_schema_mutually_exclusive=$([bool]$toolsAndSchemaMutuallyExclusive)"
Write-Output "structured_output_differential=$differential"
Write-Output "credential_leak_detected=$([bool]$credentialLeakDetected)"
Write-Output "overall=$(if ($overallPass) { 'PASS' } else { 'FAIL' })"
Write-Output 'credential_value_logged=False'

if ($overallPass) { exit 0 }
exit 1
