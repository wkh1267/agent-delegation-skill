$ErrorActionPreference = 'Stop'

# Deterministic test for the Delegent handoff MCP boundary. No model, no
# network: synthetic JSON-RPC is driven over stdio so the boundary's accept and
# reject behaviour is pinned in CI. The live N4 gate depends on this server
# actually refusing malformed submissions, so that property must be tested here
# rather than inferred from a passing live run.

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$serverPath = Join-Path $repoRoot 'skills\delegating-work\tools\delegent-handoff-mcp.js'
$schemaPath = Join-Path $repoRoot 'skills\delegating-work\schemas\delegent-handoff.schema.json'

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message = 'Assertion failed.'
    )
    if (-not $Condition) { throw $Message }
}

Assert-True (Test-Path -LiteralPath $serverPath -PathType Leaf) 'Handoff MCP server is missing.'
Assert-True (Test-Path -LiteralPath $schemaPath -PathType Leaf) 'Handoff schema is missing.'

$node = Get-Command node -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $node) {
    Write-Output 'SKIP Delegent handoff MCP boundary (node not available)'
    exit 0
}

function Invoke-McpSession {
    param([string[]]$Requests)

    $outDir = Join-Path ([IO.Path]::GetTempPath()) ('delegent-mcp-test-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $outDir | Out-Null
    $outPath = Join-Path $outDir 'handoff.json'

    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = $node.Source
    $startInfo.Arguments = ('"' + $serverPath + '" "' + $schemaPath + '" "' + $outPath + '"')
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
    foreach ($request in $Requests) { $process.StandardInput.WriteLine($request) }
    $process.StandardInput.Close()
    if (-not $process.WaitForExit(30000)) {
        try { & taskkill.exe /PID $process.Id /T /F 1>$null 2>$null } catch {}
    }
    $stdout = ''
    $stderr = ''
    try { $stdout = [string]$stdoutTask.Result } catch {}
    try { $stderr = [string]$stderrTask.Result } catch {}
    $process.Dispose()

    $responses = @()
    foreach ($line in @($stdout -split "`r?`n" | Where-Object { $_.Trim() })) {
        try { $responses += ($line | ConvertFrom-Json -ErrorAction Stop) } catch {}
    }

    $accepted = $null
    if (Test-Path -LiteralPath $outPath -PathType Leaf) {
        $accepted = Get-Content -Raw -LiteralPath $outPath | ConvertFrom-Json
    }
    $logEntries = @()
    if (Test-Path -LiteralPath ($outPath + '.log.jsonl') -PathType Leaf) {
        foreach ($line in @(Get-Content -LiteralPath ($outPath + '.log.jsonl') | Where-Object { $_.Trim() })) {
            try { $logEntries += ($line | ConvertFrom-Json -ErrorAction Stop) } catch {}
        }
    }

    Remove-Item -LiteralPath $outDir -Recurse -Force -ErrorAction SilentlyContinue

    return [pscustomobject]@{
        Responses = $responses
        Accepted = $accepted
        AcceptedFileWritten = ($null -ne $accepted)
        LogEntries = $logEntries
        Stderr = $stderr
    }
}

$initialize = '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"0"}}}'
$initialized = '{"jsonrpc":"2.0","method":"notifications/initialized"}'
$listTools = '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'

function New-CallRequest {
    param([int]$Id, [hashtable]$Arguments)
    $payload = @{
        jsonrpc = '2.0'
        id = $Id
        method = 'tools/call'
        params = @{ name = 'delegent_handoff'; arguments = $Arguments }
    }
    return ($payload | ConvertTo-Json -Depth 20 -Compress)
}

$validHandoff = @{
    status = 'completed'
    summary = 'Inspected the README and reported findings.'
    evidence = @('README.md line 3: Context-aware coding-agent orchestration for Codex.')
    changes = @()
    tests = @()
    risks = @()
    decisions_needed = @()
    review_targets = @()
}

# --- 1. Handshake and tool advertisement ---
$session = Invoke-McpSession -Requests @($initialize, $initialized, $listTools)
$initResponse = @($session.Responses | Where-Object { $_.id -eq 1 })
Assert-True ($initResponse.Count -eq 1) 'Server must answer initialize exactly once.'
Assert-True (-not [string]::IsNullOrWhiteSpace([string]$initResponse[0].result.serverInfo.name)) 'initialize must report serverInfo.'
$listResponse = @($session.Responses | Where-Object { $_.id -eq 2 })
Assert-True ($listResponse.Count -eq 1) 'Server must answer tools/list.'
$tools = @($listResponse[0].result.tools)
Assert-True ($tools.Count -eq 1) 'Boundary must advertise exactly one tool.'
Assert-True ([string]$tools[0].name -ceq 'delegent_handoff') 'Tool must be named delegent_handoff.'
$advertised = @($tools[0].inputSchema.required)
foreach ($field in @('status', 'summary', 'evidence', 'changes', 'tests', 'risks', 'decisions_needed', 'review_targets')) {
    Assert-True ($advertised -contains $field) "Advertised input schema must require $field."
}
Assert-True ($false -eq $tools[0].inputSchema.additionalProperties) 'Advertised input schema must be closed.'

# --- 2. A conforming handoff is accepted and persisted ---
$session = Invoke-McpSession -Requests @($initialize, $initialized, (New-CallRequest -Id 3 -Arguments $validHandoff))
$callResponse = @($session.Responses | Where-Object { $_.id -eq 3 })
Assert-True ($callResponse.Count -eq 1) 'Server must answer tools/call.'
Assert-True (-not [bool]$callResponse[0].result.isError) 'A conforming handoff must not be an error.'
Assert-True ([string]$callResponse[0].result.content[0].text -match 'HANDOFF_ACCEPTED') 'A conforming handoff must be accepted.'
Assert-True $session.AcceptedFileWritten 'A conforming handoff must be persisted.'
Assert-True ([string]$session.Accepted.status -ceq 'completed') 'Persisted handoff must preserve status.'
Assert-True (@($session.LogEntries | Where-Object { $_.accepted -eq $true }).Count -eq 1) 'Log must record one acceptance.'

# --- 3. Negative controls: each malformation must be rejected, and must not
#        write an accepted handoff. This is the property the live gate relies on.
$rejectCases = @(
    @{ Name = 'missing required field'; Arguments = @{ status = 'completed'; summary = 'x'; evidence = @() } },
    @{ Name = 'unknown extra field'; Arguments = ($validHandoff + @{ surprise = 'nope' }) },
    @{ Name = 'status outside enum'; Arguments = ($validHandoff.Clone() + @{}) },
    @{ Name = 'scalar where array required'; Arguments = ($validHandoff.Clone() + @{}) },
    @{ Name = 'wrong type for summary'; Arguments = ($validHandoff.Clone() + @{}) }
)
$rejectCases[2].Arguments['status'] = 'finished'
$rejectCases[3].Arguments['evidence'] = 'not-an-array'
$rejectCases[4].Arguments['summary'] = 42

$caseId = 10
foreach ($case in $rejectCases) {
    $caseId++
    $session = Invoke-McpSession -Requests @($initialize, $initialized, (New-CallRequest -Id $caseId -Arguments $case.Arguments))
    $response = @($session.Responses | Where-Object { $_.id -eq $caseId })
    Assert-True ($response.Count -eq 1) "$($case.Name): server must answer."
    Assert-True ([bool]$response[0].result.isError) "$($case.Name): must be reported as an error."
    Assert-True ([string]$response[0].result.content[0].text -match 'HANDOFF_REJECTED') "$($case.Name): must be rejected."
    Assert-True (-not $session.AcceptedFileWritten) "$($case.Name): a rejected handoff must never be persisted."
    Assert-True (@($session.LogEntries | Where-Object { $_.accepted -eq $false }).Count -eq 1) "$($case.Name): log must record the rejection."
}

# --- 4. An unknown tool name is refused ---
$unknown = '{"jsonrpc":"2.0","id":20,"method":"tools/call","params":{"name":"not_the_handoff","arguments":{}}}'
$session = Invoke-McpSession -Requests @($initialize, $initialized, $unknown)
$response = @($session.Responses | Where-Object { $_.id -eq 20 })
Assert-True ($response.Count -eq 1) 'Server must answer an unknown tool call.'
Assert-True ($null -ne $response[0].error) 'An unknown tool must be a protocol error.'
Assert-True (-not $session.AcceptedFileWritten) 'An unknown tool must never write a handoff.'

# --- 5. Rejection then correction: the Worker can recover in one session ---
$session = Invoke-McpSession -Requests @(
    $initialize,
    $initialized,
    (New-CallRequest -Id 30 -Arguments @{ status = 'completed'; summary = 'x' }),
    (New-CallRequest -Id 31 -Arguments $validHandoff)
)
$first = @($session.Responses | Where-Object { $_.id -eq 30 })
$second = @($session.Responses | Where-Object { $_.id -eq 31 })
Assert-True ([bool]$first[0].result.isError) 'The malformed submission must be rejected.'
Assert-True (-not [bool]$second[0].result.isError) 'The corrected submission must be accepted.'
Assert-True $session.AcceptedFileWritten 'The corrected submission must be persisted.'
Assert-True (@($session.LogEntries).Count -eq 2) 'Log must record both submissions.'

Write-Output "PASS Delegent handoff MCP boundary ($($rejectCases.Count) rejection controls)"
exit 0
