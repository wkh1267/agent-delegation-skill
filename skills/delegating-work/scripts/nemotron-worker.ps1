$skillRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$settings = Get-Content -Raw (Join-Path $skillRoot '.env') | ConvertFrom-StringData
if (-not $settings.api_key) { throw 'Missing api_key in delegating-work/.env' }
# ponytail: temp-backed sessions avoid sandbox ACLs; use a durable data dir when permissions allow.
$runtime = Join-Path ([IO.Path]::GetTempPath()) 'agent-delegation-skills\opencode'
$env:api_key = $settings.api_key.Trim('"').Trim("'")
$env:XDG_CONFIG_HOME = Join-Path $runtime 'config'
$env:XDG_DATA_HOME = Join-Path $runtime 'data'
$env:XDG_CACHE_HOME = Join-Path $runtime 'cache'
$env:XDG_STATE_HOME = Join-Path $runtime 'state'
$env:OPENCODE_CONFIG = $null
$env:OPENCODE_CONFIG_CONTENT = Get-Content -Raw (Join-Path $skillRoot 'opencode.json')
& opencode run --model 'nvidia/nvidia/nemotron-3-super-120b-a12b' @args
exit $LASTEXITCODE
