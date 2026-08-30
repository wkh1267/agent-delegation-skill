$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$protocolPath = Join-Path $repoRoot 'skills\delegating-work\scripts\worker-protocol.ps1'
$wrapperPath = Join-Path $repoRoot 'skills\delegating-work\scripts\nemotron-worker.ps1'
$credentialPath = Join-Path $repoRoot 'skills\delegating-work\.env'
. $protocolPath

function Assert-True {
    param([bool]$Condition)
    if (-not $Condition) { throw 'Assertion failed.' }
}

function New-NormalResult {
    [ordered]@{
        status = 'completed'
        summary = 'done'
        evidence = 'focused evidence'
        changes = 'none'
        tests = 'passed'
        risks = 'none'
        decisions_needed = 'none'
        review_targets = 'adapter'
    }
}

function New-ResponseJson {
    param([object]$StructuredOutput, [object[]]$Parts = @())
    @{ info = @{ id = 'msg_new'; role = 'assistant'; structured = $StructuredOutput }; parts = $Parts } |
        ConvertTo-Json -Depth 12 -Compress
}

function New-FakeRequest {
    param([hashtable]$Routes)
    $queues = @{}
    foreach ($key in $Routes.Keys) {
        $queue = New-Object Collections.Queue
        foreach ($item in @($Routes[$key])) { $queue.Enqueue($item) }
        $queues[$key] = $queue
    }
    {
        param($Method, $Path, $BodyJson, $TimeoutSeconds)
        $key = "$Method $Path"
        if (-not $queues.ContainsKey($key) -or $queues[$key].Count -eq 0) { throw 'Unexpected fake request.' }
        $item = $queues[$key].Dequeue()
        if ($item -is [scriptblock]) { return & $item $Method $Path $BodyJson $TimeoutSeconds }
        return [string]$item
    }.GetNewClosure()
}

$tests = [ordered]@{}

$tests['valid eight-field handoff'] = {
    $request = New-FakeRequest @{ 'GET /session/ses_valid/message' = @('[]'); 'POST /session/ses_valid/message' = @(New-ResponseJson (New-NormalResult)) }
    $result = Invoke-DelegentWorkerProtocol ([pscustomobject]@{ Session = 'ses_valid'; Title = $null; Agent = 'plan'; Dir = $null; Prompt = 'task' }) $request
    Assert-True ($result.ExitCode -eq 0 -and $result.Output -match '^STATUS: completed' -and $result.Output -notmatch 'WORKER_PROTOCOL_ERROR')
}

$tests['valid hard escalation'] = {
    $decision = [ordered]@{ kind = 'decision_needed'; question = 'Choose?'; evidence = 'facts'; options = 'A or B'; recommendation = 'A'; confidence = 'high' }
    $request = New-FakeRequest @{ 'GET /session/ses_decision/message' = @('[]'); 'POST /session/ses_decision/message' = @(New-ResponseJson $decision) }
    $result = Invoke-DelegentWorkerProtocol ([pscustomobject]@{ Session = 'ses_decision'; Title = $null; Agent = 'plan'; Dir = $null; Prompt = 'task' }) $request
    Assert-True ($result.ExitCode -eq 0 -and $result.Output -match '^DECISION_NEEDED' -and $result.Output -match 'Recommendation:')
}

$tests['trajectory excluded'] = {
    $parts = @(@{ type = 'tool'; state = @{ output = 'trajectory-progress-marker' } }, @{ type = 'text'; text = 'human terminal noise' })
    $request = New-FakeRequest @{ 'GET /session/ses_trajectory/message' = @('[]'); 'POST /session/ses_trajectory/message' = @(New-ResponseJson (New-NormalResult) $parts) }
    $result = Invoke-DelegentWorkerProtocol ([pscustomobject]@{ Session = 'ses_trajectory'; Title = $null; Agent = 'build'; Dir = $null; Prompt = 'task' }) $request
    Assert-True ($result.ExitCode -eq 0 -and $result.Output -notmatch 'trajectory-progress-marker|human terminal noise')
}

$tests['missing terminal result'] = {
    $request = New-FakeRequest @{
        'POST /session' = @('{"id":"ses_missing"}')
        'POST /session/ses_missing/message' = @('{"info":{"id":"msg_new","role":"assistant"},"parts":[]}')
        'GET /session/ses_missing/message' = @('[]')
    }
    $result = Invoke-DelegentWorkerProtocol ([pscustomobject]@{ Session = $null; Title = $null; Agent = 'plan'; Dir = $null; Prompt = 'task' }) $request
    Assert-True ($result.Output -match 'kind: missing_terminal_handoff')
}

$tests['malformed field'] = {
    $malformed = New-NormalResult
    $malformed.Remove('risks')
    $request = New-FakeRequest @{ 'GET /session/ses_malformed/message' = @('[]'); 'POST /session/ses_malformed/message' = @(New-ResponseJson $malformed) }
    $result = Invoke-DelegentWorkerProtocol ([pscustomobject]@{ Session = 'ses_malformed'; Title = $null; Agent = 'plan'; Dir = $null; Prompt = 'task' }) $request
    Assert-True ($result.Output -match 'kind: malformed_handoff')
}

$tests['duplicate field'] = {
    $duplicate = '{"info":{"id":"msg_new","role":"assistant","structured_output":{"status":"completed","status":"blocked","summary":"done","evidence":"facts","changes":"none","tests":"passed","risks":"none","decisions_needed":"none","review_targets":"adapter"}},"parts":[]}'
    $request = New-FakeRequest @{ 'GET /session/ses_duplicate/message' = @('[]'); 'POST /session/ses_duplicate/message' = @($duplicate) }
    $result = Invoke-DelegentWorkerProtocol ([pscustomobject]@{ Session = 'ses_duplicate'; Title = $null; Agent = 'plan'; Dir = $null; Prompt = 'task' }) $request
    Assert-True ($result.Output -match 'kind: malformed_handoff')
}

$tests['runtime API failure'] = {
    $failure = { throw [InvalidOperationException]::new('untrusted runtime detail') }
    $request = New-FakeRequest @{ 'GET /session/ses_failure/message' = @('[]'); 'POST /session/ses_failure/message' = @($failure) }
    $result = Invoke-DelegentWorkerProtocol ([pscustomobject]@{ Session = 'ses_failure'; Title = $null; Agent = 'plan'; Dir = $null; Prompt = 'task' }) $request
    Assert-True ($result.Output -match 'kind: runtime_output_error' -and $result.Output -notmatch 'untrusted runtime detail')
}

$tests['bounded timeout'] = {
    $timeout = { throw [TimeoutException]::new('still running') }
    $request = New-FakeRequest @{
        'GET /session/ses_timeout/message' = @('[]', '[]')
        'POST /session/ses_timeout/message' = @($timeout)
        'POST /session/ses_timeout/abort' = @('{}')
    }
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $result = Invoke-DelegentWorkerProtocol ([pscustomobject]@{ Session = 'ses_timeout'; Title = $null; Agent = 'plan'; Dir = $null; Prompt = 'task' }) $request -PromptTimeoutSeconds 1
    $watch.Stop()
    Assert-True ($result.Output -match 'kind: timeout' -and $watch.Elapsed.TotalSeconds -lt 1)
}

$tests['CLI stdout missing; persisted session recovery'] = {
    $persisted = @(@{ info = @{ id = 'msg_new'; role = 'assistant'; structured_output = New-NormalResult }; parts = @(@{ type = 'tool'; state = @{ output = 'hidden trajectory' } }) }) | ConvertTo-Json -Depth 12 -Compress
    $request = New-FakeRequest @{
        'POST /session' = @('{"id":"ses_recovery"}')
        'POST /session/ses_recovery/message' = @('')
        'GET /session/ses_recovery/message' = @($persisted)
    }
    $result = Invoke-DelegentWorkerProtocol ([pscustomobject]@{ Session = $null; Title = 'delegent:test:scope:plan'; Agent = 'plan'; Dir = $null; Prompt = 'task' }) $request
    Assert-True ($result.ExitCode -eq 0 -and $result.Output -match '^STATUS: completed' -and $result.Output -notmatch 'hidden trajectory')
}

$tests['stale ID-less session result rejected'] = {
    $old = @(@{ info = @{ role = 'assistant'; structured = New-NormalResult }; parts = @() }) | ConvertTo-Json -Depth 12 -Compress
    $request = New-FakeRequest @{
        'GET /session/ses_stale/message' = @($old)
        'POST /session/ses_stale/message' = @('')
    }
    $result = Invoke-DelegentWorkerProtocol ([pscustomobject]@{ Session = 'ses_stale'; Title = $null; Agent = 'plan'; Dir = $null; Prompt = 'task' }) $request
    Assert-True ($result.Output -match 'kind: missing_terminal_handoff' -and $result.Output -notmatch 'done')
}

$tests['fake credential excluded'] = {
    $fakeCredential = 'nvapi-' + [Guid]::NewGuid().ToString('N')
    $parts = @(@{ type = 'tool'; state = @{ output = $fakeCredential } })
    $request = New-FakeRequest @{ 'GET /session/ses_secret/message' = @('[]'); 'POST /session/ses_secret/message' = @(New-ResponseJson (New-NormalResult) $parts) }
    $result = Invoke-DelegentWorkerProtocol ([pscustomobject]@{ Session = 'ses_secret'; Title = $null; Agent = 'plan'; Dir = $null; Prompt = 'task' }) $request -SensitiveValues @($fakeCredential)

    $leaking = New-NormalResult
    $leaking.summary = $fakeCredential
    $leakRequest = New-FakeRequest @{ 'GET /session/ses_leak/message' = @('[]'); 'POST /session/ses_leak/message' = @(New-ResponseJson $leaking) }
    $leakResult = Invoke-DelegentWorkerProtocol ([pscustomobject]@{ Session = 'ses_leak'; Title = $null; Agent = 'plan'; Dir = $null; Prompt = 'task' }) $leakRequest -SensitiveValues @($fakeCredential)

    $residue = @(
        Get-ChildItem -LiteralPath $repoRoot -Recurse -File -Force |
            Where-Object { $_.FullName -notmatch '\\.git\\' -and $_.FullName -ne $credentialPath } |
            Select-String -SimpleMatch $fakeCredential -List -ErrorAction SilentlyContinue
    )
    Assert-True ($result.Output -notmatch [regex]::Escape($fakeCredential) -and $leakResult.Output -match 'kind: runtime_output_error' -and $leakResult.Output -notmatch [regex]::Escape($fakeCredential) -and $residue.Count -eq 0)
}

$tests['sessions compatibility'] = {
    $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('delegent-phase-a-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempRoot -ErrorAction Stop | Out-Null
    $oldPath = $env:PATH
    $oldCredential = $env:DELEGENT_API_KEY
    $oldRuntime = $env:DELEGENT_RUNTIME
    try {
        $fakeOpenCode = Join-Path $tempRoot 'opencode.ps1'
        Set-Content -LiteralPath $fakeOpenCode -Encoding UTF8 -Value '[Console]::Out.Write(($args | ConvertTo-Json -Compress)); exit 0'
        $env:PATH = "$tempRoot;$oldPath"
        $runtimeCredential = 'fake-' + [Guid]::NewGuid().ToString('N')
        $env:DELEGENT_API_KEY = $runtimeCredential
        $env:DELEGENT_RUNTIME = Join-Path $tempRoot 'runtime'
        $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $wrapperPath sessions --format json
        $tempResidue = @(Get-ChildItem -LiteralPath $tempRoot -Recurse -File -Force | Select-String -SimpleMatch $runtimeCredential -List -ErrorAction SilentlyContinue)
        Assert-True ($LASTEXITCODE -eq 0 -and ($output -join '') -eq '["session","list","--format","json"]' -and ($output -join '') -notmatch [regex]::Escape($runtimeCredential) -and $tempResidue.Count -eq 0)
    }
    finally {
        $env:PATH = $oldPath
        $env:DELEGENT_API_KEY = $oldCredential
        $env:DELEGENT_RUNTIME = $oldRuntime
        if (Test-Path -LiteralPath $tempRoot) {
            $resolvedTemp = (Resolve-Path -LiteralPath $tempRoot).Path
            if ($resolvedTemp.StartsWith([IO.Path]::GetTempPath(), [StringComparison]::OrdinalIgnoreCase)) {
                Remove-Item -LiteralPath $resolvedTemp -Recurse -Force
            }
        }
    }
}

$tests['native server ownership and cleanup'] = {
    $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('delegent-native-' + [Guid]::NewGuid().ToString('N'))
    $shimDirectory = Join-Path $tempRoot 'npm'
    $nativeDirectory = Join-Path $shimDirectory 'node_modules\opencode-ai\bin'
    New-Item -ItemType Directory -Path $nativeDirectory -Force | Out-Null
    $shim = Join-Path $shimDirectory 'opencode.ps1'
    $native = Join-Path $nativeDirectory 'opencode.exe'
    New-Item -ItemType File -Path $shim, $native | Out-Null

    $parentCode = 'Start-Sleep -Milliseconds 500; $start = New-Object Diagnostics.ProcessStartInfo; $start.FileName = Join-Path $PSHOME ''powershell.exe''; $start.Arguments = ''-NoProfile -Command "Start-Sleep -Seconds 30"''; $start.UseShellExecute = $false; $start.CreateNoWindow = $true; $child = New-Object Diagnostics.Process; $child.StartInfo = $start; $null = $child.Start(); [Console]::Out.WriteLine($child.Id); [Console]::Out.Flush(); $child.WaitForExit()'
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($parentCode))
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = Join-Path $PSHOME 'powershell.exe'
    $start.Arguments = "-NoProfile -EncodedCommand $encoded"
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $server = New-Object Diagnostics.Process
    $server.StartInfo = $start
    $job = [IntPtr]::Zero
    $childId = $null
    try {
        Assert-True ((Resolve-DelegentOpenCodeServer $shim) -eq $native)
        $null = $server.Start()
        $null = $server.StandardError.ReadToEndAsync()
        $job = New-DelegentServerJob $server
        $childId = [int]$server.StandardOutput.ReadLine()
        Stop-DelegentServerProcess $server $job
        $job = [IntPtr]::Zero
        Start-Sleep -Milliseconds 100
        Assert-True ($server.HasExited -and $null -eq (Get-Process -Id $childId -ErrorAction SilentlyContinue))
    }
    finally {
        if ($job -ne [IntPtr]::Zero) { Stop-DelegentServerProcess $server $job }
        if ($childId -and (Get-Process -Id $childId -ErrorAction SilentlyContinue)) { Stop-Process -Id $childId -Force -ErrorAction SilentlyContinue }
        if (-not $server.HasExited) { $server.Kill() }
        $server.Dispose()
        if (Test-Path -LiteralPath $tempRoot) {
            $resolvedTemp = (Resolve-Path -LiteralPath $tempRoot).Path
            if ($resolvedTemp.StartsWith([IO.Path]::GetTempPath(), [StringComparison]::OrdinalIgnoreCase)) {
                Remove-Item -LiteralPath $resolvedTemp -Recurse -Force
            }
        }
    }
}

$tests['session title agent dir forwarding'] = {
    $invocation = Get-DelegentWorkerInvocation @('--session', 'ses_keep', '--title=delegent:test:scope:plan', '--agent', 'plan', '--dir', 'C:\fake-repo', '--', 'inspect', '--literal')
    Assert-True ($invocation.Session -eq 'ses_keep' -and $invocation.Title -eq 'delegent:test:scope:plan' -and $invocation.Agent -eq 'plan' -and $invocation.Dir -eq 'C:\fake-repo' -and $invocation.Prompt -eq 'inspect --literal')

    $capture = @{ Body = $null }
    $request = {
        param($Method, $Path, $BodyJson, $TimeoutSeconds)
        if ($Method -eq 'POST' -and $Path -eq '/session') {
            Assert-True ((ConvertFrom-Json $BodyJson).title -eq 'delegent:test:scope:build')
            return '{"id":"ses_created"}'
        }
        if ($Method -eq 'POST' -and $Path -eq '/session/ses_created/message') {
            $capture.Body = ConvertFrom-Json $BodyJson
            return New-ResponseJson (New-NormalResult)
        }
        throw 'Unexpected fake request.'
    }.GetNewClosure()
    $createdInvocation = Get-DelegentWorkerInvocation @('--title', 'delegent:test:scope:build', '--agent', 'build', '--dir', 'C:\fake-repo', 'task')
    $result = Invoke-DelegentWorkerProtocol $createdInvocation $request
    Assert-True ($result.ExitCode -eq 0 -and $capture.Body.agent -eq 'build' -and $capture.Body.parts[0].text -eq 'task')
}

$passed = 0
foreach ($test in $tests.GetEnumerator()) {
    try {
        & $test.Value
        Write-Output "PASS $($test.Key)"
        $passed++
    }
    catch {
        Write-Output "FAIL $($test.Key)"
    }
}

if ($passed -ne $tests.Count) {
    Write-Output "FAILED $passed/$($tests.Count)"
    exit 1
}

Write-Output "PASS $passed/$($tests.Count)"
exit 0
