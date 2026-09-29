# Item 136: a verification -> deployment handoff must carry all six reviewer checks as
# separate enum values. A comma-joined string written by hand, an unknown value, or a
# missing check is refused, and the refusal names the offending value.

$ErrorActionPreference = "Continue"
$REPO_ROOT = (Resolve-Path -Path "$PSScriptRoot/../..").Path
. (Join-Path $PSScriptRoot '_harness.ps1')
$validateScript = Join-Path $REPO_ROOT "powershell/validate-handoff.ps1"
. (Join-Path $REPO_ROOT "powershell/lib/platform.ps1")
$pwshCmd = Get-PwshCommand

$allChecks = @("tests_pass", "vet_pass", "acceptance_criteria_met", "scope_bounded", "no_regressions", "no_hard_mandates_violated")
$results = @()

function Invoke-ValidatorOnChecks {
    param([Parameter(Mandatory = $true)][object[]]$Checks)
    $root = New-TestFixtureRoot -NameHint "vh-rc"
    try {
        $hf = Join-Path $root "handoff.json"
        [ordered]@{
            task_id                  = "C-998"
            source_phase             = "verification"
            target_phase             = "deployment"
            reason                   = "Review approved - no blockers"
            generated_by             = "new-handoff.ps1"
            tool_version             = "1.0.0"
            handoff_retry_count      = 0
            review_strike_count      = 0
            rebase_count             = 0
            budget_tier              = "low"
            cumulative_handoff_count = 4
            prompt_version           = "verification_prompt-v1"
            session_cycle_id         = "initial"
            cycle_id                 = "initial"
            artifacts                = @("README.md")
            reviewer_checks_passed   = $Checks
        } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $hf -Encoding UTF8
        Push-Location $root
        try {
            $out = & $pwshCmd -NoProfile -ExecutionPolicy Bypass -File $validateScript -HandoffFile $hf 2>&1
            return @{ Code = $LASTEXITCODE; Out = ($out -join '') }
        } finally { Pop-Location }
    } finally {
        Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
    }
}

$results += Run-Test "all six checks as separate items validate" {
    $r = Invoke-ValidatorOnChecks -Checks $allChecks
    Assert-Result "valid-exit" ($r.Code -eq 0) ("expected exit 0, got " + $r.Code + ". Output: " + $r.Out)
}

$results += Run-Test "a hand-written comma-joined string is refused and named" {
    $r = Invoke-ValidatorOnChecks -Checks @($allChecks -join ",")
    Assert-Result "invalid-exit" ($r.Code -eq 1) ("expected exit 1, got " + $r.Code + ". Output: " + $r.Out)
    Assert-Result "reason-code" ($r.Out -match 'reviewer_contract_failed') ("expected reviewer_contract_failed. Output: " + $r.Out)
    Assert-Result "names-value" ($r.Out.Contains("'tests_pass,vet_pass,")) ("expected the joined value to be named. Output: " + $r.Out)
}

$results += Run-Test "a value outside the enum is refused and named" {
    $r = Invoke-ValidatorOnChecks -Checks @($allChecks + "lint_pass")
    Assert-Result "invalid-exit" ($r.Code -eq 1) ("expected exit 1, got " + $r.Code + ". Output: " + $r.Out)
    Assert-Result "names-value" ($r.Out.Contains("'lint_pass'")) ("expected lint_pass to be named. Output: " + $r.Out)
}

$results += Run-Test "a missing check is refused and named" {
    $r = Invoke-ValidatorOnChecks -Checks @($allChecks | Where-Object { $_ -ne "scope_bounded" })
    Assert-Result "invalid-exit" ($r.Code -eq 1) ("expected exit 1, got " + $r.Code + ". Output: " + $r.Out)
    Assert-Result "names-missing" ($r.Out -match 'missing reviewer checks: scope_bounded') ("expected scope_bounded to be named as missing. Output: " + $r.Out)
}

$results += Run-Test "the legacy reviewer->operator check is gone" {
    $text = Get-Content -LiteralPath $validateScript -Raw -Encoding UTF8
    Assert-Result "no-legacy-key" (-not ($text -match '\$source -eq "reviewer"')) "validate-handoff.ps1 still keys a check to the legacy reviewer phase"
}

$passed = @($results | Where-Object { $_ }).Count
$total = $results.Count
Write-Host ("`n[validate-handoff-reviewer-checks] {0}/{1} passed" -f $passed, $total) -ForegroundColor Cyan
if ($passed -ne $total) { exit 1 }
