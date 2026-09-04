$ErrorActionPreference = 'Stop'

# Behavioural test for the stream-error classifier shared by the two live
# Codex/NIM probes. The other Codex/NIM asset tests assert script *shape*; this
# one runs the real classifier over synthetic JSONL streams, including negative
# controls, so a benign-notice tolerance can never quietly become a gate that
# passes on real failures.
#
# The function under test is extracted verbatim from the shipping probe rather
# than re-typed here, so the test cannot drift away from what actually runs.

$smokePath = Join-Path $PSScriptRoot 'run-codex-nim-smoke.ps1'
$repoReadPath = Join-Path $PSScriptRoot 'run-codex-nim-repo-read.ps1'

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message = 'Assertion failed.'
    )
    if (-not $Condition) { throw $Message }
}

function Get-ExtractedFunction {
    param(
        [string]$Path,
        [string]$Name
    )
    $source = Get-Content -Raw -LiteralPath $Path
    $match = [regex]::Match($source, '(?s)function ' + [regex]::Escape($Name) + ' \{.*?\r?\n\}')
    Assert-True $match.Success "Could not extract $Name from $Path."
    return $match.Value
}

$repoReadFunction = Get-ExtractedFunction -Path $repoReadPath -Name 'Get-StreamErrorMessages'
$smokeFunction = Get-ExtractedFunction -Path $smokePath -Name 'Get-StreamErrorMessages'

# Both probes must classify identically; a divergence would make one gate
# stricter than the other for the same runtime.
$normalize = { param([string]$Text) ($Text -replace '\r\n', "`n").Trim() }
Assert-True ((& $normalize $repoReadFunction) -ceq (& $normalize $smokeFunction)) 'Both live probes must share an identical Get-StreamErrorMessages implementation.'

Invoke-Expression $repoReadFunction

# Kept in step with both probes by the assertions below.
$benignStreamErrorPattern = '(?i)model metadata for .+ not found'
$retryStreamErrorPattern = '(?i)^\s*reconnecting\b'

foreach ($path in @($repoReadPath, $smokePath)) {
    $source = Get-Content -Raw -LiteralPath $path
    Assert-True ($source.Contains("`$benignStreamErrorPattern = '$benignStreamErrorPattern'")) "$path must use the benign pattern this test verifies."
    Assert-True ($source.Contains("`$retryStreamErrorPattern = '$retryStreamErrorPattern'")) "$path must use the retry pattern this test verifies."
}

function Get-Classification {
    param([object[]]$Events)

    $all = @(Get-StreamErrorMessages -Events $Events)
    $unexpected = @($all | Where-Object { $_ -notmatch $benignStreamErrorPattern })
    $retries = @($unexpected | Where-Object { $_ -match $retryStreamErrorPattern })
    $fatal = @($unexpected | Where-Object { $_ -notmatch $retryStreamErrorPattern })
    $turnFailedEvent = @($Events | Where-Object { $_.type -eq 'turn.failed' }).Count -gt 0

    [pscustomobject]@{
        Benign = @($all | Where-Object { $_ -match $benignStreamErrorPattern }).Count
        Retries = $retries.Count
        ModelNotFound = @($retries | Where-Object { $_ -match '(?i)\bmodel not found\b' }).Count -gt 0
        Fatal = $fatal.Count
        TurnFailed = $turnFailedEvent -or ($fatal.Count -gt 0)
    }
}

function New-Event {
    param([string]$Json)
    return ($Json | ConvertFrom-Json)
}

$cases = @(
    @{
        # The stream observed in the passing 2026-09-03 N3 run.
        Name = 'fallback-metadata notice only does not fail the turn'
        Events = @(
            (New-Event '{"type":"thread.started","thread_id":"t1"}'),
            (New-Event '{"type":"item.completed","item":{"id":"item_0","type":"error","message":"Model metadata for `nvidia/nemotron-3-super-120b-a12b` not found. Defaulting to fallback metadata; this can degrade performance and cause issues."}}'),
            (New-Event '{"type":"turn.completed"}')
        )
        Benign = 1; Retries = 0; ModelNotFound = $false; Fatal = 0; TurnFailed = $false
    },
    @{
        # The stream observed in the retrying 2026-09-03 N2b run.
        Name = 'recoverable provider retries are surfaced but do not fail the turn'
        Events = @(
            (New-Event '{"type":"item.completed","item":{"id":"item_0","type":"error","message":"Model metadata for `x` not found. Defaulting to fallback metadata"}}'),
            (New-Event '{"type":"error","message":"Reconnecting... 1/5 (stream disconnected before completion: response.failed event received)"}'),
            (New-Event '{"type":"error","message":"Reconnecting... 2/5 (unexpected status 404 Not Found: Model not found)"}'),
            (New-Event '{"type":"error","message":"Reconnecting... 3/5 (unexpected status 404 Not Found: Model not found)"}'),
            (New-Event '{"type":"error","message":"Reconnecting... 4/5 (stream disconnected before completion: response.failed event received)"}'),
            (New-Event '{"type":"turn.completed"}')
        )
        Benign = 1; Retries = 4; ModelNotFound = $true; Fatal = 0; TurnFailed = $false
    },
    @{
        # Negative control: tolerating known notices must not tolerate anything else.
        Name = 'unrecognized stream error still fails the turn'
        Events = @(
            (New-Event '{"type":"item.completed","item":{"id":"item_0","type":"error","message":"Model metadata for `x` not found. Defaulting to fallback metadata"}}'),
            (New-Event '{"type":"error","message":"401 Unauthorized: invalid credentials"}'),
            (New-Event '{"type":"turn.completed"}')
        )
        Benign = 1; Retries = 0; ModelNotFound = $false; Fatal = 1; TurnFailed = $true
    },
    @{
        # Negative control: an explicit turn.failed must fail even on a clean stream.
        Name = 'explicit turn.failed still fails the turn'
        Events = @(
            (New-Event '{"type":"turn.failed","error":{"message":"nope"}}')
        )
        Benign = 0; Retries = 0; ModelNotFound = $false; Fatal = 0; TurnFailed = $true
    },
    @{
        Name = 'one error item on both item.started and item.completed counts once'
        Events = @(
            (New-Event '{"type":"item.started","item":{"id":"item_7","type":"error","message":"Totally unknown failure"}}'),
            (New-Event '{"type":"item.completed","item":{"id":"item_7","type":"error","message":"Totally unknown failure"}}')
        )
        Benign = 0; Retries = 0; ModelNotFound = $false; Fatal = 1; TurnFailed = $true
    },
    @{
        Name = 'top-level error text under the error field is still classified'
        Events = @(
            (New-Event '{"type":"error","error":"Some unrecognized provider fault"}')
        )
        Benign = 0; Retries = 0; ModelNotFound = $false; Fatal = 1; TurnFailed = $true
    },
    @{
        Name = 'a clean stream reports nothing'
        Events = @(
            (New-Event '{"type":"thread.started","thread_id":"t1"}'),
            (New-Event '{"type":"item.completed","item":{"id":"item_1","type":"command_execution","status":"completed","exit_code":0}}'),
            (New-Event '{"type":"turn.completed"}')
        )
        Benign = 0; Retries = 0; ModelNotFound = $false; Fatal = 0; TurnFailed = $false
    }
)

$checked = 0
foreach ($case in $cases) {
    $result = Get-Classification -Events $case.Events
    foreach ($field in @('Benign', 'Retries', 'ModelNotFound', 'Fatal', 'TurnFailed')) {
        Assert-True ($result.$field -eq $case.$field) ("$($case.Name): $field expected $($case.$field) but got $($result.$field).")
        $checked++
    }
}

Write-Output "PASS Codex NIM stream-error classifier $($cases.Count)/$($cases.Count) cases, $checked assertions"
exit 0
