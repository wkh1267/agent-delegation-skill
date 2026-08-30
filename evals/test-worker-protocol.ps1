$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$protocolPath = Join-Path $repoRoot 'skills\delegating-work\scripts\worker-protocol.ps1'
$terminalProtocolPath = Join-Path $repoRoot 'skills\delegating-work\scripts\worker-terminal-protocol.ps1'
$wrapperPath = Join-Path $repoRoot 'skills\delegating-work\scripts\nemotron-worker.ps1'
$skillRoot = Join-Path $repoRoot 'skills\delegating-work'
$credentialPath = Join-Path $skillRoot '.env'
. $protocolPath
. $terminalProtocolPath

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message = 'Assertion failed.'
    )
    if (-not $Condition) { throw $Message }
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

function New-DecisionResult {
    [ordered]@{
        question = 'Choose?'
        evidence = 'facts'
        options = 'A or B'
        recommendation = 'A'
        confidence = 'high'
    }
}

function New-TerminalPart {
    param(
        [string]$Tool,
        [object]$Input,
        [string]$Status = 'completed'
    )
    @{
        type = 'tool'
        tool = $Tool
        callID = 'call_test'
        state = @{
            status = $Status
            input = $Input
            output = 'recorded'
            title = 'terminal'
            metadata = @{}
            time = @{ start = 1; end = 2 }
        }
    }
}

function New-ResponseJson {
    param(
        [object[]]$Parts = @(),
        [string]$Id = 'msg_new',
        [object]$Error = $null
    )
    $info = @{ id = $Id; role = 'assistant' }
    if ($null -ne $Error) { $info.error = $Error }
    @{ info = $info; parts = $Parts } | ConvertTo-Json -Depth 16 -Compress
}

# Windows PowerShell 5.1 can behave differently when scriptblocks created with
# GetNewClosure() are invoked across function/module scopes. Keep fake transport
# state explicitly at script scope so protocol tests exercise the adapter rather
# than closure/module visibility quirks.
$script:DelegentFakeRoutes = @{}

function New-FakeRequest {
    param([hashtable]$Routes)

    $script:DelegentFakeRoutes = @{}
    foreach ($key in $Routes.Keys) {
        $queue = New-Object Collections.Queue
        foreach ($item in @($Routes[$key])) { $queue.Enqueue($item) }
        $script:DelegentFakeRoutes[$key] = $queue
    }

    {
        param($Method, $Path, $BodyJson, $TimeoutSeconds)
        $key = "$Method $Path"
        $routes = $script:DelegentFakeRoutes
        if (-not $routes.ContainsKey($key) -or $routes[$key].Count -eq 0) {
            throw "Unexpected fake request: $key"
        }
        $item = $routes[$key].Dequeue()
        if ($item -is [scriptblock]) { return & $item $Method $Path $BodyJson $TimeoutSeconds }
        return [string]$item
    }
}

function New-Invocation {
    param([string]$Session = 'ses_test', [string]$Agent = 'plan')
    [pscustomobject]@{ Session = $Session; Title = $null; Agent = $Agent; Dir = $null; Prompt = 'task' }
}

$tests = [ordered]@{}

$tests['valid terminal handoff'] = {
    $parts = @(New-TerminalPart 'delegent_handoff' (New-NormalResult))
    $request = New-FakeRequest @{
        'GET /session/ses_valid/message' = @('[]')
        'POST /session/ses_valid/message' = @(New-ResponseJson $parts)
    }
    $result = Invoke-DelegentWorkerProtocol (New-Invocation 'ses_valid') $request
    Assert-True ($result.ExitCode -eq 0 -and $result.Output -match '^STATUS: completed' -and $result.Output -notmatch 'WORKER_PROTOCOL_ERROR') "Unexpected result: $($result.Output)"
}

$tests['valid terminal decision'] = {
    $parts = @(New-TerminalPart 'delegent_decision' (New-DecisionResult))
    $request = New-FakeRequest @{
        'GET /session/ses_decision/message' = @('[]')
        'POST /session/ses_decision/message' = @(New-ResponseJson $parts)
    }
    $result = Invoke-DelegentWorkerProtocol (New-Invocation 'ses_decision') $request
    Assert-True ($result.ExitCode -eq 0 -and $result.Output -match '^DECISION_NEEDED' -and $result.Output -match 'Recommendation:') "Unexpected result: $($result.Output)"
}

$tests['ordinary trajectory excluded'] = {
    $parts = @(
        @{ type = 'tool'; tool = 'read'; state = @{ status = 'completed'; input = @{ path = 'README.md' }; output = 'trajectory-progress-marker' } },
        @{ type = 'text'; text = 'human terminal noise' },
        (New-TerminalPart 'delegent_handoff' (New-NormalResult))
    )
    $request = New-FakeRequest @{
        'GET /session/ses_trajectory/message' = @('[]')
        'POST /session/ses_trajectory/message' = @(New-ResponseJson $parts)
    }
    $result = Invoke-DelegentWorkerProtocol (New-Invocation 'ses_trajectory' 'build') $request
    Assert-True ($result.ExitCode -eq 0 -and $result.Output -notmatch 'trajectory-progress-marker|human terminal noise') "Unexpected result: $($result.Output)"
}

$tests['missing terminal tool'] = {
    $request = New-FakeRequest @{
        'POST /session' = @('{"id":"ses_missing"}')
        'POST /session/ses_missing/message' = @(New-ResponseJson @(@{ type = 'text'; text = 'plain prose only' }))
        'GET /session/ses_missing/message' = @('[]')
    }
    $result = Invoke-DelegentWorkerProtocol (New-Invocation $null) $request
    Assert-True ($result.Output -match 'kind: missing_terminal_handoff' -and $result.Output -notmatch 'plain prose only')
}

$tests['malformed missing argument'] = {
    $value = New-NormalResult
    $value.Remove('risks')
    $parts = @(New-TerminalPart 'delegent_handoff' $value)
    $request = New-FakeRequest @{
        'GET /session/ses_missing_field/message' = @('[]')
        'POST /session/ses_missing_field/message' = @(New-ResponseJson $parts)
    }
    $result = Invoke-DelegentWorkerProtocol (New-Invocation 'ses_missing_field') $request
    Assert-True ($result.Output -match 'kind: malformed_handoff')
}

$tests['malformed extra argument'] = {
    $value = New-NormalResult
    $value.extra = 'not allowed'
    $parts = @(New-TerminalPart 'delegent_handoff' $value)
    $request = New-FakeRequest @{
        'GET /session/ses_extra/message' = @('[]')
        'POST /session/ses_extra/message' = @(New-ResponseJson $parts)
    }
    $result = Invoke-DelegentWorkerProtocol (New-Invocation 'ses_extra') $request
    Assert-True ($result.Output -match 'kind: malformed_handoff')
}

$tests['duplicate terminal handoff rejected'] = {
    $parts = @(
        (New-TerminalPart 'delegent_handoff' (New-NormalResult)),
        (New-TerminalPart 'delegent_handoff' (New-NormalResult))
    )
    $request = New-FakeRequest @{
        'GET /session/ses_duplicate/message' = @('[]')
        'POST /session/ses_duplicate/message' = @(New-ResponseJson $parts)
    }
    $result = Invoke-DelegentWorkerProtocol (New-Invocation 'ses_duplicate') $request
    Assert-True ($result.Output -match 'kind: malformed_handoff')
}

$tests['handoff and decision together rejected'] = {
    $parts = @(
        (New-TerminalPart 'delegent_handoff' (New-NormalResult)),
        (New-TerminalPart 'delegent_decision' (New-DecisionResult))
    )
    $request = New-FakeRequest @{
        'GET /session/ses_both/message' = @('[]')
        'POST /session/ses_both/message' = @(New-ResponseJson $parts)
    }
    $result = Invoke-DelegentWorkerProtocol (New-Invocation 'ses_both') $request
    Assert-True ($result.Output -match 'kind: malformed_handoff')
}

$tests['runtime API failure'] = {
    $failure = { throw [InvalidOperationException]::new('untrusted runtime detail') }
    $request = New-FakeRequest @{
        'GET /session/ses_failure/message' = @('[]')
        'POST /session/ses_failure/message' = @($failure)
    }
    $result = Invoke-DelegentWorkerProtocol (New-Invocation 'ses_failure') $request
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
    $result = Invoke-DelegentWorkerProtocol (New-Invocation 'ses_timeout') $request -PromptTimeoutSeconds 1
    $watch.Stop()
    Assert-True ($result.Output -match 'kind: timeout' -and $watch.Elapsed.TotalSeconds -lt 1)
}

$tests['persisted session recovery'] = {
    $persistedParts = @(
        @{ type = 'tool'; tool = 'read'; state = @{ status = 'completed'; input = @{ path = 'README.md' }; output = 'hidden trajectory' } },
        (New-TerminalPart 'delegent_handoff' (New-NormalResult))
    )
    $persisted = @(@{ info = @{ id = 'msg_new'; role = 'assistant' }; parts = $persistedParts }) | ConvertTo-Json -Depth 16 -Compress
    $request = New-FakeRequest @{
        'POST /session' = @('{"id":"ses_recovery"}')
        'POST /session/ses_recovery/message' = @('')
        'GET /session/ses_recovery/message' = @($persisted)
    }
    $result = Invoke-DelegentWorkerProtocol (New-Invocation $null) $request
    Assert-True ($result.ExitCode -eq 0 -and $result.Output -match '^STATUS: completed' -and $result.Output -notmatch 'hidden trajectory') "Unexpected result: $($result.Output)"
}

$tests['stale terminal result rejected on reuse'] = {
    $old = @(@{ info = @{ id = 'msg_old'; role = 'assistant' }; parts = @((New-TerminalPart 'delegent_handoff' (New-NormalResult))) }) | ConvertTo-Json -Depth 16 -Compress
    $request = New-FakeRequest @{
        'GET /session/ses_stale/message' = @($old, $old)
        'POST /session/ses_stale/message' = @('')
    }
    $result = Invoke-DelegentWorkerProtocol (New-Invocation 'ses_stale') $request
    Assert-True ($result.Output -match 'kind: missing_terminal_handoff' -and $result.Output -notmatch '^STATUS: completed')
}

$tests['sensitive content excluded'] = {
    $fakeCredential = 'nvapi-' + [Guid]::NewGuid().ToString('N')
    $safeParts = @(
        @{ type = 'tool'; tool = 'read'; state = @{ status = 'completed'; input = @{}; output = $fakeCredential } },
        (New-TerminalPart 'delegent_handoff' (New-NormalResult))
    )
    $safeRequest = New-FakeRequest @{
        'GET /session/ses_secret/message' = @('[]')
        'POST /session/ses_secret/message' = @(New-ResponseJson $safeParts)
    }
    $safe = Invoke-DelegentWorkerProtocol (New-Invocation 'ses_secret') $safeRequest -SensitiveValues @($fakeCredential)

    $leaking = New-NormalResult
    $leaking.summary = $fakeCredential
    $leakRequest = New-FakeRequest @{
        'GET /session/ses_leak/message' = @('[]')
        'POST /session/ses_leak/message' = @(New-ResponseJson @((New-TerminalPart 'delegent_handoff' $leaking)))
    }
    $leak = Invoke-DelegentWorkerProtocol (New-Invocation 'ses_leak') $leakRequest -SensitiveValues @($fakeCredential)

    $residue = @(
        Get-ChildItem -LiteralPath $repoRoot -Recurse -File -Force |
            Where-Object { $_.FullName -notmatch '\\.git\\' -and $_.FullName -ne $credentialPath } |
            Select-String -SimpleMatch $fakeCredential -List -ErrorAction SilentlyContinue
    )
    Assert-True ($safe.ExitCode -eq 0 -and $safe.Output -notmatch [regex]::Escape($fakeCredential) -and $leak.Output -match 'kind: runtime_output_error' -and $leak.Output -notmatch [regex]::Escape($fakeCredential) -and $residue.Count -eq 0) "Safe=$($safe.Output); Leak=$($leak.Output)"
}

$tests['message body has no format or agent'] = {
    $script:DelegentCapturedBody = $null
    $script:DelegentMessageBodyResponse = New-ResponseJson @((New-TerminalPart 'delegent_handoff' (New-NormalResult)))
    $request = {
        param($Method, $Path, $BodyJson, $TimeoutSeconds)
        if ($Method -eq 'GET') { return '[]' }
        $script:DelegentCapturedBody = ConvertFrom-Json $BodyJson
        return $script:DelegentMessageBodyResponse
    }
    $result = Invoke-DelegentWorkerProtocol (New-Invocation 'ses_body' 'build') $request
    $capture = $script:DelegentCapturedBody
    Assert-True ($result.ExitCode -eq 0 -and $null -ne $capture -and $null -eq $capture.PSObject.Properties['format'] -and $null -eq $capture.PSObject.Properties['agent'] -and $capture.model.providerID -eq 'nvidia') "Unexpected result/body: $($result.Output)"
}

$tests['terminal tool installation'] = {
    $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('delegent-tools-' + [Guid]::NewGuid().ToString('N'))
    try {
        $target = Install-DelegentTerminalTools $skillRoot $tempRoot
        $handoff = Join-Path $target 'delegent_handoff.ts'
        $decision = Join-Path $target 'delegent_decision.ts'
        Assert-True ((Test-Path $handoff) -and (Test-Path $decision))
        $combined = (Get-Content -Raw $handoff) + (Get-Content -Raw $decision)
        Assert-True ($combined -notmatch 'nvapi-|api_key|Get-Content|Invoke-RestMethod|Invoke-WebRequest')
    }
    finally {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$tests['session title agent dir parsing'] = {
    $invocation = Get-DelegentWorkerInvocation @('--session', 'ses_keep', '--title=delegent:test:scope:plan', '--agent', 'plan', '--dir', 'C:\fake-repo', '--', 'inspect', '--literal')
    Assert-True ($invocation.Session -eq 'ses_keep' -and $invocation.Title -eq 'delegent:test:scope:plan' -and $invocation.Agent -eq 'plan' -and $invocation.Dir -eq 'C:\fake-repo' -and $invocation.Prompt -eq 'inspect --literal')
}

$tests['sessions compatibility'] = {
    $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('delegent-sessions-' + [Guid]::NewGuid().ToString('N'))
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
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
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
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$passed = 0
foreach ($test in $tests.GetEnumerator()) {
    try {
        & $test.Value
        Write-Output "PASS $($test.Key)"
        $passed++
    }
    catch {
        Write-Output "FAIL $($test.Key): $($_.Exception.Message)"
    }
}

if ($passed -ne $tests.Count) {
    Write-Output "FAILED $passed/$($tests.Count)"
    exit 1
}

Write-Output "PASS $passed/$($tests.Count)"
exit 0