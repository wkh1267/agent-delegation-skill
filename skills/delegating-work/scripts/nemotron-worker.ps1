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
# Do not inherit a caller-owned explicit config directory. Normal Worker runs
# install Delegent-owned tools into their own explicit directory below.
$env:OPENCODE_CONFIG_DIR = $null
$baseConfigPath = Join-Path $skillRoot 'opencode.json'
$env:OPENCODE_CONFIG_CONTENT = Get-Content -Raw $baseConfigPath

# `sessions` remains the wrapper-only OpenCode CLI path. Worker runs use the
# session API below while preserving the documented wrapper flags.
if ($args.Count -gt 0 -and $args[0] -eq 'sessions') {
    $sessionArgs = @()
    if ($args.Count -gt 1) {
        $sessionArgs = $args[1..($args.Count - 1)]
    }
    & opencode session list @sessionArgs
    exit $LASTEXITCODE
}

# Keep the mature parsing/process/session helpers from Phase A, then override
# only the Worker terminal-result transport with the normal-tool implementation.
. (Join-Path $PSScriptRoot 'worker-protocol.ps1')
. (Join-Path $PSScriptRoot 'worker-terminal-protocol.ps1')
. (Join-Path $PSScriptRoot 'worker-terminal-catalog.ps1')

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

try {
    # OpenCode 1.18.x has a live bug where supplying `agent` on
    # POST /session/:id/message can fail. Preserve the wrapper's --agent contract
    # by selecting the requested default agent in this invocation's isolated
    # server config instead of putting `agent` in the message body.
    $config = Get-Content -Raw $baseConfigPath | ConvertFrom-Json -ErrorAction Stop
    if ($invocation.Agent) { $config.default_agent = [string]$invocation.Agent }
    $env:OPENCODE_CONFIG_CONTENT = $config | ConvertTo-Json -Depth 32 -Compress

    # Use OpenCode's explicit config-directory seam rather than inferring a
    # global tools path from XDG_CONFIG_HOME. OpenCode 1.18.25 adds this exact
    # directory to discovery, installs @opencode-ai/plugin there, and waits for
    # that dependency before importing custom tools.
    $delegentConfigDir = Join-Path $runtime 'delegent-config'
    New-Item -ItemType Directory -Force -Path $delegentConfigDir -ErrorAction Stop | Out-Null
    $env:OPENCODE_CONFIG_DIR = $delegentConfigDir
    $null = Install-DelegentTerminalTools -SkillRoot $skillRoot -ConfigDir $delegentConfigDir
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

    # First use of an explicit OpenCode config directory may install
    # @opencode-ai/plugin before custom tools can be imported. ToolRegistry waits
    # for that dependency, so a five-second catalog request is too aggressive on
    # a cold runtime. Keep bootstrap bounded, retry short timed-out requests, and
    # never spend a Worker inference call until both terminal tools are visible.
    $bootstrapTimeoutSeconds = 60
    if ($env:DELEGENT_BOOTSTRAP_TIMEOUT_SECONDS) {
        $parsedBootstrapTimeout = 0
        if (-not [int]::TryParse($env:DELEGENT_BOOTSTRAP_TIMEOUT_SECONDS, [ref]$parsedBootstrapTimeout) -or
            $parsedBootstrapTimeout -lt 5 -or $parsedBootstrapTimeout -gt 300) {
            throw 'Invalid terminal tool bootstrap timeout.'
        }
        $bootstrapTimeoutSeconds = $parsedBootstrapTimeout
    }

    $catalogReady = $false
    $catalogTimedOut = $false
    $catalogDeadline = [DateTime]::UtcNow.AddSeconds($bootstrapTimeoutSeconds)
    while ([DateTime]::UtcNow -lt $catalogDeadline -and -not $server.HasExited) {
        $remainingSeconds = [int][Math]::Ceiling(($catalogDeadline - [DateTime]::UtcNow).TotalSeconds)
        if ($remainingSeconds -lt 1) { break }
        $attemptTimeoutSeconds = [Math]::Min(10, $remainingSeconds)
        try {
            $toolIdsJson = & $request 'GET' '/experimental/tool/ids' $null $attemptTimeoutSeconds
            $toolIds = @(ConvertFrom-DelegentUniqueJson $toolIdsJson)
            if (-not (Test-DelegentTerminalToolCatalog $toolIds)) {
                $result = New-DelegentTerminalCatalogError -Kind terminal_tools_unavailable
                Write-Output $result.Output
                exit $result.ExitCode
            }
            $catalogReady = $true
            break
        }
        catch {
            if (Test-DelegentTimeoutError $_) {
                $catalogTimedOut = $true
                Start-Sleep -Milliseconds 100
                continue
            }
            $result = New-DelegentTerminalCatalogError -Kind terminal_tool_catalog_error
            Write-Output $result.Output
            exit $result.ExitCode
        }
    }

    if (-not $catalogReady) {
        $kind = if ($catalogTimedOut) { 'terminal_tool_bootstrap_timeout' } else { 'terminal_tool_catalog_error' }
        $result = New-DelegentTerminalCatalogError -Kind $kind
        Write-Output $result.Output
        exit $result.ExitCode
    }

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
