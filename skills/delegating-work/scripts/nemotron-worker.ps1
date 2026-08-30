$skillRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$apiKey = $env:DELEGENT_API_KEY
if (-not $apiKey) {
    $settings = Get-Content -Raw (Join-Path $skillRoot '.env') | ConvertFrom-StringData
    $apiKey = $settings.api_key
}
if (-not $apiKey) { throw 'Missing Worker API credential.' }

# Keep every delegated-worker command on the same OpenCode storage roots so
# session listing and session reuse see the sessions created by this wrapper.
# Prefer a durable per-user location for persistent Worker memory. An explicit
# DELEGENT_RUNTIME override wins. If the durable default is not writable, fall
# back to the system temp directory so delegation can still function.
$runtime = $null
if ($env:DELEGENT_RUNTIME) {
    $runtime = $env:DELEGENT_RUNTIME
    New-Item -ItemType Directory -Force -Path $runtime -ErrorAction Stop | Out-Null
}
elseif ($env:LOCALAPPDATA) {
    $durable = Join-Path $env:LOCALAPPDATA 'agent-delegation-skills\opencode'
    try {
        New-Item -ItemType Directory -Force -Path $durable -ErrorAction Stop | Out-Null
        $runtime = $durable
    }
    catch {
        $runtime = $null
    }
}

if (-not $runtime) {
    $runtime = Join-Path ([IO.Path]::GetTempPath()) 'agent-delegation-skills\opencode'
    New-Item -ItemType Directory -Force -Path $runtime -ErrorAction Stop | Out-Null
}

$env:api_key = $apiKey.Trim('"').Trim("'")
$env:XDG_CONFIG_HOME = Join-Path $runtime 'config'
$env:XDG_DATA_HOME = Join-Path $runtime 'data'
$env:XDG_CACHE_HOME = Join-Path $runtime 'cache'
$env:XDG_STATE_HOME = Join-Path $runtime 'state'
$env:OPENCODE_CONFIG = $null
$env:OPENCODE_CONFIG_CONTENT = Get-Content -Raw (Join-Path $skillRoot 'opencode.json')

# `sessions` remains the wrapper-only OpenCode CLI path. Worker runs use the
# structured session API below while preserving the documented wrapper flags.
if ($args.Count -gt 0 -and $args[0] -eq 'sessions') {
    $sessionArgs = @()
    if ($args.Count -gt 1) {
        $sessionArgs = $args[1..($args.Count - 1)]
    }
    & opencode session list @sessionArgs
    exit $LASTEXITCODE
}

. (Join-Path $PSScriptRoot 'worker-protocol.ps1')

try {
    $invocation = Get-DelegentWorkerInvocation $args
}
catch {
    $result = New-DelegentProtocolError -Kind runtime_output_error
    Write-Output $result.Output
    exit $result.ExitCode
}

$workingDirectory = if ($invocation.Dir) { $invocation.Dir } else { (Get-Location).Path }
try {
    $workingDirectory = (Resolve-Path -LiteralPath $workingDirectory -ErrorAction Stop).Path
}
catch {
    $result = New-DelegentProtocolError -Kind runtime_output_error
    Write-Output $result.Output
    exit $result.ExitCode
}

$listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
$listener.Start()
$port = ([Net.IPEndPoint]$listener.LocalEndpoint).Port
$listener.Stop()

$serverPassword = [Guid]::NewGuid().ToString('N')
$env:OPENCODE_SERVER_USERNAME = 'opencode'
$env:OPENCODE_SERVER_PASSWORD = $serverPassword
$command = Get-Command opencode -CommandType Application, ExternalScript -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $command) {
    $result = New-DelegentProtocolError -Kind runtime_output_error
    Write-Output $result.Output
    exit $result.ExitCode
}

$server = $null
$serverJob = [IntPtr]::Zero
try {
    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = Resolve-DelegentOpenCodeServer $command.Source
    $startInfo.Arguments = "serve --hostname 127.0.0.1 --port $port"
    $startInfo.WorkingDirectory = $workingDirectory
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true

    $server = New-Object Diagnostics.Process
    $server.StartInfo = $startInfo
    Initialize-DelegentServerJob
    if (-not $server.Start()) { throw 'OpenCode server did not start.' }
    $serverJob = New-DelegentServerJob $server
    $server.BeginOutputReadLine()
    $server.BeginErrorReadLine()

    $baseUrl = "http://127.0.0.1:$port"
    $authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("opencode:$serverPassword"))
    $request = {
        param($Method, $Path, $BodyJson, $TimeoutSeconds)
        $parameters = @{
            Uri = $baseUrl + $Path
            Method = $Method
            Headers = @{ Authorization = $authorization }
            TimeoutSec = $TimeoutSeconds
            UseBasicParsing = $true
            ErrorAction = 'Stop'
        }
        if ($null -ne $BodyJson) {
            $parameters.ContentType = 'application/json'
            $parameters.Body = $BodyJson
        }
        $response = Invoke-WebRequest @parameters
        [string]$response.Content
    }.GetNewClosure()

    $healthy = $false
    $healthDeadline = [DateTime]::UtcNow.AddSeconds(10)
    while ([DateTime]::UtcNow -lt $healthDeadline -and -not $server.HasExited) {
        try {
            $health = ConvertFrom-DelegentUniqueJson (& $request 'GET' '/global/health' $null 1)
            if ($health.healthy -eq $true) { $healthy = $true; break }
        }
        catch {}
        Start-Sleep -Milliseconds 100
    }
    if (-not $healthy) { throw 'OpenCode server did not become healthy.' }

    $timeoutSeconds = 300
    if ($env:DELEGENT_TIMEOUT_SECONDS) {
        $parsedTimeout = 0
        if (-not [int]::TryParse($env:DELEGENT_TIMEOUT_SECONDS, [ref]$parsedTimeout) -or $parsedTimeout -lt 1) {
            throw 'Invalid Worker timeout.'
        }
        $timeoutSeconds = $parsedTimeout
    }

    $result = Invoke-DelegentWorkerProtocol -Invocation $invocation -Request $request -SensitiveValues @($env:api_key) -PromptTimeoutSeconds $timeoutSeconds
    Write-Output $result.Output
    exit $result.ExitCode
}
catch {
    $exitCode = if ($null -ne $server -and $server.HasExited) { $server.ExitCode } else { $null }
    $result = New-DelegentProtocolError -Kind runtime_output_error -ExitCode $exitCode
    Write-Output $result.Output
    exit $result.ExitCode
}
finally {
    if ($null -ne $server) {
        Stop-DelegentServerProcess $server $serverJob
        $server.Dispose()
    }
}
