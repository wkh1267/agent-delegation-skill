$ErrorActionPreference = 'Stop'
$setupPath = Join-Path $PSScriptRoot 'setup-codex-nim.ps1'
$probePath = Join-Path $PSScriptRoot 'probe-nim-responses.ps1'

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message = 'Assertion failed.'
    )
    if (-not $Condition) { throw $Message }
}

foreach ($path in @($setupPath, $probePath)) {
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
    Assert-True ($errors.Count -eq 0) "PowerShell parser errors in $path"
}

$setup = Get-Content -Raw -LiteralPath $setupPath
$probe = Get-Content -Raw -LiteralPath $probePath

Assert-True ($setup -match '\[model_providers\.nim\]') 'Setup must define the NIM model provider.'
Assert-True ($setup -match 'env_key = "NIM_API_KEY"') 'Setup must use an environment variable for the NIM credential.'
Assert-True ($setup -match 'wire_api = "responses"') 'Setup must use the Responses wire API.'
Assert-True ($setup -match 'model_provider = "nim"') 'Isolated Worker config must select the NIM provider directly.'
Assert-True ($setup -match 'model = "\$safeModel"') 'Isolated Worker config must select the requested Nemotron model directly.'
Assert-True ($setup -match 'config_mode=isolated-default') 'Setup output must identify the isolated default-config mode.'
Assert-True ($setup -match 'profile_required=False') 'Setup must make clear that a profile is not required in the dedicated Worker CODEX_HOME.'
Assert-True ($setup -match 'Remove-Item -LiteralPath \$staleProfilePath') 'Setup must remove stale generated profile state from earlier experiments.'
Assert-True ($setup -match 'codex-home') 'Setup must create an isolated CODEX_HOME directory.'
Assert-True ($setup -notmatch '\$HOME\\\.codex|~\/\.codex') 'Setup must not mutate the normal user Codex home.'
Assert-True ($setup -notmatch 'nvapi-[A-Za-z0-9_-]+') 'Setup must not contain a NVIDIA credential literal.'

Assert-True ($probe -match "\+ '/responses'") 'Probe must target the Responses endpoint.'
Assert-True ($probe -match "tool_choice = 'auto'") 'Probe must exercise automatic function tool choice used by Codex.'
Assert-True ($probe -match "type = 'function'") 'Probe must send a function tool.'
Assert-True ($probe -match "type -eq 'function_call'") 'Probe must require a real Responses function_call item.'
Assert-True ($probe -match 'call_id') 'Probe must verify the tool call ID.'
Assert-True ($probe -match 'arguments_valid') 'Probe must validate function arguments.'
Assert-True ($probe -match 'NIM_API_KEY' -and $probe -match 'DELEGENT_API_KEY') 'Probe must support environment-provided credentials.'
Assert-True ($probe -match 'delegating-work\\\.env') 'Probe may reuse the existing ignored Delegent credential source.'
Assert-True ($probe -notmatch 'Write-Output[^\r\n]*(\$key|api_key|Content)') 'Probe must never write credential or raw response content.'
Assert-True ($probe -notmatch 'nvapi-[A-Za-z0-9_-]+') 'Probe must not contain a NVIDIA credential literal.'
Assert-True ($probe -match 'credential_value_logged=False') 'Probe must make the no-secret-output contract explicit.'

Write-Output 'PASS Codex NIM N0/N1 bootstrap assets'
exit 0
