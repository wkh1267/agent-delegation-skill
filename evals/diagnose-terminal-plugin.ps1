$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$skillRoot = Join-Path $repoRoot 'skills\delegating-work'
$protocolPath = Join-Path $skillRoot 'scripts\worker-protocol.ps1'
. $protocolPath

$old = @{
    api_key = $env:api_key
    XDG_CONFIG_HOME = $env:XDG_CONFIG_HOME
    XDG_DATA_HOME = $env:XDG_DATA_HOME
    XDG_CACHE_HOME = $env:XDG_CACHE_HOME
    XDG_STATE_HOME = $env:XDG_STATE_HOME
    OPENCODE_CONFIG = $env:OPENCODE_CONFIG
    OPENCODE_CONFIG_DIR = $env:OPENCODE_CONFIG_DIR
    OPENCODE_CONFIG_CONTENT = $env:OPENCODE_CONFIG_CONTENT
    OPENCODE_PURE = $env:OPENCODE_PURE
    OPENCODE_SERVER_USERNAME = $env:OPENCODE_SERVER_USERNAME
    OPENCODE_SERVER_PASSWORD = $env:OPENCODE_SERVER_PASSWORD
}

$runtime = Join-Path ([IO.Path]::GetTempPath()) ('delegent-terminal-diagnostic-' + [Guid]::NewGuid().ToString('N'))
$server = $null
$serverJob = [IntPtr]::Zero

try {
    New-Item -ItemType Directory -Force -Path $runtime | Out-Null

    # Use a non-secret placeholder only so {env:api_key} config substitution is deterministic.
    # This diagnostic never sends a model request.
    $env:api_key = 'delegent-diagnostic-placeholder'
    $env:XDG_CONFIG_HOME = Join-Path $runtime 'config'
    $env:XDG_DATA_HOME = Join-Path $runtime 'data'
    $env:XDG_CACHE_HOME = Join-Path $runtime 'cache'
    $env:XDG_STATE_HOME = Join-Path $runtime 'state'
    $env:OPENCODE_CONFIG = $null
    $env:OPENCODE_CONFIG_DIR = $null

    $inheritedPure = $old.OPENCODE_PURE
    # Delegent requires its explicit local terminal plugin, so test the runtime
    # under the intended non-pure setting regardless of caller environment.
    $env:OPENCODE_PURE = 'false'

    $baseConfigPath = Join-Path $skillRoot 'opencode.json'
    $config = Get-Content -Raw $baseConfigPath | ConvertFrom-Json -ErrorAction Stop
    $terminalPluginPath = (Resolve-Path -LiteralPath (Join-Path $skillRoot 'plugins\delegent-terminal.js') -ErrorAction Stop).Path
    $terminalPluginUri = ([System.Uri]::new($terminalPluginPath)).AbsoluteUri

    $pluginList = @()
    if ($null -ne $config.PSObject.Properties['plugin']) {
        $pluginList += @($config.plugin)
    }
    if ($pluginList -cnotcontains $terminalPluginUri) {
        $pluginList += $terminalPluginUri
    }
    if ($null -ne $config.PSObject.Properties['plugin']) {
        $config.plugin = $pluginList
    }
    else {
        $config | Add-Member -MemberType NoteProperty -Name plugin -Value $pluginList
    }
    $env:OPENCODE_CONFIG_CONTENT = $config | ConvertTo-Json -Depth 32 -Compress

    $listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $port = ([Net.IPEndPoint]$listener.LocalEndpoint).Port
    $listener.Stop()

    $serverPassword = [Guid]::NewGuid().ToString('N')
    $env:OPENCODE_SERVER_USERNAME = 'opencode'
    $env:OPENCODE_SERVER_PASSWORD = $serverPassword

    $command = Get-Command opencode -CommandType Application, ExternalScript -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $command) { throw 'OpenCode executable not found.' }

    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = Resolve-DelegentOpenCodeServer $command.Source
    $startInfo.Arguments = "serve --hostname 127.0.0.1 --port $port"
    $startInfo.WorkingDirectory = $repoRoot
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
        param($Path, $TimeoutSeconds)
        $response = Invoke-WebRequest -Uri ($baseUrl + $Path) -Method GET -Headers @{ Authorization = $authorization } -TimeoutSec $TimeoutSeconds -UseBasicParsing -ErrorAction Stop
        [string]$response.Content
    }.GetNewClosure()

    $health = $null
    $healthDeadline = [DateTime]::UtcNow.AddSeconds(10)
    while ([DateTime]::UtcNow -lt $healthDeadline -and -not $server.HasExited) {
        try {
            $candidate = (& $request '/global/health' 1) | ConvertFrom-Json -ErrorAction Stop
            if ($candidate.healthy -eq $true) {
                $health = $candidate
                break
            }
        }
        catch {}
        Start-Sleep -Milliseconds 100
    }
    if ($null -eq $health) { throw 'OpenCode server did not become healthy.' }

    $effectiveConfig = (& $request '/config' 10) | ConvertFrom-Json -ErrorAction Stop
    $toolIds = @(((& $request '/experimental/tool/ids' 20) | ConvertFrom-Json -ErrorAction Stop))

    $effectivePlugins = @()
    if ($null -ne $effectiveConfig.PSObject.Properties['plugin']) {
        $effectivePlugins = @($effectiveConfig.plugin | ForEach-Object { [string]$_ })
    }

    $pluginConfigured = $effectivePlugins -ccontains $terminalPluginUri
    $handoffRegistered = $toolIds -ccontains 'delegent_handoff'
    $decisionRegistered = $toolIds -ccontains 'delegent_decision'
    $pureInheritedText = if ([string]::IsNullOrWhiteSpace([string]$inheritedPure)) { 'unset' } else { [string]$inheritedPure }

    Write-Output 'TERMINAL_PLUGIN_DIAGNOSTIC'
    Write-Output "opencode_version=$([string]$health.version)"
    Write-Output "inherited_opencode_pure=$pureInheritedText"
    Write-Output 'diagnostic_opencode_pure=false'
    Write-Output "plugin_file_exists=$([bool](Test-Path -LiteralPath $terminalPluginPath -PathType Leaf))"
    Write-Output "plugin_configured=$([bool]$pluginConfigured)"
    Write-Output "configured_plugin_count=$($effectivePlugins.Count)"
    Write-Output "handoff_registered=$([bool]$handoffRegistered)"
    Write-Output "decision_registered=$([bool]$decisionRegistered)"
    Write-Output 'model_inference_used=false'
}
finally {
    if ($null -ne $server) {
        Stop-DelegentServerProcess $server $serverJob
        $server.Dispose()
    }

    foreach ($name in $old.Keys) {
        $value = $old[$name]
        if ($null -eq $value) {
            Remove-Item -LiteralPath ("Env:" + $name) -ErrorAction SilentlyContinue
        }
        else {
            Set-Item -LiteralPath ("Env:" + $name) -Value $value
        }
    }
    Remove-Item -LiteralPath $runtime -Recurse -Force -ErrorAction SilentlyContinue
}
