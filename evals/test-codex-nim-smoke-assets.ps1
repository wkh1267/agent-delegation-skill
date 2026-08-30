$ErrorActionPreference = 'Stop'
$smokePath = Join-Path $PSScriptRoot 'run-codex-nim-smoke.ps1'
$doctorPath = Join-Path $PSScriptRoot 'diagnose-codex-nim-doctor.ps1'

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message = 'Assertion failed.'
    )
    if (-not $Condition) { throw $Message }
}

foreach ($path in @($smokePath, $doctorPath)) {
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
    Assert-True ($errors.Count -eq 0) "PowerShell parser errors in $path"
}

$smoke = Get-Content -Raw -LiteralPath $smokePath
Assert-True ($smoke -match 'CODEX_HOME') 'N2 smoke must use isolated CODEX_HOME.'
Assert-True ($smoke -match 'setup-codex-nim\.ps1') 'N2 smoke must regenerate the isolated NIM Worker config.'
Assert-True ($smoke -match 'config_mode=isolated-default') 'N2 smoke output must identify the dedicated isolated config mode.'
Assert-True ($smoke -notmatch '-p nim-worker') 'N2 smoke must not depend on a profile inside the dedicated Worker CODEX_HOME.'
Assert-True ($smoke -match 'exec --strict-config --ephemeral --json --sandbox read-only --ignore-rules -') 'N2 smoke must use the bounded read-only ephemeral JSONL Codex exec surface.'
Assert-True ($smoke -match 'Reply with exactly WORKER_OK\.') 'N2 smoke must use the deterministic WORKER_OK task.'
Assert-True ($smoke -match "type -eq 'thread\.started'") 'N2 smoke must require a thread.started event.'
Assert-True ($smoke -match "type -eq 'turn\.completed'") 'N2 smoke must require turn completion.'
Assert-True ($smoke -match "item\.type -eq 'agent_message'") 'N2 smoke must inspect the completed agent message.'
Assert-True ($smoke -match "-ceq 'WORKER_OK'") 'N2 smoke must require the exact final message.'
Assert-True ($smoke -match 'ReadToEndAsync') 'N2 smoke must drain stdout and stderr without pipe deadlock.'
Assert-True ($smoke -match 'taskkill\.exe /PID \$process\.Id /T /F') 'N2 smoke must bound and clean up the Codex process tree.'
Assert-True ($smoke -match "extension -eq '\.ps1'" -and $smoke -match "extension -eq '\.cmd'") 'N2 smoke must support Windows Codex shims as well as native executables.'
Assert-True ($smoke -match 'app_server_init_error') 'N2 smoke must classify in-process app-server startup failures.'
Assert-True ($smoke -match 'Get-SafeFailureClass' -and $smoke -match 'failure_class=') 'N2 smoke must classify pre-thread failures without printing raw stderr.'
Assert-True ($smoke -match 'stdout\.Contains\(\$key\)' -and $smoke -match 'stderr\.Contains\(\$key\)') 'N2 smoke must fail if the credential appears in captured process output.'
Assert-True ($smoke -notmatch 'Write-Output[^\r\n]*(\$stdout\b|\$stderr\b|\$key\b)') 'N2 smoke must not print raw process streams or credential values.'
Assert-True ($smoke -notmatch 'nvapi-[A-Za-z0-9_-]+') 'N2 smoke must not contain a NVIDIA credential literal.'
Assert-True ($smoke -match 'credential_value_logged=False') 'N2 smoke must make the no-secret-output contract explicit.'

$doctor = Get-Content -Raw -LiteralPath $doctorPath
Assert-True ($doctor -match 'setup-codex-nim\.ps1') 'N2 doctor must use the same isolated NIM Worker config setup.'
Assert-True ($doctor -match "ArgumentsPrefix \+ 'doctor --json'") 'N2 doctor must inspect the dedicated Worker config without a profile.'
Assert-True ($doctor -notmatch '-p nim-worker doctor') 'N2 doctor must not use --profile because doctor is not a profile-capable runtime command.'
Assert-True ($doctor -match "'config\.load'") 'N2 doctor must inspect config.load.'
Assert-True ($doctor -match "'auth\.credentials'") 'N2 doctor must inspect auth.credentials.'
Assert-True ($doctor -match "'network\.provider_reachability'") 'N2 doctor must inspect provider reachability.'
Assert-True ($doctor -match "activeProvider -ceq 'nim'") 'N2 doctor must require the NIM provider.'
Assert-True ($doctor -match "expectedModel = 'nvidia/nemotron-3-super-120b-a12b'") 'N2 doctor must require the intended Nemotron model.'
Assert-True ($doctor -match 'model_inference_used=false') 'N2 doctor must explicitly remain zero-inference.'
Assert-True ($doctor -match 'ReadToEndAsync') 'N2 doctor must capture native stdout/stderr without PowerShell NativeCommandError leakage.'
Assert-True ($doctor -match 'doctorStdout\.Contains\(\$key\)' -and $doctor -match 'doctorStderr\.Contains\(\$key\)') 'N2 doctor must detect credential leakage in captured streams.'
Assert-True ($doctor -notmatch 'Write-Output\s+(?:"?\$doctorStdout\b|"?\$doctorStderr\b|"?\$key\b)') 'N2 doctor must not directly print raw doctor streams or credential values.'
Assert-True ($doctor -notmatch 'nvapi-[A-Za-z0-9_-]+') 'N2 doctor must not contain a NVIDIA credential literal.'
Assert-True ($doctor -match 'credential_value_logged=False') 'N2 doctor must make the no-secret-output contract explicit.'

Write-Output 'PASS Codex NIM N2 smoke and doctor assets'
exit 0
