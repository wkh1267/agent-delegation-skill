[CmdletBinding()]
param(
    [string]$RuntimeRoot,
    [ValidateRange(10, 120)]
    [int]$TimeoutSeconds = 60
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$expectedLine = 'Context-aware coding-agent orchestration for Codex.'

function Get-CodexLaunchSpec {
    $native = Get-Command codex.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($native) {
        return [pscustomobject]@{ FileName = $native.Source; ArgumentsPrefix = ''; ArgumentsSuffix = ''; Kind = 'native' }
    }

    $cmdShim = Get-Command codex.cmd -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmdShim) {
        $comspec = if ($env:ComSpec) { $env:ComSpec } else { 'cmd.exe' }
        return [pscustomobject]@{
            FileName = $comspec
            ArgumentsPrefix = ('/d /s /c ""' + $cmdShim.Source + '" ')
            ArgumentsSuffix = '"'
            Kind = 'cmd-shim'
        }
    }

    $command = Get-Command codex -CommandType Application, ExternalScript -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $command) { return $null }
    $extension = [IO.Path]::GetExtension([string]$command.Source).ToLowerInvariant()
    if ($extension -eq '.cmd' -or $extension -eq '.bat') {
        $comspec = if ($env:ComSpec) { $env:ComSpec } else { 'cmd.exe' }
        return [pscustomobject]@{
            FileName = $comspec
            ArgumentsPrefix = ('/d /s /c ""' + $command.Source + '" ')
            ArgumentsSuffix = '"'
            Kind = 'cmd-shim'
        }
    }
    if ($extension -eq '.ps1') {
        $powershell = Get-Command powershell.exe -CommandType Application -ErrorAction Stop | Select-Object -First 1
        return [pscustomobject]@{
            FileName = $powershell.Source
            ArgumentsPrefix = ('-NoProfile -ExecutionPolicy Bypass -File "' + $command.Source + '" ')
            ArgumentsSuffix = ''
            Kind = 'powershell-shim-fallback'
        }
    }
    return [pscustomobject]@{ FileName = $command.Source; ArgumentsPrefix = ''; ArgumentsSuffix = ''; Kind = 'application' }
}

function Get-WorkingTreeState {
    $lines = @(& git -C $repoRoot status --porcelain=v1 --untracked-files=all 2>$null)
    return ($lines -join "`n")
}

function Get-SafeTextSummary {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return 'none' }
    $safe = [string]$Text
    $safe = [regex]::Replace($safe, 'https?://\S+', '<url>')
    $safe = [regex]::Replace($safe, '(?i)\b[A-Z]:\\(?:[^\\\s:"<>|]+\\)*[^\\\s:"<>|]*', '<path>')
    $safe = [regex]::Replace($safe, '(?<![A-Za-z0-9_])/(?:[^/\s]+/)+[^\s:;,]+', '<path>')
    $safe = [regex]::Replace($safe, '[\r\n\t]+', ' ')
    $safe = [regex]::Replace($safe, '\s{2,}', ' ').Trim()
    if ($safe.Length -gt 500) { $safe = $safe.Substring(0, 500) + '...' }
    if ([string]::IsNullOrWhiteSpace($safe)) { return 'redacted' }
    return $safe
}

function Invoke-Arm {
    param(
        [Parameter(Mandatory = $true)][string]$PermissionProfile,
        [Parameter(Mandatory = $true)][bool]$UseNoProfile,
        [Parameter(Mandatory = $true)][pscustomobject]$LaunchSpec,
        [Parameter(Mandatory = $true)][string]$CodexHome,
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds
    )

    $profileArg = $PermissionProfile.Replace('"', '""')
    $repoArg = $repoRoot.Replace('"', '""')
    $noProfileArg = if ($UseNoProfile) { ' -NoProfile' } else { '' }
    $codexArgs = 'sandbox -P "' + $profileArg + '" -C "' + $repoArg + '" powershell.exe' + $noProfileArg + ' -Command "Get-Content -LiteralPath README.md -TotalCount 3"'

    $oldCodexHome = $env:CODEX_HOME
    $process = $null
    $stdout = ''
    $stderr = ''
    $timedOut = $false
    $exitCode = $null
    try {
        $env:CODEX_HOME = $CodexHome
        $startInfo = New-Object Diagnostics.ProcessStartInfo
        $startInfo.FileName = $LaunchSpec.FileName
        $startInfo.Arguments = $LaunchSpec.ArgumentsPrefix + $codexArgs + $LaunchSpec.ArgumentsSuffix
        $startInfo.WorkingDirectory = $repoRoot
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true

        $process = New-Object Diagnostics.Process
        $process.StartInfo = $startInfo
        if (-not $process.Start()) { throw 'Codex sandbox process did not start.' }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            $timedOut = $true
            try { & taskkill.exe /PID $process.Id /T /F 1>$null 2>$null } catch {}
            try { $process.WaitForExit(5000) | Out-Null } catch {}
        }
        if ($process.HasExited) { $exitCode = $process.ExitCode }
        try { $stdout = [string]$stdoutTask.Result } catch { $stdout = '' }
        try { $stderr = [string]$stderrTask.Result } catch { $stderr = '' }
    }
    finally {
        if ($null -eq $oldCodexHome) { Remove-Item Env:CODEX_HOME -ErrorAction SilentlyContinue }
        else { $env:CODEX_HOME = $oldCodexHome }
        if ($null -ne $process) { $process.Dispose() }
    }

    [pscustomobject]@{
        TimedOut = $timedOut
        ExitCode = $exitCode
        OutputMatch = $stdout -match [regex]::Escape($expectedLine)
        BlockedByPolicy = $stderr -match '(?i)blocked by policy'
        CreateProcessFailure = $stderr -match '(?i)(CreateProcess|CreateProcessAsUserW|Failed to create|process failed|helper[_ -].*error)'
        StderrPresent = -not [string]::IsNullOrWhiteSpace($stderr)
        StderrSummary = Get-SafeTextSummary -Text $stderr
    }
}

if ([string]::IsNullOrWhiteSpace($RuntimeRoot)) {
    if ($env:LOCALAPPDATA) { $RuntimeRoot = Join-Path $env:LOCALAPPDATA 'agent-delegation-skills\codex-nim' }
    else { $RuntimeRoot = Join-Path ([IO.Path]::GetTempPath()) 'agent-delegation-skills\codex-nim' }
}

$launchSpec = Get-CodexLaunchSpec
if ($null -eq $launchSpec) {
    Write-Output 'CODEX_POWERSHELL_PROFILE_GAP'
    Write-Output 'codex_found=False'
    Write-Output 'overall=FAIL'
    Write-Output 'model_inference_used=false'
    Write-Output 'credential_required=false'
    exit 1
}

$codexCommand = Get-Command codex -CommandType Application, ExternalScript -ErrorAction SilentlyContinue | Select-Object -First 1
$codexVersion = (& $codexCommand.Source --version 2>$null | Select-Object -First 1)
if ([string]::IsNullOrWhiteSpace([string]$codexVersion)) { $codexVersion = 'unknown' }

& (Join-Path $PSScriptRoot 'setup-codex-nim.ps1') -RuntimeRoot $RuntimeRoot | Out-Null
$codexHome = Join-Path $RuntimeRoot 'codex-home'
$beforeTree = Get-WorkingTreeState

$readOnlyNoProfile = Invoke-Arm -PermissionProfile ':read-only' -UseNoProfile $true -LaunchSpec $launchSpec -CodexHome $codexHome -TimeoutSeconds $TimeoutSeconds
$readOnlyAgentShape = Invoke-Arm -PermissionProfile ':read-only' -UseNoProfile $false -LaunchSpec $launchSpec -CodexHome $codexHome -TimeoutSeconds $TimeoutSeconds
$fullAccessAgentShape = Invoke-Arm -PermissionProfile ':danger-full-access' -UseNoProfile $false -LaunchSpec $launchSpec -CodexHome $codexHome -TimeoutSeconds $TimeoutSeconds

$afterTree = Get-WorkingTreeState
$workingTreeUnchanged = $beforeTree -ceq $afterTree

function ExitText($Arm) { if ($null -eq $Arm.ExitCode) { 'none' } else { [string]$Arm.ExitCode } }

$referencePass = (-not $readOnlyNoProfile.TimedOut) -and $readOnlyNoProfile.ExitCode -eq 0 -and $readOnlyNoProfile.OutputMatch
$controlPass = (-not $fullAccessAgentShape.TimedOut) -and $fullAccessAgentShape.ExitCode -eq 0 -and $fullAccessAgentShape.OutputMatch
$agentShapePass = (-not $readOnlyAgentShape.TimedOut) -and $readOnlyAgentShape.ExitCode -eq 0 -and $readOnlyAgentShape.OutputMatch
$differential = if ($referencePass -and $controlPass -and -not $agentShapePass -and $readOnlyAgentShape.BlockedByPolicy) {
    'NOPROFILE_GAP_CONFIRMED'
} elseif ($referencePass -and $controlPass -and $agentShapePass) {
    'DIRECT_AGENT_SHAPE_HEALTHY'
} else {
    'INCONCLUSIVE'
}
$overallPass = $referencePass -and $controlPass -and $workingTreeUnchanged

Write-Output 'CODEX_POWERSHELL_PROFILE_GAP'
Write-Output "codex_version=$([string]$codexVersion)"
Write-Output "codex_launcher=$($launchSpec.Kind)"
Write-Output "codex_home=$codexHome"
Write-Output 'command=Get-Content-README-read-only'
Write-Output 'reference_profile=:read-only'
Write-Output 'reference_no_profile=True'
Write-Output "reference_exit_code=$(ExitText $readOnlyNoProfile)"
Write-Output "reference_output_match=$([bool]$readOnlyNoProfile.OutputMatch)"
Write-Output "reference_blocked_by_policy=$([bool]$readOnlyNoProfile.BlockedByPolicy)"
Write-Output "reference_stderr_summary=$($readOnlyNoProfile.StderrSummary)"
Write-Output 'agent_shape_profile=:read-only'
Write-Output 'agent_shape_no_profile=False'
Write-Output "agent_shape_exit_code=$(ExitText $readOnlyAgentShape)"
Write-Output "agent_shape_output_match=$([bool]$readOnlyAgentShape.OutputMatch)"
Write-Output "agent_shape_blocked_by_policy=$([bool]$readOnlyAgentShape.BlockedByPolicy)"
Write-Output "agent_shape_create_process_failure=$([bool]$readOnlyAgentShape.CreateProcessFailure)"
Write-Output "agent_shape_stderr_summary=$($readOnlyAgentShape.StderrSummary)"
Write-Output 'control_profile=:danger-full-access'
Write-Output 'control_no_profile=False'
Write-Output "control_exit_code=$(ExitText $fullAccessAgentShape)"
Write-Output "control_output_match=$([bool]$fullAccessAgentShape.OutputMatch)"
Write-Output "control_blocked_by_policy=$([bool]$fullAccessAgentShape.BlockedByPolicy)"
Write-Output "control_stderr_summary=$($fullAccessAgentShape.StderrSummary)"
Write-Output "working_tree_unchanged=$([bool]$workingTreeUnchanged)"
Write-Output "profile_gap_differential=$differential"
Write-Output "overall=$(if ($overallPass) { 'PASS' } else { 'FAIL' })"
Write-Output 'model_inference_used=false'
Write-Output 'credential_required=false'

if ($overallPass) { exit 0 }
exit 1
