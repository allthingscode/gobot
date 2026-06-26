# Verifies Get-SpecialistModel maps (target_phase, budget_tier, design_required) to the
# correct model per the Model Selection policy (docs/policy.md 2.3): Sonnet is the default,
# Opus is reserved for activities that warrant deeper reasoning, and the mechanical
# Operator runs on Haiku.

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$REPO_ROOT = (Resolve-Path -Path "$PSScriptRoot/../..").Path
. (Join-Path $PSScriptRoot '_harness.ps1')
. (Join-Path $REPO_ROOT "powershell/factory-lib.ps1")

$results = @()

$results += Run-Test "Researcher is always Opus regardless of tier" {
    Assert-Result "research low" ((Get-SpecialistModel -TargetPhase 'research' -BudgetTier 'low') -eq 'opus') "expected opus"
    Assert-Result "research extended" ((Get-SpecialistModel -TargetPhase 'research' -BudgetTier 'extended') -eq 'opus') "expected opus"
}

$results += Run-Test "Groomer defaults to Sonnet, escalates on high/extended" {
    Assert-Result "groom low" ((Get-SpecialistModel -TargetPhase 'grooming' -BudgetTier 'low') -eq 'sonnet') "expected sonnet"
    Assert-Result "groom medium" ((Get-SpecialistModel -TargetPhase 'grooming' -BudgetTier 'medium') -eq 'sonnet') "expected sonnet"
    Assert-Result "groom high" ((Get-SpecialistModel -TargetPhase 'grooming' -BudgetTier 'high') -eq 'opus') "expected opus"
    Assert-Result "groom extended" ((Get-SpecialistModel -TargetPhase 'grooming' -BudgetTier 'extended') -eq 'opus') "expected opus"
}

$results += Run-Test "Architect: design_required or high/extended tier -> Opus, else Sonnet" {
    Assert-Result "arch low exec" ((Get-SpecialistModel -TargetPhase 'implementation' -BudgetTier 'low' -DesignRequired $false) -eq 'sonnet') "expected sonnet"
    Assert-Result "arch low design" ((Get-SpecialistModel -TargetPhase 'implementation' -BudgetTier 'low' -DesignRequired $true) -eq 'opus') "expected opus"
    Assert-Result "arch high exec" ((Get-SpecialistModel -TargetPhase 'implementation' -BudgetTier 'high' -DesignRequired $false) -eq 'opus') "expected opus"
    Assert-Result "arch extended exec" ((Get-SpecialistModel -TargetPhase 'implementation' -BudgetTier 'extended' -DesignRequired $false) -eq 'opus') "expected opus"
}

$results += Run-Test "Reviewer defaults to Sonnet, escalates on high/extended" {
    Assert-Result "rev low" ((Get-SpecialistModel -TargetPhase 'verification' -BudgetTier 'low') -eq 'sonnet') "expected sonnet"
    Assert-Result "rev high" ((Get-SpecialistModel -TargetPhase 'verification' -BudgetTier 'high') -eq 'opus') "expected opus"
}

$results += Run-Test "Operator is Haiku, escalates only to Sonnet on high/extended" {
    Assert-Result "op low" ((Get-SpecialistModel -TargetPhase 'deployment' -BudgetTier 'low') -eq 'haiku') "expected haiku"
    Assert-Result "op medium" ((Get-SpecialistModel -TargetPhase 'deployment' -BudgetTier 'medium') -eq 'haiku') "expected haiku"
    Assert-Result "op high" ((Get-SpecialistModel -TargetPhase 'deployment' -BudgetTier 'high') -eq 'sonnet') "expected sonnet"
}

$results += Run-Test "done has no model; blank/dirty tier defaults safely" {
    Assert-Result "done empty" ((Get-SpecialistModel -TargetPhase 'done' -BudgetTier 'low') -eq '') "expected empty"
    Assert-Result "blank tier -> medium -> sonnet for groom" ((Get-SpecialistModel -TargetPhase 'grooming' -BudgetTier '') -eq 'sonnet') "expected sonnet"
    Assert-Result "case/space-insensitive tier" ((Get-SpecialistModel -TargetPhase 'implementation' -BudgetTier '  HIGH ' -DesignRequired $false) -eq 'opus') "expected opus"
}

if ($results -contains $false) {
    Write-Host "`nSOME TESTS FAILED" -ForegroundColor Red
    exit 1
}

Write-Host ("`nALL TESTS PASSED (" + $results.Count + " tests)") -ForegroundColor Green
exit 0
