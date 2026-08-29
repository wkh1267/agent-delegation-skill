param(
    [ValidateSet('baseline', 'delegated')]
    [string]$Expected = 'delegated'
)

$fixture = Join-Path $PSScriptRoot 'fixtures\controlled-workflow.txt'
if (-not (Test-Path -LiteralPath $fixture)) {
    Write-Error "Missing fixture: $fixture"
    exit 1
}

$content = (Get-Content -Raw -LiteralPath $fixture).Trim()
$actual = if ($content -match '^mode=(baseline|delegated)$') { $Matches[1] } else { $null }

if (-not $actual) {
    Write-Error "Malformed fixture content. Expected exactly mode=baseline or mode=delegated."
    exit 1
}

if ($actual -ne $Expected) {
    Write-Error "Expected mode=$Expected but found mode=$actual."
    exit 1
}

Write-Output "PASS mode=$actual"
exit 0
