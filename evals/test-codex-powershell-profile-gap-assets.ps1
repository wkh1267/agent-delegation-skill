$ErrorActionPreference = 'Stop'
$path = Join-Path $PSScriptRoot 'diagnose-codex-powershell-profile-gap.ps1'

function Assert-True {
    param([bool]$Condition, [string]$Message = 'Assertion failed.')
    if (-not $Condition) { throw $Message }
}

$tokens = $null
$errors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
Assert-True ($errors.Count -eq 0) 'PowerShell parser errors in Codex PowerShell profile-gap diagnostic.'

$text = Get-Content -Raw -LiteralPath $path
Assert-True ($text -match 'CODEX_POWERSHELL_PROFILE_GAP') 'Diagnostic must expose a distinct result contract.'
Assert-True ($text -match 'sandbox -P') 'Diagnostic must call codex sandbox directly.'
Assert-True ($text -match 'PermissionProfile '':read-only''.*UseNoProfile \$true') 'Reference arm must use read-only plus -NoProfile.'
Assert-True ($text -match 'PermissionProfile '':read-only''.*UseNoProfile \$false') 'Agent-shape arm must use read-only without -NoProfile.'
Assert-True ($text -match 'PermissionProfile '':danger-full-access''.*UseNoProfile \$false') 'Control arm must use full access without -NoProfile.'
Assert-True ($text -match 'if \(\$UseNoProfile\) \{ '' -NoProfile'' \} else \{ '''' \}') 'Only the PowerShell -NoProfile flag may vary between matching read-only arms.'
Assert-True ($text -match 'Get-Content -LiteralPath README\.md -TotalCount 3') 'All arms must use the deterministic README command.'
Assert-True ($text -match 'profile_gap_differential=') 'Diagnostic must classify the profile-gap result.'
Assert-True ($text -match 'NOPROFILE_GAP_CONFIRMED') 'Diagnostic must recognize the isolated -NoProfile gap.'
Assert-True ($text -match 'DIRECT_AGENT_SHAPE_HEALTHY') 'Diagnostic must recognize when the direct agent-shaped command is healthy.'
Assert-True ($text -match 'status --porcelain=v1 --untracked-files=all') 'Diagnostic must verify the working tree invariant.'
Assert-True ($text -match 'working_tree_unchanged=') 'Diagnostic must report working-tree stability.'
Assert-True ($text -match 'model_inference_used=false') 'Diagnostic must remain zero-inference.'
Assert-True ($text -match 'credential_required=false') 'Diagnostic must require no provider credential.'
Assert-True ($text -notmatch 'NIM_API_KEY|DELEGENT_API_KEY|api_key') 'Diagnostic must not access provider credentials.'
Assert-True ($text -match 'Get-Command codex\.cmd' -and $text -match 'Kind = ''cmd-shim''') 'Diagnostic must preserve the proven cmd-shim launcher.'
Assert-True ($text -notmatch 'nvapi-[A-Za-z0-9_-]{12,}') 'Diagnostic must not contain credential literals.'

Write-Output 'PASS Codex PowerShell profile-gap diagnostic assets'
exit 0
