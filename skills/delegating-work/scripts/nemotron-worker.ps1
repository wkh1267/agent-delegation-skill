$skillRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$settings = Get-Content -Raw (Join-Path $skillRoot '.env') | ConvertFrom-StringData
if (-not $settings.api_key) { throw 'Missing api_key in delegating-work/.env' }

# Keep every delegated-worker command on the same OpenCode storage roots so
# session listing and session reuse see the sessions created by this wrapper.
$runtime = Join-Path ([IO.Path]::GetTempPath()) 'agent-delegation-skills\opencode'
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
