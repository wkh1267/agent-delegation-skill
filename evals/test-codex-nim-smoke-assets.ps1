$ErrorActionPreference = 'Stop'
$smokePath = Join-Path $PSScriptRoot 'run-codex-nim-smoke.ps1'
$doctorPath = Join-Path $PSScriptRoot 'diagnose-codex-nim-doctor.ps1'
$repoReadPath = Join-Path $PSScriptRoot 'run-codex-nim-repo-read.ps1'

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message = 'Assertion failed.'
    )
    if (-not $Condition) { throw $Message }
}

foreach ($path in @($smokePath, $doctorPath, $repoReadPath)) {
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
    Assert-True ($errors.Count -eq 0) "PowerShell parser errors in $path"
}

$smoke = Get-Content -Raw -LiteralPath $smokePath
Assert-True ($smoke -match 'CODEX_HOME') 'N2 smoke must use isolated CODEX_HOME.'
Assert-True ($smoke -match 'setup-codex-nim\.ps1') 'N2 smoke must regenerate the isolated NIM Worker config.'
Assert-True ($smoke -match 'config_mode=isolated-default') 'N2 smoke output must identify the dedicated isolated config mode.'
Assert-True ($smoke -match 'harness_mode=minimal') 'N2b smoke must identify the minimal harness mode.'
Assert-True ($smoke -notmatch '-p nim-worker') 'N2 smoke must not depend on a profile inside the dedicated Worker CODEX_HOME.'
Assert-True ($smoke -match "\$codexArgs = 'exec --json -'") 'N2b smoke must use only the minimal Codex exec JSONL surface.'
Assert-True ($smoke -notmatch "\$codexArgs = '[^']*(--strict-config|--ephemeral|--sandbox|--ignore-rules)") 'N2b must not mix hardening options into the core harness gate.'
Assert-True ($smoke -match 'strict_config=False' -and $smoke -match 'sandbox=default' -and $smoke -match 'ephemeral=False' -and $smoke -match 'ignore_rules=False') 'N2b output must make deferred hardening explicit.'
Assert-True ($smoke -match 'Reply with exactly WORKER_OK\.') 'N2 smoke must use the deterministic WORKER_OK task.'
Assert-True ($smoke -match "type -eq 'thread\.started'") 'N2 smoke must require a thread.started event.'
Assert-True ($smoke -match "type -eq 'turn\.completed'") 'N2 smoke must require turn completion.'
Assert-True ($smoke -match "item\.type -eq 'agent_message'") 'N2 smoke must inspect the completed agent message.'
Assert-True ($smoke -match "-ceq 'WORKER_OK'") 'N2 smoke must require the exact final message.'
Assert-True ($smoke -match 'ReadToEndAsync') 'N2 smoke must drain stdout and stderr without pipe deadlock.'
Assert-True ($smoke -match 'taskkill\.exe /PID \$process\.Id /T /F') 'N2 smoke must bound and clean up the Codex process tree.'
Assert-True ($smoke -match 'Get-Command codex\.cmd' -and $smoke -match "Kind = 'cmd-shim'") 'N2 smoke must prefer the npm cmd shim for redirected stdin on Windows.'
Assert-True ($smoke -match "Kind = 'powershell-shim-fallback'") 'N2 smoke may retain the PowerShell shim only as a fallback.'
Assert-True ($smoke -match 'powershell_shim_error') 'N2 smoke must classify the known PowerShell npm shim failure distinctly.'
Assert-True ($smoke -match 'Get-SafeFailureClass' -and $smoke -match 'failure_class=') 'N2 smoke must classify failures without printing raw stderr.'
Assert-True ($smoke -match 'Get-SafeStderrSummary' -and $smoke -match 'stderr_summary=') 'N2 smoke must expose a bounded sanitized startup error summary.'
Assert-True ($smoke -match 'Replace\(\$Credential, ''<redacted>''\)') 'N2 stderr summary must redact the exact credential before output.'
Assert-True ($smoke -match 'stdout\.Contains\(\$key\)' -and $smoke -match 'stderr\.Contains\(\$key\)') 'N2 smoke must fail if the credential appears in captured process output.'
Assert-True ($smoke -notmatch 'Write-Output[^\r\n]*(\$stdout\b|\$stderr\b|\$key\b)') 'N2 smoke must not print raw process streams or credential values.'
Assert-True ($smoke -notmatch 'nvapi-[A-Za-z0-9_-]{12,}') 'N2 smoke must not contain a NVIDIA credential literal.'
Assert-True ($smoke -match 'credential_value_logged=False') 'N2 smoke must make the no-secret-output contract explicit.'

$doctor = Get-Content -Raw -LiteralPath $doctorPath
Assert-True ($doctor -match 'setup-codex-nim\.ps1') 'N2 doctor must use the same isolated NIM Worker config setup.'
Assert-True ($doctor -match "ArgumentsPrefix \+ 'doctor --json'") 'N2 doctor must inspect the dedicated Worker config without a profile.'
Assert-True ($doctor -notmatch '-p nim-worker doctor') 'N2 doctor must not use --profile because doctor is not a profile-capable runtime command.'
Assert-True ($doctor -match "'config\.load'") 'N2 doctor must inspect config.load.'
Assert-True ($doctor -match "'auth\.credentials'") 'N2 doctor must inspect auth.credentials.'
Assert-True ($doctor -match "'network\.provider_reachability'") 'N2 doctor must inspect provider reachability.'
Assert-True ($doctor -match "'sandbox\.helpers'") 'N2/N3 preflight doctor must inspect the effective sandbox backend.'
Assert-True ($doctor -match 'Get-DetailValue -Check \$sandboxCheck') 'Doctor must read object-shaped sandbox details by name.'
Assert-True ($doctor -notmatch 'Get-DetailLineValue') 'Doctor must not parse object-shaped details as "name: value" lines.'
Assert-True ($doctor -match "activeProvider -ceq 'nim'") 'N2 doctor must require the NIM provider.'
Assert-True ($doctor -match "expectedModel = 'nvidia/nemotron-3-super-120b-a12b'") 'N2 doctor must require the intended Nemotron model.'
Assert-True ($doctor -match 'Get-SandboxBackendClass') 'Doctor must classify the sandbox backend rather than string-match a name Codex redacts.'
Assert-True ($doctor -match "'\^\(\?i:disabled\|none\|off\)\$'") 'Doctor must recognize the disabled backend that caused the exec-policy rejection.'
Assert-True ($doctor -match "\`$value -ceq '<redacted>'") 'Doctor must treat the redacted backend name as an enabled backend.'
Assert-True ($doctor -match "\`$windowsSandboxEnabled = \`$sandboxBackendClass -like 'enabled\*'") 'Doctor must gate the Windows sandbox negatively against the disabled backend.'
Assert-True ($doctor -notmatch '\$windowsSandboxEnabled = \$(filesystemSandbox|networkSandbox)') 'Doctor must not gate on policy fields that do not discriminate the backend.'
Assert-True ($doctor -match 'sandbox_backend_class=' -and $doctor -match 'windows_sandbox_enabled=') 'Doctor output must expose the effective Windows sandbox backend class.'
Assert-True ($doctor -match 'filesystem_sandbox=' -and $doctor -match 'network_sandbox=') 'Doctor output must still record the requested sandbox policy fields.'
Assert-True ($doctor -match 'Get-Command codex\.cmd' -and $doctor -match "Kind = 'cmd-shim'") 'Doctor must prefer the npm cmd shim over the known-unsafe PowerShell shim.'
Assert-True ($doctor -match "Kind = 'powershell-shim-fallback'") 'Doctor may retain the PowerShell shim only as a fallback.'
Assert-True (($doctor -split 'codex\.cmd')[0] -notmatch "\`$extension -eq '\.ps1'") 'Doctor must probe the cmd shim before any PowerShell shim branch.'
Assert-True ($doctor -match 'model_inference_used=false') 'N2 doctor must explicitly remain zero-inference.'
Assert-True ($doctor -match 'credential_value_logged=False') 'N2 doctor must make the no-secret-output contract explicit.'

$repoRead = Get-Content -Raw -LiteralPath $repoReadPath
Assert-True ($repoRead -match 'CODEX_NIM_REPO_READ') 'N3 must expose a distinct repo-read result contract.'
Assert-True ($repoRead -match "\$codexArgs = 'exec --json --sandbox read-only -'") 'N3 must add the read-only Codex sandbox to the proven minimal harness.'
Assert-True ($repoRead -match 'harness_mode=repo-read-explicit-tool-contract') 'N3b must identify the explicit tool-contract differential.'
Assert-True ($repoRead -match 'tool_contract=exec_command-use_default-no-justification') 'N3b output must identify the exact command permission contract.'
Assert-True ($repoRead -match 'Use exec_command exactly once') 'N3b must direct the Worker to the intended command tool.'
Assert-True ($repoRead -match 'Get-Content -LiteralPath README\.md -TotalCount 3') 'N3b must use a deterministic read-only README command.'
Assert-True ($repoRead -match 'sandbox_permissions to "use_default"') 'N3b must provide a valid non-escalated sandbox permission value.'
Assert-True ($repoRead -match 'Omit justification, prefix_rule, additional_permissions') 'N3b must remove the invalid permission-argument combination observed in N3a.'
Assert-True ($repoRead -match 'first non-empty line after the top-level heading') 'N3 prompt must require evidence learned from README rather than include the expected content.'
Assert-True ($repoRead -match 'README_TOOL_OK\|Context-aware coding-agent orchestration for Codex\.') 'N3 validator must know the current deterministic README evidence.'
Assert-True ($repoRead -match "item\.type -eq 'command_execution'") 'N3 must require a real Codex command execution event.'
Assert-True ($repoRead -match "item\.command.*README\\\.md|README\\\.md.*item\.command") 'N3 must verify that the tool command references README.md.'
Assert-True ($repoRead -match "item\.status -eq 'completed'" -and $repoRead -match 'item\.exit_code') 'N3 must require the README command to complete successfully.'
Assert-True ($repoRead -match "item\.type -eq 'file_change'") 'N3 must explicitly inspect file-change events.'
Assert-True ($repoRead -match 'status --porcelain=v1 --untracked-files=all') 'N3 must compare the working tree before and after the Worker turn.'
Assert-True ($repoRead -match 'invalid_tool_args_seen=' -and $repoRead -match 'exec_command_failed_seen=' -and $repoRead -match 'exec_policy_blocked_seen=' -and $repoRead -match 'windows_process_failure_seen=') 'N3 must distinguish tool-argument errors, exec-policy rejection, and real Windows command-runner failures.'
Assert-True ($repoRead -match 'tool_argument_error' -and $repoRead -match 'exec_policy_blocked' -and $repoRead -match 'windows_sandbox_process_error') 'N3 failure classifier must preserve distinct compatibility and policy fault classes.'
Assert-True ($repoRead -match '\(-not \$execPolicyBlockedSeen\) -and') 'N3 must not misclassify an exec-policy rejection as a Windows process creation failure.'
Assert-True ($repoRead -match 'working_tree_unchanged=') 'N3 output must expose the working-tree invariant.'
Assert-True ($repoRead -match 'file_change_item_count=') 'N3 output must expose the file-change event invariant.'
Assert-True ($repoRead -match 'tool_use_present=' -and $repoRead -match 'readme_tool_command_succeeded=') 'N3 output must expose observed tool-use evidence.'
Assert-True ($repoRead -match 'Get-Command codex\.cmd' -and $repoRead -match "Kind = 'cmd-shim'") 'N3 must preserve the proven Windows cmd-shim launcher behavior.'
Assert-True ($repoRead -match 'stdout\.Contains\(\$key\)' -and $repoRead -match 'stderr\.Contains\(\$key\)') 'N3 must fail on credential leakage.'
Assert-True ($repoRead -notmatch 'Write-Output[^\r\n]*(\$stdout\b|\$stderr\b|\$key\b)') 'N3 must not print raw process streams or credential values.'
Assert-True ($repoRead -notmatch 'nvapi-[A-Za-z0-9_-]{12,}') 'N3 must not contain a NVIDIA credential literal.'
Assert-True ($repoRead -match 'credential_value_logged=False') 'N3 must make the no-secret-output contract explicit.'

# A custom NIM model is never in Codex's model catalog, so the fallback-metadata
# notice arrives on every turn as an error-typed stream entry. Both live probes
# must separate that notice from a real turn failure, and neither may swallow an
# unrecognized stream error.
foreach ($pair in @(
    @{ Name = 'N2b smoke'; Text = $smoke },
    @{ Name = 'N3 repo-read'; Text = $repoRead }
)) {
    $name = $pair.Name
    $text = $pair.Text
    Assert-True ($text -match 'Get-StreamErrorMessages') "$name must collect stream errors before classifying the turn."
    Assert-True ($text -notmatch "\`$_\.type -eq 'turn\.failed' -or \`$_\.type -eq 'error'") "$name must not treat every error-typed stream entry as a turn failure."
    Assert-True ($text -match "benignStreamErrorPattern = '\(\?i\)model metadata for \.\+ not found'") "$name must recognize only the known fallback-metadata notice as benign."
    Assert-True ($text.Contains('$retryStreamErrorPattern = ''(?i)^\s*reconnecting\b''')) "$name must recognize a recoverable provider reconnect notice."
    Assert-True ($text -match '\$fatalStreamErrors\.Count -gt 0') "$name must still fail the turn on an unrecognized stream error."
    Assert-True ($text -match 'provider_retry_notice_count=' -and $text -match 'provider_model_not_found_seen=') "$name output must expose the provider retry rate and the 404 model-not-found signal."
    Assert-True ($text -match 'provider_retry_summary=\$providerRetrySummary') "$name must report retry notices through the sanitizer."
    Assert-True (@([regex]::Matches($text, 'Write-Output[^\r\n]*\$providerRetryNotices(?!\.Count)')).Count -eq 0) "$name must not print raw retry-notice text."
    Assert-True ($text -match "\`$eventType -like 'item\.\*'" -and $text -match "\`$eventType -eq 'error'") "$name must inspect both the top-level and item-shaped error entries."
    Assert-True ($text -match '\$seenItemIds') "$name must de-duplicate one error item reported on both item.started and item.completed."
    Assert-True ($text -match 'model_metadata_fallback_seen=' -and $text -match 'fatal_stream_error_count=') "$name output must expose the benign/fatal stream-error split."
    Assert-True ($text -match '\$fatalStreamErrorSummary = Get-SafeStderrSummary -CapturedStderr \(\$fatalStreamErrors -join') "$name must report unrecognized stream errors through the sanitizer."
    # Printing the count is safe; interpolating the collected text is not.
    Assert-True (@([regex]::Matches($text, 'Write-Output[^\r\n]*\$fatalStreamErrors(?!\.Count)')).Count -eq 0) "$name must not print raw stream-error text."
    Assert-True (@([regex]::Matches($text, 'Write-Output[^\r\n]*\$streamErrorMessages(?!\.Count)')).Count -eq 0) "$name must not print raw stream-error messages."
}

Write-Output 'PASS Codex NIM N2/N3 harness assets'
exit 0
