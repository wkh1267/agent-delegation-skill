[CmdletBinding()]
param(
    [string]$BaseUrl = 'https://integrate.api.nvidia.com/v1',
    [string]$Model = 'nvidia/nemotron-3-super-120b-a12b',
    [ValidateRange(5, 120)]
    [int]$TimeoutSeconds = 45
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

function Invoke-SafeJsonPost {
    param(
        [string]$Uri,
        [hashtable]$Headers,
        [string]$Body,
        [int]$Timeout
    )

    try {
        $response = Invoke-WebRequest `
            -Uri $Uri `
            -Method POST `
            -Headers $Headers `
            -ContentType 'application/json' `
            -Body $Body `
            -TimeoutSec $Timeout `
            -UseBasicParsing `
            -ErrorAction Stop

        return [pscustomobject]@{
            Status = 'ok'
            HttpStatus = [int]$response.StatusCode
            Content = [string]$response.Content
        }
    }
    catch {
        $httpStatus = $null
        if ($null -ne $_.Exception.Response -and $null -ne $_.Exception.Response.StatusCode) {
            try { $httpStatus = [int]$_.Exception.Response.StatusCode } catch {}
        }

        $status = 'network_error'
        if ($_.Exception -is [Net.WebException] -and $_.Exception.Status -eq [Net.WebExceptionStatus]::Timeout) {
            $status = 'timeout'
        }
        elseif ($null -ne $httpStatus) {
            $status = 'http_error'
        }

        return [pscustomobject]@{
            Status = $status
            HttpStatus = $httpStatus
            Content = $null
        }
    }
}

function ConvertFrom-SafeJson {
    param([string]$Json)
    try {
        [pscustomobject]@{
            Status = 'ok'
            Value = ($Json | ConvertFrom-Json -ErrorAction Stop)
        }
    }
    catch {
        [pscustomobject]@{
            Status = 'decode_error'
            Value = $null
        }
    }
}

$normalizedBaseUrl = $BaseUrl.TrimEnd('/')
if (-not $normalizedBaseUrl.EndsWith('/v1', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'BaseUrl must include the /v1 suffix.'
}
$responsesUrl = $normalizedBaseUrl + '/responses'

$key = Get-NimCredential
if ([string]::IsNullOrWhiteSpace($key)) {
    Write-Output 'NIM_RESPONSES_PROBE'
    Write-Output "endpoint=$responsesUrl"
    Write-Output "model=$Model"
    Write-Output 'credential_present=False'
    Write-Output 'network_requests_sent=0'
    Write-Output 'overall=FAIL'
    Write-Output 'credential_value_logged=False'
    exit 1
}
$key = $key.Trim('"').Trim("'")

$headers = @{
    Authorization = 'Bearer ' + $key
    Accept = 'application/json'
}

$basicBody = [ordered]@{
    model = $Model
    input = 'Reply with exactly NIM_RESPONSES_OK.'
    stream = $false
} | ConvertTo-Json -Depth 16 -Compress

$requestsSent = 1
$basicRequest = Invoke-SafeJsonPost -Uri $responsesUrl -Headers $headers -Body $basicBody -Timeout $TimeoutSeconds
$basicDecode = $null
$basicShape = $false
if ($basicRequest.Status -eq 'ok') {
    $basicDecode = ConvertFrom-SafeJson $basicRequest.Content
    if ($basicDecode.Status -eq 'ok' -and $null -ne $basicDecode.Value.PSObject.Properties['output']) {
        $basicShape = $true
    }
}

$toolRequest = [pscustomobject]@{ Status = 'skipped'; HttpStatus = $null; Content = $null }
$toolDecodeStatus = 'skipped'
$functionCallPresent = $false
$functionNameMatch = $false
$callIdPresent = $false
$argumentsValid = $false

if ($basicRequest.Status -eq 'ok' -and $basicShape) {
    $toolBody = [ordered]@{
        model = $Model
        input = @(
            [ordered]@{
                role = 'user'
                content = 'Use the delegent_probe function with value TOOL_OK. Do not answer in text.'
            }
        )
        tools = @(
            [ordered]@{
                type = 'function'
                name = 'delegent_probe'
                description = 'Return a deterministic compatibility probe value.'
                parameters = [ordered]@{
                    type = 'object'
                    properties = [ordered]@{
                        value = [ordered]@{
                            type = 'string'
                            enum = @('TOOL_OK')
                        }
                    }
                    required = @('value')
                    additionalProperties = $false
                }
            }
        )
        tool_choice = 'auto'
        stream = $false
    } | ConvertTo-Json -Depth 32 -Compress

    $requestsSent++
    $toolRequest = Invoke-SafeJsonPost -Uri $responsesUrl -Headers $headers -Body $toolBody -Timeout $TimeoutSeconds

    if ($toolRequest.Status -eq 'ok') {
        $toolDecode = ConvertFrom-SafeJson $toolRequest.Content
        $toolDecodeStatus = $toolDecode.Status
        if ($toolDecode.Status -eq 'ok' -and $null -ne $toolDecode.Value.PSObject.Properties['output']) {
            $calls = @($toolDecode.Value.output | Where-Object { $_.type -eq 'function_call' })
            $functionCallPresent = $calls.Count -gt 0
            $probeCalls = @($calls | Where-Object { $_.name -eq 'delegent_probe' })
            if ($probeCalls.Count -gt 0) {
                $functionNameMatch = $true
                $call = $probeCalls[0]
                $callIdPresent = -not [string]::IsNullOrWhiteSpace([string]$call.call_id)
                try {
                    $arguments = ([string]$call.arguments) | ConvertFrom-Json -ErrorAction Stop
                    $argumentNames = @($arguments.PSObject.Properties.Name)
                    $argumentsValid = (
                        $argumentNames.Count -eq 1 -and
                        $argumentNames[0] -ceq 'value' -and
                        [string]$arguments.value -ceq 'TOOL_OK'
                    )
                }
                catch {
                    $argumentsValid = $false
                }
            }
        }
    }
}

$basicHttpStatus = if ($null -eq $basicRequest.HttpStatus) { 'none' } else { [string]$basicRequest.HttpStatus }
$toolHttpStatus = if ($null -eq $toolRequest.HttpStatus) { 'none' } else { [string]$toolRequest.HttpStatus }
$basicDecodeStatus = if ($null -eq $basicDecode) { 'skipped' } else { [string]$basicDecode.Status }

$overallPass = (
    $basicRequest.Status -eq 'ok' -and
    $basicShape -and
    $toolRequest.Status -eq 'ok' -and
    $toolDecodeStatus -eq 'ok' -and
    $functionCallPresent -and
    $functionNameMatch -and
    $callIdPresent -and
    $argumentsValid
)

Write-Output 'NIM_RESPONSES_PROBE'
Write-Output "endpoint=$responsesUrl"
Write-Output "model=$Model"
Write-Output 'credential_present=True'
Write-Output "credential_source=$credentialSource"
Write-Output "network_requests_sent=$requestsSent"
Write-Output "basic_request=$($basicRequest.Status)"
Write-Output "basic_http_status=$basicHttpStatus"
Write-Output "basic_decode=$basicDecodeStatus"
Write-Output "basic_output_shape=$([bool]$basicShape)"
Write-Output "tool_request=$($toolRequest.Status)"
Write-Output "tool_http_status=$toolHttpStatus"
Write-Output "tool_decode=$toolDecodeStatus"
Write-Output "function_call_present=$([bool]$functionCallPresent)"
Write-Output "function_name_match=$([bool]$functionNameMatch)"
Write-Output "call_id_present=$([bool]$callIdPresent)"
Write-Output "arguments_valid=$([bool]$argumentsValid)"
Write-Output "overall=$(if ($overallPass) { 'PASS' } else { 'FAIL' })"
Write-Output 'credential_value_logged=False'

if ($overallPass) { exit 0 }
exit 1
