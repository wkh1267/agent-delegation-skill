$skillRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$settings = Get-Content -Raw (Join-Path $skillRoot '.env') | ConvertFrom-StringData
if (-not $settings.api_key) { throw 'Missing api_key in delegating-work/.env' }

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

$env:api_key = $settings.api_key.Trim('"').Trim("'")
$env:XDG_CONFIG_HOME = Join-Path $runtime 'config'
$env:XDG_DATA_HOME = Join-Path $runtime 'data'
$env:XDG_CACHE_HOME = Join-Path $runtime 'cache'
$env:XDG_STATE_HOME = Join-Path $runtime 'state'
$env:OPENCODE_CONFIG = $null
$env:OPENCODE_CONFIG_CONTENT = Get-Content -Raw (Join-Path $skillRoot 'opencode.json')

# `sessions` is a wrapper-only convenience command. Everything else keeps the
# original behavior and is forwarded to `opencode run`, so existing invocations
# such as `--agent build --dir <repo> <task>` remain valid.
if ($args.Count -gt 0 -and $args[0] -eq 'sessions') {
    $sessionArgs = @()
    if ($args.Count -gt 1) {
        $sessionArgs = $args[1..($args.Count - 1)]
    }
    & opencode session list @sessionArgs
    exit $LASTEXITCODE
}

& opencode run --model 'nvidia/nvidia/nemotron-3-super-120b-a12b' @args
exit $LASTEXITCODE
