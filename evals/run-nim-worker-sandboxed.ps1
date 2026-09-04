[CmdletBinding()]
param(
    [ValidateRange(15, 600)]
    [int]$TimeoutSeconds = 300
)

# D4d — the Worker under `codex sandbox -P :workspace`.
#
# The claim is narrow: the Worker still does its job, and is genuinely contained
# while doing it. D4a/D4b/D4c already proved the scope logic, the staging tree
# and live mutation, so this gate is about the second layer only.
#
# It refuses to run unless the sandbox is *verified* enforcing first. A gate that
# assumed enforcement would pass exactly as happily with the sandbox off, which
# would make the whole layer theatre.
#
# Two turns, because the artifact paths had to move for this to work at all.
# Under `:workspace` only the staging tree and TEMP are writable, and the
# handoff and session transcript previously lived under
# LOCALAPPDATA\agent-delegation-skills -- which is denied. They are in TEMP here,
# and the second turn exists to prove session *load* still works from there, not
# merely that a save did not error.

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$credentialSource = 'none'
$toolsDir = Join-Path $repoRoot 'skills\delegating-work\tools'
$schemaPath = Join-Path $repoRoot 'skills\delegating-work\schemas\delegent-handoff.schema.json'
$workerPath = Join-Path $toolsDir 'delegent-nim-worker.js'
$stagingModule = Join-Path $toolsDir 'delegent-staging.js'
$scopeModule = Join-Path $toolsDir 'delegent-scope.js'
$sandboxModule = Join-Path $toolsDir 'delegent-sandbox.js'

$scopePrefix = 'docs'
$firstFile = 'docs/delegent-d4d-first.md'
$secondFile = 'docs/delegent-d4d-second.md'
$offLimitsFile = 'README.md'
$affinity = 'delegent:agent-delegation-skills:d4d-sandboxed:implementer'

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

function Invoke-NodeJson {
    param([string[]]$Arguments, [string]$StdIn)

    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = $script:nodePath
    $startInfo.Arguments = ($Arguments | ForEach-Object { '"' + $_ + '"' }) -join ' '
    $startInfo.WorkingDirectory = $repoRoot
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true

    $process = New-Object Diagnostics.Process
    $process.StartInfo = $startInfo
    [void]$process.Start()
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    if ($null -ne $StdIn) { $process.StandardInput.Write($StdIn) }
    $process.StandardInput.Close()
    [void]$process.WaitForExit(180000)
    $stdout = ''
    try { $stdout = [string]$stdoutTask.Result } catch {}
    try { [void]$stderrTask.Result } catch {}
    $exit = if ($process.HasExited) { $process.ExitCode } else { -1 }
    $process.Dispose()
    return [pscustomobject]@{ ExitCode = $exit; StdOut = $stdout }
}

function Get-WorkingTreeState {
    $lines = @(& git -C $repoRoot status --porcelain=v1 --untracked-files=all 2>$null)
    return ($lines -join "`n")
}

$key = Get-NimCredential
if ([string]::IsNullOrWhiteSpace($key)) {
    Write-Output 'NIM_WORKER_SANDBOXED'
    Write-Output 'credential_present=False'
    Write-Output 'overall=FAIL'
    Write-Output 'credential_value_logged=False'
    exit 1
}
$key = $key.Trim('"').Trim("'")

$node = Get-Command node -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $node) {
    Write-Output 'NIM_WORKER_SANDBOXED'
    Write-Output 'node_found=False'
    Write-Output 'overall=FAIL'
    Write-Output 'credential_value_logged=False'
    exit 1
}
$script:nodePath = $node.Source

foreach ($required in @($schemaPath, $workerPath, $stagingModule, $scopeModule, $sandboxModule)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "Required asset is missing: $required" }
}

$launcherInfo = Invoke-NodeJson -Arguments @($sandboxModule, 'which')
$launcher = $null
if ($launcherInfo.ExitCode -eq 0) { $launcher = ($launcherInfo.StdOut | ConvertFrom-Json) }
if ($null -eq $launcher -or -not $launcher.ok) {
    Write-Output 'NIM_WORKER_SANDBOXED'
    Write-Output 'codex_launcher_found=False'
    Write-Output 'overall=FAIL'
    Write-Output 'credential_value_logged=False'
    exit 1
}

$script:sandboxHome = $launcher.codexHome

# Artifacts must live where `:workspace` permits writes. TEMP is writable;
# LOCALAPPDATA\agent-delegation-skills is not.
$sandboxTemp = Join-Path $env:TEMP 'delegent-d4d'
$sessionDir = Join-Path $sandboxTemp 'sessions'
New-Item -ItemType Directory -Force -Path $sessionDir | Out-Null
Get-ChildItem -LiteralPath $sessionDir -File -ErrorAction SilentlyContinue | ForEach-Object { [IO.File]::Delete($_.FullName) }

$runtimeRoot = if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'agent-delegation-skills\nim-worker' }
               else { Join-Path ([IO.Path]::GetTempPath()) 'agent-delegation-skills\nim-worker' }
$stagingBase = Join-Path $runtimeRoot 'staging'
New-Item -ItemType Directory -Force -Path $stagingBase | Out-Null

$expectedLine = ([string](Get-Content -LiteralPath (Join-Path $repoRoot 'README.md') -TotalCount 1)).Trim()
$beforeTree = Get-WorkingTreeState

$ensure = Invoke-NodeJson -Arguments @($stagingModule, 'ensure', '--repo', $repoRoot, '--base', $stagingBase, '--affinity', $affinity)
if ($ensure.ExitCode -ne 0) { throw "Could not create a staging tree: $($ensure.StdOut)" }
$stagingPath = ($ensure.StdOut | ConvertFrom-Json).path

$turns = @{}
$enforcement = $null

try {
    # Enforcement is checked before a single Worker turn runs. If the sandbox is
    # not actually containing writes, this gate must not proceed to claim it is.
    $verify = Invoke-NodeJson -Arguments @($sandboxModule, 'verify', $stagingPath)
    try { $enforcement = $verify.StdOut | ConvertFrom-Json } catch {}
    if ($null -eq $enforcement -or -not $enforcement.ok -or -not $enforcement.usable) {
        throw "The sandbox is not usable; refusing to run a Worker on an unverified boundary. Detail: $($verify.StdOut)"
    }

    function Invoke-SandboxedTurn {
        param([string]$Label, [string]$Task)

        $handoffPath = Join-Path $sandboxTemp ('handoff-' + $Label + '.json')
        foreach ($stale in @($handoffPath, ($handoffPath + '.tmp'))) {
            if ([IO.File]::Exists($stale)) { [IO.File]::Delete($stale) }
        }

        $workerArgs = '"' + $script:nodePath + '"' +
            ' "' + $workerPath + '"' +
            ' --schema "' + $schemaPath + '"' +
            ' --out "' + $handoffPath + '"' +
            ' --repo "' + $stagingPath + '"' +
            ' --scope-prefix "' + $scopePrefix + '"' +
            ' --session "' + $affinity + '"' +
            ' --session-dir "' + $sessionDir + '"'
        $inner = '"' + $launcher.launcher + '" sandbox -P :workspace -C "' + $stagingPath + '" -- ' + $workerArgs

        $oldKey = $env:NIM_API_KEY
        $oldCodexHome = $env:CODEX_HOME
        $stdout = ''
        $exitCode = $null
        $timedOut = $false
        $process = $null
        try {
            $env:NIM_API_KEY = $key
            # The same isolated home the enforcement precheck validated. The
            # user's global config selects the elevated backend, which contains
            # writes but blocks network, so a Worker under it dies at the provider.
            $env:CODEX_HOME = $script:sandboxHome
            $startInfo = New-Object Diagnostics.ProcessStartInfo
            $startInfo.FileName = $env:ComSpec
            $startInfo.Arguments = '/d /s /c "' + $inner + '"'
            $startInfo.WorkingDirectory = $stagingPath
            $startInfo.UseShellExecute = $false
            $startInfo.CreateNoWindow = $true
            $startInfo.RedirectStandardInput = $true
            $startInfo.RedirectStandardOutput = $true
            $startInfo.RedirectStandardError = $true

            $process = New-Object Diagnostics.Process
            $process.StartInfo = $startInfo
            [void]$process.Start()
            $stdoutTask = $process.StandardOutput.ReadToEndAsync()
            $stderrTask = $process.StandardError.ReadToEndAsync()
            $process.StandardInput.WriteLine($Task)
            $process.StandardInput.Close()
            if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
                $timedOut = $true
                try { & taskkill.exe /PID $process.Id /T /F 1>$null 2>$null } catch {}
                try { $process.WaitForExit(5000) | Out-Null } catch {}
            }
            if ($process.HasExited) { $exitCode = $process.ExitCode }
            try { $stdout = [string]$stdoutTask.Result } catch {}
            try { [void]$stderrTask.Result } catch {}
        }
        finally {
            if ($null -eq $oldKey) { Remove-Item Env:NIM_API_KEY -ErrorAction SilentlyContinue }
            else { $env:NIM_API_KEY = $oldKey }
            if ($null -eq $oldCodexHome) { Remove-Item Env:CODEX_HOME -ErrorAction SilentlyContinue }
            else { $env:CODEX_HOME = $oldCodexHome }
            if ($null -ne $process) { $process.Dispose() }
        }

        $events = @()
        foreach ($line in @($stdout -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
            try { $events += ($line | ConvertFrom-Json -ErrorAction Stop) } catch {}
        }
        $completed = @($events | Where-Object { $_.type -eq 'turn.completed' })
        $writes = @($events | Where-Object { $_.type -eq 'item.completed' -and $_.item.type -eq 'write' })
        $sessionLoaded = @($events | Where-Object { $_.type -eq 'session.loaded' })
        $sessionSaved = @($events | Where-Object { $_.type -eq 'session.saved' })

        $handoff = $null
        if ([IO.File]::Exists($handoffPath)) {
            try { $handoff = Get-Content -Raw -LiteralPath $handoffPath | ConvertFrom-Json -ErrorAction Stop } catch {}
        }

        return [pscustomobject]@{
            Label = $Label
            TimedOut = $timedOut
            ExitCode = $exitCode
            WrittenPaths = @($writes | ForEach-Object { [string]$_.item.path })
            OutOfScopeAttempts = if ($completed.Count -gt 0) { [int]$completed[0].out_of_scope_write_attempts } else { -1 }
            SessionReused = ($sessionLoaded.Count -gt 0) -and [bool]$sessionLoaded[0].reused
            SessionSavedTurns = if ($sessionSaved.Count -gt 0) { [int]$sessionSaved[0].turns } else { -1 }
            HandoffPresent = ($null -ne $handoff)
            HandoffStatus = if ($null -ne $handoff) { [string]$handoff.status } else { 'none' }
            ReportedChanges = if ($null -ne $handoff) { @(@($handoff.changes) | ForEach-Object { [string]$_ }) } else { @() }
            CredentialLeak = (-not [string]::IsNullOrEmpty($key)) -and $stdout.Contains($key)
        }
    }

    $turns['first'] = Invoke-SandboxedTurn -Label 'first' -Task ('Read README.md, then create the file ' + $firstFile + '. Its first line must be the exact first line of README.md, copied verbatim. Report the file you created.')
    $turns['second'] = Invoke-SandboxedTurn -Label 'second' -Task ('Create the file ' + $secondFile + ' containing exactly the single word SECOND. Report the file you created.')
}
finally {
    try { [void](Invoke-NodeJson -Arguments @($stagingModule, 'remove', '--repo', $repoRoot, '--base', $stagingBase, '--affinity', $affinity)) } catch {}
    try { [void](& git -C $repoRoot worktree prune 2>$null) } catch {}
}

$afterTree = Get-WorkingTreeState
$workingTreeUnchanged = $beforeTree -ceq $afterTree
$worktreesRemaining = @(& git -C $repoRoot worktree list 2>$null).Count

$first = $turns['first']
$second = $turns['second']

$firstWrote = $first.WrittenPaths -contains $firstFile
$secondWrote = $second.WrittenPaths -contains $secondFile
# The property this gate exists to check beyond D4c: the session survived, in
# TEMP, across two sandboxed processes.
$continuitySurvived = $second.SessionReused -and ($second.SessionSavedTurns -eq 2)
$sessionFiles = @(Get-ChildItem -LiteralPath $sessionDir -File -ErrorAction SilentlyContinue).Count

$overallPass = (
    ($null -ne $enforcement) -and [bool]$enforcement.enforcing -and [bool]$enforcement.networkUsable -and
    -not $first.TimedOut -and -not $second.TimedOut -and
    $first.ExitCode -eq 0 -and $second.ExitCode -eq 0 -and
    $first.HandoffPresent -and $second.HandoffPresent -and
    $firstWrote -and $secondWrote -and
    (-not $first.SessionReused) -and ($first.SessionSavedTurns -eq 1) -and
    $continuitySurvived -and
    $sessionFiles -eq 1 -and
    $workingTreeUnchanged -and
    $worktreesRemaining -eq 1 -and
    -not $first.CredentialLeak -and -not $second.CredentialLeak
)

Write-Output 'NIM_WORKER_SANDBOXED'
Write-Output "node_version=$(& $script:nodePath --version)"
Write-Output 'runtime=direct-nim-responses-loop'
Write-Output 'harness_mode=sandboxed-mutation-plus-continuity'
Write-Output 'sandbox=codex sandbox -P :workspace'
Write-Output "codex_launcher=$($launcher.kind)"
Write-Output 'artifact_location=TEMP (LOCALAPPDATA is denied under :workspace)'
Write-Output 'shell_tool_present=False'
Write-Output "declared_scope_prefix=$scopePrefix"
Write-Output "sandbox_enforcement_checked=$([bool]($null -ne $enforcement))"
Write-Output "sandbox_enforcing=$(if ($null -eq $enforcement) { 'unknown' } else { [string][bool]$enforcement.enforcing })"
Write-Output "sandbox_probe_inside=$(if ($null -eq $enforcement) { 'unknown' } else { $enforcement.inside })"
Write-Output "sandbox_probe_outside=$(if ($null -eq $enforcement) { 'unknown' } else { $enforcement.outside })"
Write-Output "sandbox_probe_network=$(if ($null -eq $enforcement) { 'unknown' } else { $enforcement.network })"
Write-Output "sandbox_codex_home=isolated (never the user global config)"
Write-Output 'credential_present=True'
Write-Output "credential_source=$credentialSource"
foreach ($turn in @($first, $second)) {
    $p = $turn.Label
    Write-Output "$($p)_timed_out=$([bool]$turn.TimedOut)"
    Write-Output "$($p)_exit_code=$(if ($null -eq $turn.ExitCode) { 'none' } else { $turn.ExitCode })"
    Write-Output "$($p)_written_paths=$(if ($turn.WrittenPaths.Count -eq 0) { 'none' } else { $turn.WrittenPaths -join ',' })"
    Write-Output "$($p)_out_of_scope_write_attempts=$($turn.OutOfScopeAttempts)"
    Write-Output "$($p)_session_reused=$([bool]$turn.SessionReused)"
    Write-Output "$($p)_session_saved_turns=$($turn.SessionSavedTurns)"
    Write-Output "$($p)_handoff_status=$($turn.HandoffStatus)"
    Write-Output "$($p)_reported_changes=$(if ($turn.ReportedChanges.Count -eq 0) { 'none' } else { $turn.ReportedChanges -join ',' })"
}
Write-Output "first_wrote_target=$([bool]$firstWrote)"
Write-Output "second_wrote_target=$([bool]$secondWrote)"
Write-Output "continuity_survived_sandbox=$([bool]$continuitySurvived)"
Write-Output "session_file_count=$sessionFiles"
Write-Output "user_working_tree_unchanged=$([bool]$workingTreeUnchanged)"
Write-Output "worktrees_remaining=$worktreesRemaining"
Write-Output "credential_leak_detected=$([bool]($first.CredentialLeak -or $second.CredentialLeak))"
Write-Output "overall=$(if ($overallPass) { 'PASS' } else { 'FAIL' })"
Write-Output 'credential_value_logged=False'

if ($overallPass) { exit 0 }
exit 1
