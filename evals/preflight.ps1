param(
    [switch]$RequireEvalWorkflow,
    [switch]$RequireMattWorkflows
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Push-Location $repoRoot

$failures = @()

try {
    $branch = (& git branch --show-current).Trim()
    if ($LASTEXITCODE -ne 0) {
        $failures += 'Unable to determine current Git branch.'
    }
    elseif ($branch -ne 'feat/delegent-v0.1') {
        $failures += "Expected branch feat/delegent-v0.1 but found $branch."
    }

    $status = @(& git status --short)
    if ($LASTEXITCODE -ne 0) {
        $failures += 'git status failed.'
    }
    elseif ($status.Count -gt 0) {
        $failures += 'Working tree is not clean.'
    }

    $requiredSkills = @('delegent', 'delegating-work')
    if ($RequireEvalWorkflow) {
        $requiredSkills += 'delegent-eval-workflow'
    }
    if ($RequireMattWorkflows) {
        $requiredSkills += @('implement', 'tdd', 'code-review')
    }

    foreach ($skill in $requiredSkills) {
        $skillPath = Join-Path $HOME ".agents\skills\$skill\SKILL.md"
        if (-not (Test-Path -LiteralPath $skillPath)) {
            $failures += "Missing Agent Skill: $skillPath"
        }
    }

    $envFile = Join-Path $repoRoot 'skills\delegating-work\.env'
    if (-not (Test-Path -LiteralPath $envFile)) {
        $failures += 'Missing skills/delegating-work/.env.'
    }
    else {
        try {
            $settings = Get-Content -Raw -LiteralPath $envFile | ConvertFrom-StringData
            if (-not $settings.api_key) {
                $failures += 'delegating-work/.env does not define api_key.'
            }
        }
        catch {
            $failures += 'delegating-work/.env could not be parsed as key=value settings.'
        }
    }

    $secretMatches = @(
        Get-ChildItem -LiteralPath $repoRoot -Recurse -File -Force |
            Where-Object {
                $_.FullName -notmatch '\\.git\\' -and
                $_.FullName -ne $envFile
            } |
            Select-String -Pattern 'nvapi-' -List -ErrorAction SilentlyContinue
    )

    if ($secretMatches.Count -gt 0) {
        $failures += 'Credential-shaped nvapi- content exists outside the ignored delegating-work/.env file.'
    }

    if ($failures.Count -gt 0) {
        Write-Output 'PREFLIGHT: FAIL'
        foreach ($failure in $failures) {
            Write-Output "- $failure"
        }
        exit 1
    }

    Write-Output 'PREFLIGHT: PASS'
    Write-Output "branch=$branch"
    Write-Output 'working_tree=clean'
    Write-Output "skills=$($requiredSkills -join ',')"
    Write-Output 'credential_file=present'
    Write-Output 'credential_residue_scan=clean'
    exit 0
}
finally {
    Pop-Location
}
