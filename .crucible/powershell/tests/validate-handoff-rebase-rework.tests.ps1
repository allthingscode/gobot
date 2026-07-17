# A deployment -> implementation handoff is normally invalid, but the accept gate's
# auto-rebase emits one (with rebase_count >= 1) when a merge cannot be rebased
# cleanly. validate-handoff.ps1 must authorize that rebase-conflict re-entry even
# though the standing gate decision is "accepted", not "rejected".

$ErrorActionPreference = "Continue"
$REPO_ROOT = (Resolve-Path -Path "$PSScriptRoot/../..").Path
. (Join-Path $PSScriptRoot '_harness.ps1')
$validateScript = Join-Path $REPO_ROOT "powershell/validate-handoff.ps1"
. (Join-Path $REPO_ROOT "powershell/lib/platform.ps1")
$pwshCmd = Get-PwshCommand

$results = @()

function New-DeploymentReworkHandoff {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [int]$RebaseCount
    )
    $h = [ordered]@{
        task_id                  = "C-999"
        source_phase             = "deployment"
        target_phase             = "implementation"
        reason                   = "Rebase conflict: task/C-999 no longer applies cleanly onto master (rebase attempt 1/3)."
        generated_by             = "new-handoff.ps1"
        tool_version             = "1.0.0"
        handoff_retry_count      = 0
        review_strike_count      = 0
        rebase_count             = $RebaseCount
        budget_tier              = "low"
        cumulative_handoff_count = 6
        prompt_version           = "deployment_prompt-v25"
        session_cycle_id         = "initial"
        cycle_id                 = "initial"
        artifacts                = @("README.md")
        file_affinity            = @("README.md")
    }
    $h | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Path -Encoding UTF8
}

$results += Run-Test "deployment->implementation with rebase_count>=1 validates (no gate decision)" {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ("vh_a_" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    try {
        $hf = Join-Path $root "handoff.json"
        New-DeploymentReworkHandoff -Path $hf -RebaseCount 1
        Push-Location $root
        try {
            $out = & $pwshCmd -NoProfile -ExecutionPolicy Bypass -File $validateScript -HandoffFile $hf 2>&1
            $code = $LASTEXITCODE
        } finally { Pop-Location }
        Assert-Result "valid-exit" ($code -eq 0) "expected exit 0 (valid), got $code. Output: $out"
        Assert-Result "ok-true" (($out -join '') -match '"ok":true') "expected ok:true. Output: $out"
    } finally {
        Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
    }
}

$results += Run-Test "deployment->implementation with rebase_count=0 and no gate decision is rejected" {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ("vh_b_" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    try {
        $hf = Join-Path $root "handoff.json"
        New-DeploymentReworkHandoff -Path $hf -RebaseCount 0
        Push-Location $root
        try {
            $out = & $pwshCmd -NoProfile -ExecutionPolicy Bypass -File $validateScript -HandoffFile $hf 2>&1
            $code = $LASTEXITCODE
        } finally { Pop-Location }
        Assert-Result "invalid-exit" ($code -eq 1) "expected exit 1 (invalid), got $code. Output: $out"
        Assert-Result "invalid-transition" (($out -join '') -match 'invalid_transition') "expected invalid_transition. Output: $out"
    } finally {
        Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
    }
}

$passed = @($results | Where-Object { $_ }).Count
$total = $results.Count
Write-Host ("`n[validate-handoff-rebase-rework] {0}/{1} passed" -f $passed, $total) -ForegroundColor Cyan
if ($passed -ne $total) { exit 1 }
