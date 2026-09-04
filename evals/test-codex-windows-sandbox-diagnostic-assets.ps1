$ErrorActionPreference = 'Stop'
$path = Join-Path $PSScriptRoot 'diagnose-codex-windows-sandbox.ps1'

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message = 'Assertion failed.'
    )
    if (-not $Condition) { throw $Message }
}

$tokens = $null
$errors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
Assert-True ($errors.Count -eq 0) 'PowerShell parser errors in Codex Windows sandbox diagnostic.'

$text = Get-Content -Raw -LiteralPath $path
Assert-True ($text -match 'CODEX_WINDOWS_SANDBOX_DIAGNOSTIC') 'Diagnostic must expose a distinct result contract.'
Assert-True ($text -match "sandbox -P") 'Diagnostic must invoke the Codex sandbox subcommand directly.'
Assert-True ($text -match "PermissionProfile ':read-only'") 'Diagnostic must test the built-in read-only profile.'
Assert-True ($text -match "PermissionProfile ':danger-full-access'") 'Diagnostic must include an unsandboxed control arm.'
Assert-True ($text -match 'Get-Content -LiteralPath README\.md -TotalCount 3') 'Both arms must use the deterministic README read command.'
Assert-True ($text -match 'read_only_blocked_by_policy=') 'Diagnostic must expose read-only policy rejection evidence.'
Assert-True ($text -match 'read_only_create_process_failure=') 'Diagnostic must expose read-only process creation evidence.'
Assert-True ($text -match 'control_output_match=') 'Diagnostic must expose the full-access control result.'
Assert-True ($text -match 'sandbox_differential=') 'Diagnostic must classify the A/B result.'
Assert-True ($text -match 'status --porcelain=v1 --untracked-files=all') 'Diagnostic must compare working tree state before and after.'
Assert-True ($text -match 'working_tree_unchanged=') 'Diagnostic must expose the working tree invariant.'
Assert-True ($text -match 'model_inference_used=false') 'Diagnostic must remain zero-inference.'
Assert-True ($text -match 'credential_required=false') 'Diagnostic must not require the NVIDIA credential.'
Assert-True ($text -notmatch 'NIM_API_KEY|DELEGENT_API_KEY|api_key') 'Direct sandbox diagnostic must not access provider credentials.'
Assert-True ($text -match 'Get-Command codex\.cmd' -and $text -match "Kind = 'cmd-shim'") 'Diagnostic must preserve the proven Windows cmd-shim launcher behavior.'
Assert-True ($text -notmatch 'nvapi-[A-Za-z0-9_-]{12,}') 'Diagnostic must not contain credential literals.'

Write-Output 'PASS direct Codex Windows sandbox diagnostic assets'
exit 0
